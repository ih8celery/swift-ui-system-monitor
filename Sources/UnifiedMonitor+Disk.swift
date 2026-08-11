import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectDisk() {
        guard !isCollectingDisk else { return }
        isCollectingDisk = true
        defer { isCollectingDisk = false }

        let sampleDate = Date()
        let volumes = Self.collectDiskVolumes()
        let snapshotCount = Self.collectLocalSnapshotCount()
        let status = volumes.isEmpty ? "No readable volumes found" : "Disk sample OK"
        let health = SampleHealth(isOK: !volumes.isEmpty)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snapshot = self.diskSnapshot
            snapshot.volumes = volumes
            snapshot.localSnapshotCount = snapshotCount
            snapshot.status = status
            snapshot.health = health
            snapshot.lastUpdated = sampleDate
            self.diskSnapshot = snapshot
        }

        if sampleDate.timeIntervalSince(lastDiskHogScan) >= MonitorSamplingPlan.diskHogRefreshInterval {
            scanDiskHogs()
        }
    }

    /// Measures the candidate paths with a single `du`. Slow enough to deserve its own queue and a manual trigger.
    func scanDiskHogs() {
        diskQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isScanningDiskHogs else { return }
            self.isScanningDiskHogs = true
            self.lastDiskHogScan = Date()

            DispatchQueue.main.async {
                self.diskSnapshot.isScanningHogs = true
                self.diskSnapshot.hogStatus = "Measuring reclaimable paths"
            }

            let result = Self.collectDiskHogs()
            self.isScanningDiskHogs = false

            DispatchQueue.main.async {
                var snapshot = self.diskSnapshot
                snapshot.hogs = result.hogs
                snapshot.hogStatus = result.status
                snapshot.isScanningHogs = false
                snapshot.lastHogScan = Date()
                self.diskSnapshot = snapshot
            }
        }
    }


    static func collectDiskVolumes() -> [DiskVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey
        ]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let rootURL = URL(fileURLWithPath: "/")
        let candidates = mounted.contains(where: { $0.path == "/" }) ? mounted : [rootURL] + mounted

        return candidates.compactMap { url -> DiskVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.volumeIsBrowsable != false else { return nil }
            guard let total = values.volumeTotalCapacity, total > 0 else { return nil }

            let free = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
            let important = UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            // macOS reports reclaimable space as available; the difference is what it would purge under pressure.
            let purgeable = important > free ? important - free : 0

            return DiskVolume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: free,
                purgeable: purgeable,
                isRoot: url.path == "/"
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.total > rhs.total
        }
    }

    static func collectLocalSnapshotCount() -> Int {
        let result = runProcess(path: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
        guard result.status == 0 else { return 0 }
        return parseLocalSnapshotCount(result.output)
    }

    /// Output is a header line followed by one identifier per snapshot. Both Time Machine and
    /// OS-update snapshots hold real space, so every entry counts, not just the TM ones.
    static func parseLocalSnapshotCount(_ output: String) -> Int {
        output
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("com.apple.") }
            .count
    }

    /// `du -s -k` emits "<kilobytes>\t<path>" per measured path.
    static func parseDiskUsage(_ output: String) -> [(path: String, bytes: UInt64)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let kilobytes = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }

            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return (path, kilobytes &* 1024)
        }
    }

    static func collectDiskHogs() -> (hogs: [DiskHog], status: String) {
        let start = Date()
        return measureDiskHogs(
            candidates: DiskHogCandidate.all,
            homeDirectory: NSHomeDirectory(),
            budget: MonitorSamplingPlan.diskHogScanBudget,
            pathExists: { FileManager.default.fileExists(atPath: $0) },
            elapsed: { Date().timeIntervalSince(start) },
            measure: { path in
                // -x keeps du on one filesystem; -k normalises to KiB across macOS versions.
                runProcess(
                    path: "/usr/bin/du",
                    arguments: ["-s", "-k", "-x", path],
                    timeout: MonitorSamplingPlan.diskHogPathTimeout
                )
            }
        )
    }

    /// One `du` per tree, in candidate order, until the budget runs out.
    ///
    /// A single `du` over every tree was the wrong shape: on a developer's Mac the walk
    /// outruns any sane timeout, and since `du` writes to a pipe its stdio is block-buffered,
    /// so terminating it destroys every per-path total it had already computed — the list came
    /// back empty. Per-path processes flush on exit, so a tree that is too slow or unreadable
    /// costs only its own row. Candidate order matters because the budget truncates the tail.
    static func measureDiskHogs(
        candidates: [DiskHogCandidate],
        homeDirectory: String,
        budget: TimeInterval,
        pathExists: (String) -> Bool,
        elapsed: () -> TimeInterval,
        measure: (String) -> CommandOutput
    ) -> (hogs: [DiskHog], status: String) {
        var seenPaths = Set<String>()
        let targets = candidates.compactMap { candidate -> (candidate: DiskHogCandidate, path: String)? in
            let path = candidate.resolvedPath(homeDirectory: homeDirectory)
            guard seenPaths.insert(path).inserted, pathExists(path) else { return nil }
            return (candidate, path)
        }

        guard !targets.isEmpty else {
            return ([], "No candidate paths present on this Mac")
        }

        var hogs: [DiskHog] = []
        var timedOut = 0
        var unreadable = 0
        var unmeasured = 0

        for target in targets {
            guard elapsed() < budget else {
                unmeasured += 1
                continue
            }

            let result = measure(target.path)
            // `du -s` prints one "<kilobytes>\t<path>" line once the walk finishes; anything
            // else means this tree has no answer, which says nothing about the other trees.
            guard let bytes = parseDiskUsage(result.output).first?.bytes else {
                if result.didTimeout { timedOut += 1 } else { unreadable += 1 }
                continue
            }

            hogs.append(
                DiskHog(name: target.candidate.name, path: target.path, size: bytes, hint: target.candidate.hint)
            )
        }

        let status = diskHogStatus(
            measured: hogs.count,
            timedOut: timedOut,
            unreadable: unreadable,
            unmeasured: unmeasured
        )
        return (hogs.sorted { $0.size > $1.size }, status)
    }

    /// Names each way a path can be missing from the list, so a partial scan never reads as a
    /// complete one and a slow tree is never mistaken for a permission problem.
    static func diskHogStatus(measured: Int, timedOut: Int, unreadable: Int, unmeasured: Int) -> String {
        var parts = ["Measured \(measured) path\(measured == 1 ? "" : "s")"]
        if timedOut > 0 { parts.append("\(timedOut) too slow to finish") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable (needs Full Disk Access?)") }
        if unmeasured > 0 { parts.append("\(unmeasured) not measured, scan budget spent") }
        return parts.joined(separator: ", ")
    }

    // Reading stdout to EOF and then stderr to EOF deadlocks if the child
    // fills the unread pipe's buffer first: it blocks on that write while
    // this call blocks on the other read. Draining both pipes concurrently
    // via readabilityHandler, plus a wall-clock timeout that terminates a
    // child which never exits, closes both hangs.

}
