import Foundation
import SystemBarKit

/// The Disk tab: volume math, the du-based hog scan, and the plugin that runs both.
/// Main-actor because a plugin is constructed on the main thread, by contract.
@MainActor
enum DiskTests {
    static func runAll() {
        testDiskVolumeMath()
        testDiskUsageParsing()
        testLocalSnapshotParsing()
        testReclaimableTotalIgnoresNestedPaths()
        testDiskHogCandidatePaths()
        testDiskHogScanDueRule()
        testDiskHogScanKeepsPathsThatFinished()
        testDiskHogScanMeasuresBiggestCandidatesFirst()
        testDiskHogScanPublishesRowsAsTheyFinish()
        testDiskHogScanStopsAtItsBudget()
        testDiskHogScanReportsPermissionTroubleSeparately()
        testSamplingIntervalsKeepDuRare()
        testSnapshotCountRunsTmutilThroughTheHost()
        testSnapshotAppliesAReadingAndEachHogUpdate()
        testHogScanRunsOnceUntilDueOrForced()
        testCollectPublishesVolumesAndTheHogScan()
        testPluginIdentityMatchesTheOldTab()
    }

    private static func testDiskVolumeMath() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 100, purgeable: 50, isRoot: true)
        expect(volume.importantAvailable == 150, "available should include purgeable space macOS can reclaim")
        expect(volume.used == 850, "used should be capacity minus everything macOS counts as available")
        expect(volume.availableRatio == 0.15, "available ratio should drive the headline colour")

        // A volume reporting more available than capacity must not underflow the unsigned used value.
        let overreported = DiskVolume(name: "Odd", path: "/odd", total: 100, free: 200, purgeable: 0, isRoot: false)
        expect(overreported.used == 0, "used should clamp to zero rather than underflow")
    }

    private static func testDiskUsageParsing() {
        let sample = """
        18034356\t/Users/adam/Library/Caches
        5890624\t/Users/adam/Downloads
        garbage line without a tab
        """
        let parsed = DiskCollector.parseDiskUsage(sample)
        expect(parsed.count == 2, "du parser should skip lines it cannot read")
        expect(parsed.first?.path == "/Users/adam/Library/Caches", "du parser should preserve paths")
        expect(parsed.first?.bytes == 18034356 * 1024, "du -k reports kilobytes and must be scaled to bytes")
    }

    private static func testLocalSnapshotParsing() {
        let sample = """
        Snapshots for volume group containing disk /:
        com.apple.os.update-38264256808F4A6EF35A2D2DE2F5838AC3E1B0F65
        com.apple.TimeMachine.2026-07-17-084500.local
        """
        expect(DiskCollector.parseLocalSnapshotCount(sample) == 2, "snapshot parser should count entries and drop the header")
        expect(DiskCollector.parseLocalSnapshotCount("") == 0, "snapshot parser should tolerate empty output")
    }

    private static func testReclaimableTotalIgnoresNestedPaths() {
        var snapshot = DiskSnapshot()
        snapshot.hogs = [
            DiskHog(name: "User Caches", path: "/Users/adam/Library/Caches", size: 100, hint: ""),
            DiskHog(name: "CocoaPods", path: "/Users/adam/Library/Caches/CocoaPods", size: 30, hint: ""),
            DiskHog(name: "Downloads", path: "/Users/adam/Downloads", size: 20, hint: "")
        ]
        expect(snapshot.reclaimableTotal == 120, "nested candidates must not be counted twice")
        expect(snapshot.maxHogSize == 100, "max hog size should drive the row bars")

        // A path that merely shares a name prefix is not nested and must still count.
        var siblings = DiskSnapshot()
        siblings.hogs = [
            DiskHog(name: "Caches", path: "/Users/adam/Caches", size: 10, hint: ""),
            DiskHog(name: "CachesOld", path: "/Users/adam/CachesOld", size: 5, hint: "")
        ]
        expect(siblings.reclaimableTotal == 15, "prefix-sharing siblings are not nested")
    }

    private static func testDiskHogCandidatePaths() {
        let candidate = DiskHogCandidate(name: "Caches", path: "Library/Caches", hint: "")
        expect(candidate.resolvedPath(homeDirectory: "/Users/adam") == "/Users/adam/Library/Caches", "relative candidates resolve against home")

        let absolute = DiskHogCandidate(name: "System Caches", path: "/Library/Caches", hint: "")
        expect(absolute.resolvedPath(homeDirectory: "/Users/adam") == "/Library/Caches", "absolute candidates are used as-is")

        let paths = Set(DiskHogCandidate.all.map(\.path))
        expect(paths.count == DiskHogCandidate.all.count, "candidate paths must be unique")
    }

    /// A `du` that walked a tree to completion prints "<kilobytes>\t<path>".
    private static func duFinished(_ path: String, kilobytes: UInt64) -> CommandOutput {
        CommandOutput(output: "\(kilobytes)\t\(path)\n", error: "", status: 0, didTimeout: false)
    }

    private static let hogHome = "/Users/adam"

    private static let hogCandidates = [
        DiskHogCandidate(name: "DerivedData", path: "Library/Developer/Xcode/DerivedData", hint: ""),
        DiskHogCandidate(name: "Simulators", path: "Library/Developer/CoreSimulator", hint: ""),
        DiskHogCandidate(name: "Downloads", path: "Downloads", hint: "")
    ]

    /// Every capacity read asks whether a hog scan is due, so the rule that answers has to
    /// live where the answer can be given without racing the queue that owns the scan.
    private static func testDiskHogScanDueRule() {
        let now = Date(timeIntervalSince1970: 10_000)
        expect(
            DiskCollector.isDiskHogScanDue(force: false, lastScan: .distantPast, now: now, interval: 600),
            "a scan that has never run is due"
        )
        expect(
            !DiskCollector.isDiskHogScanDue(force: false, lastScan: now.addingTimeInterval(-599), now: now, interval: 600),
            "a scan finished seconds ago must not be repeated by the next capacity read"
        )
        expect(
            DiskCollector.isDiskHogScanDue(force: false, lastScan: now.addingTimeInterval(-600), now: now, interval: 600),
            "a scan is due once the full interval has elapsed"
        )
        expect(
            DiskCollector.isDiskHogScanDue(force: true, lastScan: now, now: now, interval: 600),
            "the rescan button must override the interval"
        )
    }

    /// The regression: one `du` covering every candidate tree took longer than its timeout,
    /// and because its stdout was a pipe (so block-buffered), SIGTERM destroyed every
    /// per-path total it had already computed. The whole list came back empty.
    private static func testDiskHogScanKeepsPathsThatFinished() {
        let slowPath = "\(hogHome)/Library/Developer/CoreSimulator"

        let result = DiskCollector.measureDiskHogs(
            candidates: hogCandidates,
            homeDirectory: hogHome,
            budget: 100,
            pathExists: { _ in true },
            elapsed: { 0 },
            measure: { path in
                if path == slowPath {
                    return CommandOutput(output: "", error: "", status: -1, didTimeout: true)
                }
                return duFinished(path, kilobytes: path.hasSuffix("DerivedData") ? 2048 : 1024)
            }
        )

        expect(
            result.hogs.map(\.name) == ["DerivedData", "Downloads"],
            "a du killed on one tree must not discard the trees that finished, got \(result.hogs.map(\.name))"
        )
        expect(result.hogs.first?.size == 2048 * 1024, "du -k reports kilobytes and must scale to bytes")
        expect(
            result.status.contains("1 too slow"),
            "the status should count the path that timed out rather than blaming permissions: \(result.status)"
        )
    }

    private static func testDiskHogScanMeasuresBiggestCandidatesFirst() {
        var measured: [String] = []
        _ = DiskCollector.measureDiskHogs(
            candidates: DiskHogCandidate.all,
            homeDirectory: hogHome,
            budget: 100,
            pathExists: { _ in true },
            elapsed: { 0 },
            measure: { path in
                measured.append(path)
                return duFinished(path, kilobytes: 1)
            }
        )

        expect(
            measured == DiskHogCandidate.all.map { $0.resolvedPath(homeDirectory: hogHome) },
            "paths must be walked in candidate order so a scan cut short still covers the biggest hogs"
        )
    }

    /// A full scan can take minutes, and an empty panel for minutes is the same complaint as
    /// an empty panel forever. Each tree that finishes goes to the list right away.
    private static func testDiskHogScanPublishesRowsAsTheyFinish() {
        var updates: [[String]] = []

        let result = DiskCollector.measureDiskHogs(
            candidates: hogCandidates,
            homeDirectory: hogHome,
            budget: 100,
            pathExists: { _ in true },
            elapsed: { 0 },
            measure: { path in
                if path.hasSuffix("CoreSimulator") {
                    return CommandOutput(output: "", error: "", status: -1, didTimeout: true)
                }
                return duFinished(path, kilobytes: path.hasSuffix("DerivedData") ? 1 : 2)
            },
            onProgress: { updates.append($0.map(\.name)) }
        )

        expect(
            updates == [["DerivedData"], ["Downloads", "DerivedData"]],
            "every finished tree should reach the list mid-scan, always biggest first: \(updates)"
        )
        expect(
            result.hogs.map(\.name) == ["Downloads", "DerivedData"],
            "reporting progress must not change what the finished scan returns"
        )
    }

    private static func testDiskHogScanStopsAtItsBudget() {
        var started = 0
        let result = DiskCollector.measureDiskHogs(
            candidates: hogCandidates,
            homeDirectory: hogHome,
            budget: 10,
            pathExists: { _ in true },
            elapsed: { Double(started) * 6 },
            measure: { path in
                started += 1
                return duFinished(path, kilobytes: 1)
            }
        )

        expect(started == 2, "no new path should be started once the scan budget is spent, started \(started)")
        expect(result.hogs.count == 2, "paths measured before the budget ran out must still be reported")
        expect(
            result.status.contains("1 not measured"),
            "a scan cut short should say what it never reached: \(result.status)"
        )
    }

    private static func testDiskHogScanReportsPermissionTroubleSeparately() {
        let denied = DiskCollector.measureDiskHogs(
            candidates: hogCandidates,
            homeDirectory: hogHome,
            budget: 100,
            pathExists: { _ in true },
            elapsed: { 0 },
            measure: { path in
                CommandOutput(output: "", error: "du: \(path): Operation not permitted", status: 1, didTimeout: false)
            }
        )
        expect(denied.hogs.isEmpty, "a path du cannot read produces no row")
        expect(
            denied.status.contains("Full Disk Access"),
            "an unreadable path should point at the permission that would fix it: \(denied.status)"
        )

        let nothingInstalled = DiskCollector.measureDiskHogs(
            candidates: hogCandidates,
            homeDirectory: hogHome,
            budget: 100,
            pathExists: { _ in false },
            elapsed: { 0 },
            measure: { _ in
                expect(false, "a path that does not exist must never be handed to du")
                return duFinished("/nope", kilobytes: 0)
            }
        )
        expect(
            nothingInstalled.status == "No candidate paths present on this Mac",
            "a Mac with none of the candidate directories should say so plainly"
        )
    }

    private static func testSamplingIntervalsKeepDuRare() {
        expect(DiskSampling.refreshInterval == 30, "the volume read keeps its 30-second interval")
        expect(DiskSampling.hogRefreshInterval >= 300, "du walks real trees and must stay rare")
        expect(DiskSampling.hogRefreshInterval > DiskSampling.refreshInterval, "hog scan should be rarer than the cheap capacity read")
        expect(DiskSampling.hogScanBudget < DiskSampling.hogRefreshInterval, "a scan must be over before the next one is due, so scans never pile up")
        expect(DiskSampling.hogPathTimeout < DiskSampling.hogScanBudget, "one slow tree must not be able to spend the whole scan budget")
    }

    private static func testSnapshotCountRunsTmutilThroughTheHost() {
        let recorder = LogRecorder()
        let listing = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-09-24-101010.local\ncom.apple.os.update-ABC\n"
        let collector = DiskCollector(host: makeHost(runner: recordingRunner(recorder, answers: ["/usr/bin/tmutil listlocalsnapshots /": listing])))
        expect(collector.collectLocalSnapshotCount() == 2, "both Time Machine and OS-update snapshots count")
        expect(recorder.messages == ["/usr/bin/tmutil listlocalsnapshots /"], "tmutil runs through the host by explicit path, got \(recorder.messages)")

        let failing = DiskCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.collectLocalSnapshotCount() == 0, "a tmutil that fails counts no snapshots rather than guessing")
    }

    private static func testSnapshotAppliesAReadingAndEachHogUpdate() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 100, purgeable: 50, isRoot: true)
        let at = Date(timeIntervalSince1970: 5_000)

        let read = DiskSnapshot().applying(DiskVolumeReading(volumes: [volume], localSnapshotCount: 3, sampledAt: at))
        expect(read.boot?.path == "/" && read.localSnapshotCount == 3, "a volume reading fills the volumes and the snapshot count")
        expect(read.status == "Disk sample OK" && read.health == .ok && read.lastUpdated == at, "a reading with volumes is healthy and dated, got \(read.status)")

        let empty = DiskSnapshot().applying(DiskVolumeReading(volumes: [], localSnapshotCount: 0, sampledAt: at))
        expect(empty.status == "No readable volumes found" && empty.health == .degraded, "no readable volume says so and is degraded, got \(empty.status)")

        let hog = DiskHog(name: "Downloads", path: "/Users/adam/Downloads", size: 10, hint: "")
        let started = read.applying(DiskHogUpdate.started)
        expect(started.isScanningHogs && started.hogStatus == "Measuring reclaimable paths", "a starting scan says it is measuring, got \(started.hogStatus)")
        let partway = started.applying(DiskHogUpdate.progress([hog]))
        expect(partway.hogs.map(\.name) == ["Downloads"] && partway.isScanningHogs, "each finished tree shows while the scan goes on")
        let done = partway.applying(DiskHogUpdate.finished(hogs: [hog], status: "Measured 1 path", at: at))
        expect(!done.isScanningHogs && done.hogStatus == "Measured 1 path" && done.lastHogScan == at, "a finished scan records its status and time")
        expect(done.volumes.count == 1 && done.localSnapshotCount == 3, "a hog update leaves the volume reading alone")
    }

    private static func testHogScanRunsOnceUntilDueOrForced() {
        let updates = LogRecorder()
        let collector = DiskCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        let record: (DiskHogUpdate) -> Void = { update in
            switch update {
            case .started: updates.record("started")
            case .progress: updates.record("progress")
            case .finished: updates.record("finished")
            }
        }
        let count: (String) -> Int = { name in updates.messages.filter { $0 == name }.count }

        collector.scanHogsIfDue(force: false, publish: record)
        collector.scanHogsIfDue(force: false, publish: record)
        waitUntil(2) { count("finished") >= 1 }
        spinRunLoop(for: 0.1)
        expect(count("started") == 1, "a second request straight after the first finds the scan not due, got \(updates.messages)")

        collector.scanHogsIfDue(force: true, publish: record)
        waitUntil(2) { count("finished") >= 2 }
        expect(count("started") == 2, "the rescan button forces a scan however recent the last one was, got \(updates.messages)")
    }

    private static func testCollectPublishesVolumesAndTheHogScan() {
        let recorder = LogRecorder()
        let answers = ["/usr/bin/tmutil listlocalsnapshots /": "com.apple.TimeMachine.1.local\n"]
        let plugin = DiskPlugin(host: makeHost(runner: recordingRunner(recorder, answers: answers)))
        plugin.collect()
        waitUntil(2) { plugin.snapshot.lastUpdated != nil && plugin.snapshot.lastHogScan != nil }
        expect(plugin.snapshot.boot != nil, "the boot volume is always read, got \(plugin.snapshot.volumes.map(\.path))")
        expect(plugin.snapshot.localSnapshotCount == 1, "the snapshot count comes through the host's runner")
        expect(plugin.snapshot.lastHogScan != nil && !plugin.snapshot.isScanningHogs, "a fresh plugin's first collect also runs the hog scan, which is due")
        expect(recorder.messages.allSatisfy { $0.hasPrefix("/usr/bin/tmutil ") || $0.hasPrefix("/usr/bin/du -s -k -x ") }, "every command goes through the host by explicit path, got \(recorder.messages)")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = DiskPlugin(host: makeHost())
        expect(DiskPlugin.identifier == "disk" && plugin.title == "Disk" && plugin.systemImage == "internaldrive", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.cyan, "and its accent")
        expect(plugin.refreshInterval == 30 && plugin.sharedFeeds.isEmpty, "and its interval, and it needs no shared feed")
    }
}
