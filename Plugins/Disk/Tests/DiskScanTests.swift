import Foundation
import SystemBarKit

/// What a plan measures and in what order, which known paths have vanished, the simctl catalog,
/// and (from Task 9) the measure loop itself.
@MainActor
enum DiskScanTests {
    static func runAll() {
        testPlansResolveRootsAgainstHomeAndKeepTheirCadences()
        testTargetsAreEveryRootsChildrenBiggestKnownFirstWithoutRepeats()
        testSimulatorTargetsCarryTheCatalogOrFallBackToTheUdid()
        testVanishedPathsBecomeZeroSamplesForTheirPlanOnly()
        testSimulatorCatalogParsesSimctlAndPrettifiesTheRuntime()
    }

    static let home = "/Users/ada"
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    /// A fake folder listing: children per parent, absolute paths. Anything unlisted is empty.
    static func lister(_ tree: [String: [String]]) -> (String) -> [String] {
        { parent in (tree[parent] ?? []).map { "\(parent)/\($0)" } }
    }

    private static func testPlansResolveRootsAgainstHomeAndKeepTheirCadences() {
        let overview = DiskScanPlan.plan(.overview)
        expect(overview.resolvedRoots(homeDirectory: home) == [home, "\(home)/Library", "/Applications", "/opt", "/Library"], "an empty root is home, a relative one is under home, an absolute one is itself, got \(overview.resolvedRoots(homeDirectory: home))")
        expect(overview.cadence == DiskSampling.overviewCadence && DiskScanPlan.plan(.developer).cadence == DiskSampling.developerCadence && DiskScanPlan.plan(.simulators).cadence == DiskSampling.simulatorsCadence, "each plan carries its own cadence")
        expect(DiskScanPlan.all.map(\.kind) == [.overview, .developer, .simulators], "plans run in this order when several are due")
        expect(DiskScanPlan.plan(.developer).resolvedRoots(homeDirectory: home).contains("\(home)/Library/Application Support"), "the developer plan reaches into Application Support, because this is a developer's tool")
        expect(DiskScanPlan.plan(.simulators).resolvedRoots(homeDirectory: home) == ["\(home)/Library/Developer/CoreSimulator/Devices"], "the simulator plan measures each device folder")
    }

    private static func testTargetsAreEveryRootsChildrenBiggestKnownFirstWithoutRepeats() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 1, roots: ["", "Library", "/opt"])
        let tree = [
            home: ["Library", "proj", ".cache"],
            "\(home)/Library": ["Developer", "Caches"],
            "/opt": ["homebrew"],
        ]
        let previous = DiskLedger().appending([
            DiskSample(path: "\(home)/proj", bytes: 50, measuredAt: now, plan: .overview),
            DiskSample(path: "\(home)/Library/Developer", bytes: 900, measuredAt: now, plan: .overview),
        ])
        let targets = DiskScanTargets.targets(for: plan, homeDirectory: home, previous: previous, listChildren: lister(tree), catalog: [:])
        expect(targets.map(\.path) == ["\(home)/Library/Developer", "\(home)/proj", "/opt/homebrew", "\(home)/.cache", "\(home)/Library", "\(home)/Library/Caches"],
               "known-biggest first so a spent budget cuts the smallest, then unknown paths by name, got \(targets.map(\.path))")
        expect(targets.allSatisfy { $0.simulator == nil }, "folder targets carry no simulator info")
    }

    private static func testSimulatorTargetsCarryTheCatalogOrFallBackToTheUdid() {
        let plan = DiskScanPlan.plan(.simulators)
        let devices = "\(home)/Library/Developer/CoreSimulator/Devices"
        let known = SimulatorInfo(udid: "AAA", name: "iPhone 17", runtime: "iOS 26.5", lastBootedAt: now)
        let targets = DiskScanTargets.targets(for: plan, homeDirectory: home, previous: DiskLedger(), listChildren: lister([devices: ["AAA", "BBB"]]), catalog: ["AAA": known])
        expect(targets.map(\.path) == ["\(devices)/AAA", "\(devices)/BBB"], "each device folder is a target, got \(targets.map(\.path))")
        expect(targets[0].simulator == known, "a device simctl knows carries its name, runtime and last boot")
        expect(targets[1].simulator == SimulatorInfo(udid: "BBB", name: "BBB", runtime: "unknown runtime", lastBootedAt: nil), "one it does not know is still measured, named by its folder, got \(String(describing: targets[1].simulator))")
    }

    private static func testVanishedPathsBecomeZeroSamplesForTheirPlanOnly() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 1, roots: [""])
        let previous = DiskLedger().appending([
            DiskSample(path: "\(home)/gone", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/stays", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/already-zero", bytes: 0, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/Library/Developer", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/other-plan", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .developer),
        ])
        let targets = [DiskScanTarget(path: "\(home)/stays", simulator: nil)]
        let vanished = DiskScanTargets.vanished(plan: plan, homeDirectory: home, previous: previous, targets: targets, now: now)
        expect(vanished.map(\.path) == ["\(home)/gone"], "only a path this plan measured, directly under one of its roots, that had bytes and is no longer listed, got \(vanished.map(\.path))")
        expect(vanished.first?.bytes == 0 && vanished.first?.measuredAt == now && vanished.first?.plan == .overview, "it is recorded as zero bytes now, so movers can show it as freed")
    }

    private static func testSimulatorCatalogParsesSimctlAndPrettifiesTheRuntime() {
        let json = """
        { "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              { "udid": "AAA", "name": "iPhone 17", "lastBootedAt": "2026-09-18T07:41:44Z", "state": "Shutdown", "dataPath": "/x/AAA/data" },
              { "udid": "BBB", "name": "iPad", "state": "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": []
        } }
        """
        let catalog = SimulatorCatalog.parse(json)
        expect(catalog.count == 2, "one entry per device across runtimes, got \(catalog.keys.sorted())")
        expect(catalog["AAA"]?.name == "iPhone 17" && catalog["AAA"]?.runtime == "iOS 26.5", "the runtime identifier reads as a product and version, got \(String(describing: catalog["AAA"]))")
        expect(catalog["AAA"]?.lastBootedAt == Date(timeIntervalSince1970: 1_789_717_304), "the last boot parses as a date")
        expect(catalog["BBB"]?.lastBootedAt == nil, "a device that never booted has none")
        expect(SimulatorCatalog.parse("not json").isEmpty && SimulatorCatalog.parse("").isEmpty, "unparseable output is an empty catalog, never a crash")
        expect(SimulatorCatalog.runtimeLabel("com.apple.CoreSimulator.SimRuntime.xrOS-3-1") == "xrOS 3.1" && SimulatorCatalog.runtimeLabel("odd") == "odd", "labels: product, space, dotted version; anything else as written")
    }
}
