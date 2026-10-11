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
        testUnreadableRootsKeepTheirEarlierSamples()
        testSimulatorCatalogParsesSimctlAndPrettifiesTheRuntime()
        testMeasureRecordsEachFinishedRowAndCountsTheRest()
        testMeasureStopsAtTheBudgetAndCountsWhatItSkipped()
        testMeasureStopsCheckingOnceTheBudgetIsSpent()
        testDiskUsageThatWouldOverflowIsUnparseable()
        testScannerRunsDuAndSimctlThroughTheHost()
        testOutcomeStatusNamesEveryWayARowCanBeMissing()
    }

    static let home = "/Users/ada"
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    /// A fake folder listing: children per parent, absolute paths. An unlisted parent could not
    /// be listed (nil), as a missing or unreadable folder would be.
    static func lister(_ tree: [String: [String]]) -> (String) -> [String]? {
        { parent in tree[parent]?.map { "\(parent)/\($0)" } }
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
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 1, roots: ["", "Library", "/opt", "Library"])
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
        let devices = "\(home)/Library/Developer/CoreSimulator/Devices"
        let deletedDevice = SimulatorInfo(udid: "AAA", name: "iPhone 17", runtime: "iOS 26.5", lastBootedAt: nil)
        let previous = DiskLedger().appending([
            DiskSample(path: "\(home)/gone", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/stays", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/already-zero", bytes: 0, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/Library/Developer", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/other-plan", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .developer),
            DiskSample(path: "\(devices)/AAA", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .simulators, simulator: deletedDevice),
        ])
        let targets = [DiskScanTarget(path: "\(home)/stays", simulator: nil)]
        let vanished = DiskScanTargets.vanished(plan: plan, listedRoots: [home], previous: previous, targets: targets, now: now)
        expect(vanished.map(\.path) == ["\(home)/gone"], "only a path this plan measured, directly under one of its roots, that had bytes and is no longer listed, got \(vanished.map(\.path))")
        expect(vanished.first?.bytes == 0 && vanished.first?.measuredAt == now && vanished.first?.plan == .overview, "it is recorded as zero bytes now, so movers can show it as freed")
        let simulators = DiskScanTargets.vanished(plan: .plan(.simulators), listedRoots: [devices], previous: previous, targets: [], now: now)
        expect(simulators.map(\.path) == ["\(devices)/AAA"] && simulators.first?.simulator == deletedDevice, "a deleted device keeps its simulator info so the freed row still names it, got \(simulators)")
    }

    private static func testUnreadableRootsKeepTheirEarlierSamples() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 1, roots: [""])
        let previous = DiskLedger().appending([
            DiskSample(path: "\(home)/gone", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/stays", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
        ])
        let vanished = DiskScanTargets.vanished(plan: plan, listedRoots: [], previous: previous, targets: [], now: now)
        expect(vanished.isEmpty, "a root that could not be listed says nothing about its children, so none is marked freed, got \(vanished.map(\.path))")
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

    static func duFinished(_ path: String, kilobytes: UInt64) -> CommandOutput {
        CommandOutput(output: "\(kilobytes)\t\(path)\n", error: "", status: 0, didTimeout: false)
    }

    private static func testMeasureRecordsEachFinishedRowAndCountsTheRest() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 100, roots: [""])
        let targets = ["/a", "/slow", "/denied", "/b"].map { DiskScanTarget(path: $0, simulator: nil) }
        var rows: [DiskSample] = []
        let outcome = DiskScanner.measure(targets: targets, plan: plan, now: { now }, elapsed: { 0 }, measure: { path in
            switch path {
            case "/a": return duFinished("/a", kilobytes: 2)
            case "/b": return duFinished("/b", kilobytes: 3)
            case "/slow": return CommandOutput(output: "", error: "", status: 15, didTimeout: true)
            default: return CommandOutput(output: "", error: "du: /denied: Operation not permitted", status: 1, didTimeout: false)
            }
        }, onRow: { rows.append($0) })
        expect(rows.map { "\($0.path)=\($0.bytes)" } == ["/a=2048", "/b=3072"], "each finished du becomes a sample in bytes, as it finishes, got \(rows)")
        expect(rows.allSatisfy { $0.measuredAt == now && $0.plan == .overview }, "stamped now, for this plan")
        expect(outcome == DiskScanOutcome(measured: 2, timedOut: 1, unreadable: 1, unmeasured: 0), "the outcome counts every way a row can be missing, got \(outcome)")
    }

    private static func testMeasureStopsAtTheBudgetAndCountsWhatItSkipped() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 10, roots: [""])
        let targets = ["/a", "/b", "/c"].map { DiskScanTarget(path: $0, simulator: nil) }
        var clock: TimeInterval = 0
        var rows: [DiskSample] = []
        let outcome = DiskScanner.measure(targets: targets, plan: plan, now: { now }, elapsed: { clock }, measure: { path in
            clock += 6
            return duFinished(path, kilobytes: 1)
        }, onRow: { rows.append($0) })
        expect(rows.map(\.path) == ["/a", "/b"], "the budget is checked before each du: the first two fit, the third is skipped, got \(rows.map(\.path))")
        expect(outcome.unmeasured == 1 && outcome.measured == 2, "and the skipped one is counted, got \(outcome)")
    }

    private static func testMeasureStopsCheckingOnceTheBudgetIsSpent() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 10, roots: [""])
        let targets = ["/a", "/b", "/c", "/d"].map { DiskScanTarget(path: $0, simulator: nil) }
        var clock: TimeInterval = 0
        var clockReads = 0
        var duRuns: [String] = []
        let outcome = DiskScanner.measure(targets: targets, plan: plan, now: { now }, elapsed: { clockReads += 1; return clock }, measure: { path in
            duRuns.append(path)
            clock += 60
            return duFinished(path, kilobytes: 1)
        }, onRow: { _ in })
        expect(duRuns == ["/a"], "a budget spent by the first du runs no further du, got \(duRuns)")
        expect(outcome == DiskScanOutcome(measured: 1, timedOut: 0, unreadable: 0, unmeasured: 3), "every target after it counts as not measured, got \(outcome)")
        expect(clockReads == 2, "the loop stops at the spent budget rather than reading the clock once per remaining target, got \(clockReads)")
    }

    private static func testDiskUsageThatWouldOverflowIsUnparseable() {
        expect(DiskScanner.parseDiskUsage("\(UInt64.max)\t/huge\n").isEmpty, "a kilobyte count too big for bytes is no answer rather than a wrapped one")
        expect(DiskScanner.parseDiskUsage("2\t/a\n").first?.bytes == 2048, "an ordinary count converts to bytes")
    }

    private static func testScannerRunsDuAndSimctlThroughTheHost() {
        let recorder = LogRecorder()
        let devices = "/tmp/systembar-tests/Library/Developer/CoreSimulator/Devices"
        let simctl = #"{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [ { "udid": "AAA", "name": "iPhone 17" } ] } }"#
        let host = makeHost(runner: recordingRunner(recorder, answers: [
            "/usr/bin/xcrun simctl list devices -j": simctl,
            "/usr/bin/du -s -k -x \(devices)/AAA": "5\t\(devices)/AAA\n",
        ]))
        let scanner = DiskScanner(host: host, listChildren: lister([devices: ["AAA"]]))
        var rows: [DiskSample] = []
        let outcome = scanner.run(plan: .plan(.simulators), previous: DiskLedger(), onRow: { rows.append($0) })
        expect(recorder.messages == ["/usr/bin/xcrun simctl list devices -j", "/usr/bin/du -s -k -x \(devices)/AAA"], "simctl once, then one du per device, all by explicit path through the host, got \(recorder.messages)")
        expect(rows.count == 1 && rows.first?.bytes == 5 * 1024 && rows.first?.simulator?.name == "iPhone 17", "the device row carries simctl's name, got \(rows)")
        expect(outcome.measured == 1, "and counts as measured")
    }

    private static func testOutcomeStatusNamesEveryWayARowCanBeMissing() {
        expect(DiskScanOutcome(measured: 1, timedOut: 0, unreadable: 0, unmeasured: 0).status == "Measured 1 path", "singular")
        expect(DiskScanOutcome(measured: 3, timedOut: 1, unreadable: 2, unmeasured: 4).status == "Measured 3 paths, 1 too slow to finish, 2 unreadable (needs Full Disk Access?), 4 not measured, scan budget spent", "each nonzero count gets a clause, got \(DiskScanOutcome(measured: 3, timedOut: 1, unreadable: 2, unmeasured: 4).status)")
        expect(DiskScanOutcome().status == "Measured 0 paths", "zero measured is said plainly")
    }
}
