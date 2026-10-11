import Foundation
import SystemBarKit

/// The Disk tab: volume math, the plugin's settings, and the plugin end to end through a fake
/// host with a temporary data folder. Main-actor because a plugin is constructed on the main
/// thread, by contract.
@MainActor
enum DiskTests {
    static func runAll() {
        testDiskVolumeMath()
        testLocalSnapshotParsing()
        testSnapshotCountRunsTmutilThroughTheHost()
        testSnapshotAppliesAReadingAndALedger()
        testFooterOrdersProblemsBeforeProgressBeforeAges()
        testSamplingIntervalsKeepScansRare()
        testBackgroundScansSettingDefaultsOnAndReportsAWrongType()
        testPluginDeclaresABackgroundIntervalUnlessTurnedOff()
        testCollectRunsDuePlansOnceAndSavesTheLedger()
        testAnIncompleteScanLeavesAWarningForTheFooter()
        testACompleteRunClearsTheWarning()
        testAPlanThatMeasuredNothingWaitsItsCadence()
        testRepeatedRescanClicksQueueOneRun()
        testSaveProblemClearsAndLeavesTheLedgerNote()
        testPluginStartsFromASavedLedgerAndReportsABrokenOne()
        testPluginIdentityMatchesTheOldTab()
    }

    static let home = "/tmp/systembar-tests"
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    private static func testDiskVolumeMath() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 150, isRoot: true)
        expect(volume.used == 850, "used is capacity minus free: purgeable space is still on the disk, so it counts as used")
        expect(volume.freeRatio == 0.15, "the free ratio drives the headline colour")

        // A volume reporting more free than capacity must not underflow the unsigned used value.
        let overreported = DiskVolume(name: "Odd", path: "/odd", total: 100, free: 200, isRoot: false)
        expect(overreported.used == 0, "used clamps to zero rather than underflowing")
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

    private static func testSnapshotCountRunsTmutilThroughTheHost() {
        let recorder = LogRecorder()
        let answers = ["/usr/bin/tmutil listlocalsnapshots /": "Snapshots for disk /:\ncom.apple.TimeMachine.1.local\ncom.apple.os.update-2\n"]
        let collector = DiskCollector(host: makeHost(runner: recordingRunner(recorder, answers: answers)))
        expect(collector.collectLocalSnapshotCount() == 2, "both Time Machine and OS-update snapshots count")
        expect(recorder.messages == ["/usr/bin/tmutil listlocalsnapshots /"], "tmutil runs through the host by explicit path, got \(recorder.messages)")

        let failing = DiskCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.collectLocalSnapshotCount() == 0, "a tmutil that fails counts no snapshots rather than guessing")
    }

    private static func testSnapshotAppliesAReadingAndALedger() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 150, isRoot: true)
        let read = DiskSnapshot().applying(DiskVolumeReading(volumes: [volume], localSnapshotCount: 3, sampledAt: now))
        expect(read.boot?.path == "/" && read.localSnapshotCount == 3, "a volume reading fills the volumes and the snapshot count")
        expect(read.status == "Disk sample OK" && read.health == .ok && read.lastUpdated == now, "a reading with volumes is healthy and dated, got \(read.status)")

        let empty = DiskSnapshot().applying(DiskVolumeReading(volumes: [], localSnapshotCount: 0, sampledAt: now))
        expect(empty.status == "No readable volumes found" && empty.health == .degraded, "no readable volume says so and is degraded, got \(empty.status)")

        // Both paths were measured over a week ago, so the overview plan had looked before either
        // window and Library, unchanged, is not a mover.
        let ledger = DiskLedger().appending([
            DiskSample(path: "\(home)/proj", bytes: 10, measuredAt: now.addingTimeInterval(-8 * 86_400), plan: .overview),
            DiskSample(path: "\(home)/Library", bytes: 90, measuredAt: now.addingTimeInterval(-8 * 86_400), plan: .overview),
            DiskSample(path: "\(home)/proj", bytes: 40, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/Library", bytes: 90, measuredAt: now.addingTimeInterval(-7200), plan: .overview),
        ])
        let mapped = read.applying(DiskDerivedRows.derive(from: ledger, homeDirectory: home, now: now))
        expect(mapped.biggest.map(\.name) == ["Library", "proj"], "the ledger becomes ranked rows, got \(mapped.biggest.map(\.name))")
        expect(mapped.movers24h.map(\.row.name) == ["proj"] && mapped.movers24h.first?.change == .grew(30), "and movers over a day, got \(mapped.movers24h)")
        expect(mapped.movers7d.first?.change == .grew(30), "and over a week")
        expect(mapped.planAges[.overview] == now.addingTimeInterval(-3600) && mapped.planAges[.developer] == nil, "each plan's newest sample is its age; a plan that never ran has none")
        expect(mapped.volumes.count == 1 && mapped.localSnapshotCount == 3, "applying a ledger leaves the volume reading alone")

        let scanning = mapped.scanning(true, status: "Measuring overview folders")
        expect(scanning.isScanning && scanning.scanStatus == "Measuring overview folders", "the scan state is its own, got \(scanning.scanStatus)")
        expect(scanning.biggest == mapped.biggest, "and leaves the rows alone")
    }

    private static func testFooterOrdersProblemsBeforeProgressBeforeAges() {
        var ages = DiskSnapshot()
        ages.planAges = [.overview: now.addingTimeInterval(-120), .simulators: now.addingTimeInterval(-7200)]
        let plain = ages.footer(now: now)
        expect(plain.text == "Overview 2m ago · Developer never · Simulators 2h ago" && !plain.isWarning, "with nothing else to say, each plan's age in plan order, got \(plain.text)")

        let incomplete = ages.warning("Overview: Measured 1 path, 1 unreadable (needs Full Disk Access?)")
        expect(incomplete.footer(now: now) == ("Overview: Measured 1 path, 1 unreadable (needs Full Disk Access?)", true), "an incomplete last scan comes before the ages, as a warning")

        let scanning = incomplete.scanning(true, status: "Measuring overview folders")
        expect(scanning.footer(now: now) == ("Measuring overview folders", false), "progress comes before the incomplete summary, and is not a warning while it runs")

        let moved = scanning.noting("moved aside")
        expect(moved.footer(now: now) == ("moved aside", true), "a moved-aside ledger comes before progress, as a warning")

        let unsaved = moved.savingProblem("could not save")
        expect(unsaved.footer(now: now) == ("could not save", true), "a failed save comes before the moved-aside note")

        var misconfigured = unsaved
        misconfigured.settingsProblem = "settings problem"
        expect(misconfigured.footer(now: now) == ("settings problem", true), "a settings problem comes first of all")
    }

    private static func testSamplingIntervalsKeepScansRare() {
        expect(DiskSampling.refreshInterval == 30, "volumes every 30 s while showing")
        expect(DiskSampling.backgroundInterval == 900 && DiskSampling.backgroundInterval >= 5 && DiskSampling.backgroundInterval <= 86_400, "a 15-minute due check while hidden, inside the scheduler's clamp")
        for plan in DiskScanPlan.all {
            expect(plan.cadence >= 3 * 3600, "\(plan.kind) runs at most every three hours, got \(plan.cadence)")
            expect(plan.budget < plan.cadence && plan.budget > DiskSampling.rowTimeout, "\(plan.kind)'s budget fits inside its cadence and outlasts one row's timeout")
        }
    }

    private static func testBackgroundScansSettingDefaultsOnAndReportsAWrongType() {
        let on = DiskPlugin.backgroundScansSetting(.empty)
        expect(on.isEnabled && on.problem == nil, "no setting means background scans run")
        let off = DiskPlugin.backgroundScansSetting(PluginSettings(values: ["backgroundScans": .bool(false)]))
        expect(!off.isEnabled && off.problem == nil, "false turns them off")
        let wrong = DiskPlugin.backgroundScansSetting(PluginSettings(values: ["backgroundScans": .string("no")]))
        expect(wrong.isEnabled && wrong.problem == "settings: \"backgroundScans\" must be true or false; background scans stay on", "a wrong type keeps the default and says so, got \(String(describing: wrong.problem))")
    }

    private static func testPluginDeclaresABackgroundIntervalUnlessTurnedOff() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let on = DiskPlugin(host: makeHost(dataDirectory: directory))
        expect(on.backgroundInterval == DiskSampling.backgroundInterval, "by default the host should call collect() every 15 minutes while the tab is hidden")
        let off = DiskPlugin(host: makeHost(settings: PluginSettings(values: ["backgroundScans": .bool(false)]), dataDirectory: directory))
        expect(off.backgroundInterval == nil, "turned off, the plugin asks for nothing while hidden")
        let wrong = DiskPlugin(host: makeHost(settings: PluginSettings(values: ["backgroundScans": .number(1)]), dataDirectory: directory))
        expect(wrong.snapshot.settingsProblem?.contains("backgroundScans") == true, "a bad value is on the snapshot for the panel to show")
    }

    /// A plugin over a fake tree: home has two folders, one plan measures them.
    private static func makePlugin(dataDirectory: URL, recorder: LogRecorder, extraAnswers: [String: String] = [:], children: [String] = ["big", "small"]) -> DiskPlugin {
        var answers = [
            "/usr/bin/tmutil listlocalsnapshots /": "Snapshots for disk /:\ncom.apple.TimeMachine.1.local\n",
            "/usr/bin/du -s -k -x \(home)/big": "100\t\(home)/big\n",
            "/usr/bin/du -s -k -x \(home)/small": "1\t\(home)/small\n",
        ]
        answers.merge(extraAnswers) { _, new in new }
        let plan = DiskScanPlan(kind: .overview, cadence: 3600, budget: 60, roots: [""])
        return DiskPlugin(
            host: makeHost(runner: recordingRunner(recorder, answers: answers), dataDirectory: dataDirectory),
            plans: [plan],
            now: { Date() },
            listChildren: { parent in parent == home ? children.map { "\(home)/\($0)" } : [] }
        )
    }

    private static func testCollectRunsDuePlansOnceAndSavesTheLedger() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LogRecorder()
        let plugin = makePlugin(dataDirectory: directory, recorder: recorder)
        let duCount: () -> Int = { recorder.messages.filter { $0.hasPrefix("/usr/bin/du ") }.count }

        plugin.collect()
        waitUntil(5) { plugin.snapshot.biggest.count == 2 && !plugin.snapshot.isScanning && plugin.snapshot.lastUpdated != nil }
        expect(plugin.snapshot.boot != nil && plugin.snapshot.localSnapshotCount == 1, "collect reads the volumes and the snapshot count")
        expect(plugin.snapshot.biggest.map(\.name) == ["big", "small"], "a fresh plugin's first collect finds the plan due, measures, and publishes rows, got \(plugin.snapshot.biggest.map(\.name))")
        expect(plugin.snapshot.biggest.first?.bytes == 100 * 1024, "in bytes")
        expect(plugin.snapshot.scanStatus == "Overview: Measured 2 paths", "the footer says what the scan did, got \(plugin.snapshot.scanStatus)")
        expect(plugin.snapshot.scanWarning == nil, "a scan that measured everything leaves no warning, got \(String(describing: plugin.snapshot.scanWarning))")
        expect(duCount() == 2, "one du per folder, got \(recorder.messages)")
        expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disk-ledger.json").path), "the ledger is saved in the plugin's data folder")
        expect(recorder.messages.allSatisfy { $0.hasPrefix("/usr/bin/tmutil ") || $0.hasPrefix("/usr/bin/du -s -k -x ") }, "every command goes through the host by explicit path, got \(recorder.messages)")

        plugin.collect()
        plugin.drainScanQueue()
        expect(duCount() == 2, "a second collect finds nothing due and runs no du, got \(duCount())")

        plugin.requestScan(force: true)
        waitUntil(5) { duCount() == 4 }
        expect(duCount() == 4, "the rescan button forces every plan, got \(duCount())")
    }

    private static func testAnIncompleteScanLeavesAWarningForTheFooter() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // "denied" has no answer, so its du fails without timing out: an unreadable row.
        let plugin = makePlugin(dataDirectory: directory, recorder: LogRecorder(), children: ["big", "denied"])
        plugin.collect()
        plugin.drainScanQueue()
        waitUntil(5) { plugin.snapshot.scanWarning != nil && !plugin.snapshot.isScanning }
        let warning = plugin.snapshot.scanWarning ?? ""
        expect(warning.hasPrefix("Overview: ") && warning.contains("1 unreadable"), "the last incomplete scan's summary stays for the footer, got \(warning)")
    }

    private static func testACompleteRunClearsTheWarning() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The first run lists "denied", which has no answer and so reads as unreadable; the
        // forced run no longer lists it, so it measures everything.
        var children = ["big", "denied"]
        let plugin = DiskPlugin(
            host: makeHost(runner: recordingRunner(LogRecorder(), answers: [
                "/usr/bin/tmutil listlocalsnapshots /": "",
                "/usr/bin/du -s -k -x \(home)/big": "100\t\(home)/big\n",
            ]), dataDirectory: directory),
            plans: [DiskScanPlan(kind: .overview, cadence: 3600, budget: 60, roots: [""])],
            now: { Date() },
            listChildren: { parent in parent == home ? children.map { "\(home)/\($0)" } : [] }
        )
        plugin.collect()
        plugin.drainScanQueue()
        waitUntil(5) { plugin.snapshot.scanWarning != nil }
        expect(plugin.snapshot.scanWarning?.contains("1 unreadable") == true, "the first run leaves a warning, got \(String(describing: plugin.snapshot.scanWarning))")

        children = ["big"]
        plugin.requestScan(force: true)
        plugin.drainScanQueue()
        waitUntil(5) { plugin.snapshot.scanWarning == nil }
        expect(plugin.snapshot.scanWarning == nil && plugin.snapshot.scanStatus == "Overview: Measured 1 path", "a later complete run clears it, got \(String(describing: plugin.snapshot.scanWarning))")
    }

    private static func testAPlanThatMeasuredNothingWaitsItsCadence() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LogRecorder()
        let plan = DiskScanPlan(kind: .simulators, cadence: 3600, budget: 60, roots: [""])
        let plugin = DiskPlugin(
            host: makeHost(runner: recordingRunner(recorder, answers: [:]), dataDirectory: directory),
            plans: [plan],
            now: { Date() },
            listChildren: { _ in [] }
        )
        plugin.collect()
        plugin.drainScanQueue()
        plugin.collect()
        plugin.drainScanQueue()
        let simctlCalls = recorder.messages.filter { $0.hasPrefix("/usr/bin/xcrun simctl ") }
        expect(simctlCalls.count == 1, "a run that records no sample still waits its cadence, so simctl runs once, got \(recorder.messages)")
    }

    private static func testRepeatedRescanClicksQueueOneRun() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LogRecorder()
        // Each du waits for the test, so the first rescan is still running when the others arrive.
        let release = DispatchSemaphore(value: 0)
        let recording = recordingRunner(recorder, answers: [
            "/usr/bin/du -s -k -x \(home)/big": "100\t\(home)/big\n",
        ])
        let runner: CommandRunner = { path, arguments, timeout, environment in
            if path == "/usr/bin/du" { _ = release.wait(timeout: .now() + 5) }
            return recording(path, arguments, timeout, environment)
        }
        let plugin = DiskPlugin(
            host: makeHost(runner: runner, dataDirectory: directory),
            plans: [DiskScanPlan(kind: .overview, cadence: 3600, budget: 60, roots: [""])],
            now: { Date() },
            listChildren: { parent in parent == home ? ["\(home)/big"] : [] }
        )
        plugin.requestScan(force: true)
        plugin.requestScan(force: true)
        plugin.requestScan(force: true)
        release.signal()
        plugin.drainScanQueue()
        let duCount = recorder.messages.filter { $0.hasPrefix("/usr/bin/du ") }.count
        expect(duCount == 1, "three clicks during one rescan run it once, got \(recorder.messages)")

        plugin.requestScan(force: true)
        release.signal()
        plugin.drainScanQueue()
        expect(recorder.messages.filter { $0.hasPrefix("/usr/bin/du ") }.count == 2, "a click after that rescan finished runs another")
    }

    private static func testSaveProblemClearsAndLeavesTheLedgerNote() {
        let noted = DiskSnapshot().noting("moved aside").savingProblem("could not save")
        expect(noted.ledgerNote == "moved aside" && noted.saveProblem == "could not save", "a save problem does not overwrite the moved-aside note")
        let saved = noted.savingProblem(nil)
        expect(saved.saveProblem == nil && saved.ledgerNote == "moved aside", "a later good save clears the save problem and keeps the note")
    }

    private static func testPluginStartsFromASavedLedgerAndReportsABrokenOne() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore.standard(dataDirectory: directory)
        try? store.save(DiskLedger().appending([DiskSample(path: "\(home)/saved", bytes: 7 * 1024, measuredAt: Date(), plan: .overview)]))
        let recorder = LogRecorder()
        let plugin = makePlugin(dataDirectory: directory, recorder: recorder)
        plugin.collect()
        waitUntil(5) { plugin.snapshot.biggest.contains { $0.name == "saved" } }
        expect(plugin.snapshot.biggest.contains { $0.name == "saved" }, "the saved ledger shows before any scan, got \(plugin.snapshot.biggest.map(\.name))")
        plugin.drainScanQueue()
        expect(recorder.messages.filter { $0.hasPrefix("/usr/bin/du ") }.isEmpty, "and a plan measured a moment ago is not due, got \(recorder.messages)")

        let brokenDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: brokenDirectory) }
        try? Data("{".utf8).write(to: brokenDirectory.appendingPathComponent(DiskLedgerStore.fileName))
        let fresh = makePlugin(dataDirectory: brokenDirectory, recorder: LogRecorder())
        fresh.collect()
        waitUntil(5) { fresh.snapshot.ledgerNote != nil }
        expect(fresh.snapshot.ledgerNote?.contains(".broken") == true, "a ledger that will not parse is moved aside and the panel is told, got \(String(describing: fresh.snapshot.ledgerNote))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = DiskPlugin(host: makeHost(dataDirectory: directory))
        expect(DiskPlugin.identifier == "disk" && plugin.title == "Disk" && plugin.systemImage == "internaldrive", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.cyan, "and its accent")
        expect(plugin.refreshInterval == 30 && plugin.sharedFeeds.isEmpty, "and its interval, and it needs no shared feed")
    }
}
