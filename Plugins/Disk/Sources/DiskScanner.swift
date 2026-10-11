import Foundation
import SystemBarKit

/// How one plan's run went. Every way a row can be missing is counted, so a partial scan never
/// reads as a complete one and a slow tree is never mistaken for a permission problem.
struct DiskScanOutcome: Equatable {
    var measured = 0
    var timedOut = 0
    var unreadable = 0
    var unmeasured = 0

    var status: String {
        var parts = ["Measured \(measured) path\(measured == 1 ? "" : "s")"]
        if timedOut > 0 { parts.append("\(timedOut) too slow to finish") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable (needs Full Disk Access?)") }
        if unmeasured > 0 { parts.append("\(unmeasured) not measured, scan budget spent") }
        return parts.joined(separator: ", ")
    }
}

/// Runs one plan: lists the targets, records vanished paths, then one `du` per target until the
/// budget is spent, handing each finished row to `onRow` as it lands. Per-folder processes are
/// deliberate: a single `du` over everything outruns any timeout and, writing to a pipe, loses
/// every total when killed; per-path processes flush on exit, so a slow or unreadable tree costs
/// only its own row. Called from the plugin's scan queue only.
final class DiskScanner: @unchecked Sendable {
    private let host: HostServices
    private let listChildren: (String) -> [String]?

    init(host: HostServices, listChildren: @escaping (String) -> [String]? = DiskScanner.subfolders(of:)) {
        self.host = host
        self.listChildren = listChildren
    }

    /// The immediate subfolders of `directory`, hidden ones included, symlinks excluded (a link
    /// into another tree would bill that tree here too). Nil when the directory is missing or
    /// cannot be read, so its children's earlier samples are left alone rather than marked freed.
    static func subfolders(of directory: String) -> [String]? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: Array(keys)) else {
            return nil
        }
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return entry.path
        }
    }

    func run(plan: DiskScanPlan, previous: DiskLedger, onRow: (DiskSample) -> Void) -> DiskScanOutcome {
        let start = Date()
        let catalog = plan.kind == .simulators
            ? SimulatorCatalog.parse(host.run(path: SimulatorCatalog.command, arguments: SimulatorCatalog.arguments).output)
            : [:]
        // Each root is read once; the roots that could be read are the only ones whose missing
        // children count as vanished.
        let roots = Set(plan.resolvedRoots(homeDirectory: host.homeDirectory))
        let listings = Dictionary(uniqueKeysWithValues: roots.map { ($0, listChildren($0)) })
        let listedRoots = Set(listings.compactMap { $0.value == nil ? nil : $0.key })
        let targets = DiskScanTargets.targets(for: plan, homeDirectory: host.homeDirectory, previous: previous, listChildren: { listings[$0] ?? nil }, catalog: catalog)
        DiskScanTargets.vanished(plan: plan, listedRoots: listedRoots, previous: previous, targets: targets, now: Date()).forEach(onRow)
        let host = self.host
        return Self.measure(
            targets: targets,
            plan: plan,
            now: { Date() },
            elapsed: { Date().timeIntervalSince(start) },
            measure: { path in
                // -x keeps du on one filesystem; -k normalises to KiB across macOS versions.
                host.run(path: "/usr/bin/du", arguments: ["-s", "-k", "-x", path], timeout: DiskSampling.rowTimeout)
            },
            onRow: onRow
        )
    }

    /// The loop, with its clock and its `du` injected so a test can run it in no time.
    static func measure(
        targets: [DiskScanTarget],
        plan: DiskScanPlan,
        now: () -> Date,
        elapsed: () -> TimeInterval,
        measure: (String) -> CommandOutput,
        onRow: (DiskSample) -> Void
    ) -> DiskScanOutcome {
        var outcome = DiskScanOutcome()
        for target in targets {
            guard elapsed() < plan.budget else {
                outcome.unmeasured += 1
                continue
            }
            let result = measure(target.path)
            // `du -s` prints one "<kilobytes>\t<path>" line once the walk finishes; anything else
            // means this tree has no answer, which says nothing about the other trees.
            guard let bytes = parseDiskUsage(result.output).first?.bytes else {
                if result.didTimeout { outcome.timedOut += 1 } else { outcome.unreadable += 1 }
                continue
            }
            outcome.measured += 1
            onRow(DiskSample(path: target.path, bytes: bytes, measuredAt: now(), plan: plan.kind, simulator: target.simulator))
        }
        return outcome
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
}
