import Foundation

/// One tier of the scan: which folders, how often, and for how long. Each root's immediate
/// subfolders are measured, one `du` each; the root itself is not, because its parent's plan
/// already measured it as a child.
struct DiskScanPlan: Equatable {
    let kind: DiskPlanKind
    let cadence: TimeInterval
    let budget: TimeInterval
    /// "" is home, a relative path is under home, a path starting with "/" is itself.
    let roots: [String]

    /// In the order they run when several are due: the cheap wide sweep first.
    static let all: [DiskScanPlan] = [
        DiskScanPlan(kind: .overview, cadence: DiskSampling.overviewCadence, budget: DiskSampling.planBudget,
                     roots: ["", "Library", "/Applications", "/opt", "/Library"]),
        DiskScanPlan(kind: .developer, cadence: DiskSampling.developerCadence, budget: DiskSampling.planBudget,
                     roots: ["Library/Application Support", "Library/Containers", "Library/Group Containers",
                             "Library/Developer/Xcode", ".cache", ".ollama", ".android", "proj"]),
        DiskScanPlan(kind: .simulators, cadence: DiskSampling.simulatorsCadence, budget: DiskSampling.planBudget,
                     roots: ["Library/Developer/CoreSimulator/Devices"]),
    ]

    static func plan(_ kind: DiskPlanKind) -> DiskScanPlan {
        all.first { $0.kind == kind }!
    }

    func resolvedRoots(homeDirectory: String) -> [String] {
        roots.map { root in
            if root.isEmpty { return homeDirectory }
            if root.hasPrefix("/") { return root }
            return "\(homeDirectory)/\(root)"
        }
    }
}

/// One folder a plan will measure.
struct DiskScanTarget: Equatable {
    let path: String
    let simulator: SimulatorInfo?
}

/// Pure: which folders a plan measures, in which order, and which earlier ones are gone.
enum DiskScanTargets {
    /// Every subfolder of every root, each once, biggest-known-first so a spent budget cuts the
    /// smallest, then never-measured folders by name. Simulator targets carry what the catalog
    /// knows, or their folder name when it knows nothing.
    static func targets(
        for plan: DiskScanPlan,
        homeDirectory: String,
        previous: DiskLedger,
        listChildren: (String) -> [String],
        catalog: [String: SimulatorInfo]
    ) -> [DiskScanTarget] {
        let known = Dictionary(uniqueKeysWithValues: previous.latest.map { ($0.path, $0.bytes) })
        var seen = Set<String>()
        let paths = plan.resolvedRoots(homeDirectory: homeDirectory)
            .flatMap(listChildren)
            .filter { seen.insert($0).inserted }
            .sorted { a, b in
                let (sizeA, sizeB) = (known[a] ?? 0, known[b] ?? 0)
                if sizeA != sizeB { return sizeA > sizeB }
                let order = a.compare(b, options: .caseInsensitive)
                return order == .orderedSame ? a < b : order == .orderedAscending
            }
        return paths.map { path in
            guard plan.kind == .simulators else { return DiskScanTarget(path: path, simulator: nil) }
            let udid = (path as NSString).lastPathComponent
            let info = catalog[udid] ?? SimulatorInfo(udid: udid, name: udid, runtime: "unknown runtime", lastBootedAt: nil)
            return DiskScanTarget(path: path, simulator: info)
        }
    }

    /// Paths this plan measured before, directly under one of its roots, that had bytes and are
    /// not among today's targets: recorded as zero now, so the movers list can show them freed.
    static func vanished(plan: DiskScanPlan, homeDirectory: String, previous: DiskLedger, targets: [DiskScanTarget], now: Date) -> [DiskSample] {
        let roots = Set(plan.resolvedRoots(homeDirectory: homeDirectory))
        let present = Set(targets.map(\.path))
        return previous.latest
            .filter { sample in
                sample.plan == plan.kind
                    && sample.bytes > 0
                    && !present.contains(sample.path)
                    && roots.contains((sample.path as NSString).deletingLastPathComponent)
            }
            .map { DiskSample(path: $0.path, bytes: 0, measuredAt: now, plan: plan.kind, simulator: $0.simulator) }
    }
}
