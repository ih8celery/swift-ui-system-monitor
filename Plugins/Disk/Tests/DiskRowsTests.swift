import Foundation
import SwiftUI
import SystemBarKit

/// From ledger to panel: the deepest-level rows, parent remainders, the simulator group, movers
/// over a window, and the left column's distribution segments.
@MainActor
enum DiskRowsTests {
    static func runAll() {
        testRowsShowTheDeepestMeasuredLevelAndAParentsRemainder()
        testRowsFoldSimulatorDevicesIntoOneGroupDatedByTheOldest()
        testBiggestRanksBySizeAndHidesEmptyRows()
        testMoversRankByAbsoluteChangeAndNameNewAndFreed()
        testMoversSayNothingForARowWithNoEarlierSample()
        testDistributionIsTopRowsThenEverythingElseThenFree()
        testDisplayPathShortensHome()
        testDirectChildrenIgnoresPrefixSiblings()
        testRemainderClampsWhenChildrenOutgrowTheParent()
        testMoversStaySilentAfterAFirstScan()
        testMoversNameANewPathOnlyWhenItsPlanHadLookedBefore()
        testMoversListSimulatorDevicesNotTheGroup()
        testDeletedDevicesLeaveTheGroupCountAndList()
        testSampleHistoryAgreesWithTheLedgerOnTies()
        testDeletingTheLastSimulatorShowsAsFreed()
    }

    private static func testDeletingTheLastSimulatorShowsAsFreed() {
        let ledger = DiskLedger().appending([
            sample("\(devices)/A", 20, ago: 2 * day, plan: .simulators, simulator: deviceA),
            sample("\(devices)/A", 0, plan: .simulators, simulator: deviceA),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        expect(!rows.contains { $0.kind == .simulatorGroup }, "no device left means no group row, got \(rows.map(\.name))")
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.map(\.change) == [.freed(20)] && movers.first?.row.path == "\(home)/\(devices)/A", "the last deleted device still shows as freed, got \(movers)")
    }

    static let home = "/Users/ada"
    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    static func sample(_ path: String, _ bytes: UInt64, ago: TimeInterval = 0, plan: DiskPlanKind = .overview, simulator: SimulatorInfo? = nil) -> DiskSample {
        DiskSample(path: "\(home)/\(path)", bytes: bytes, measuredAt: now.addingTimeInterval(-ago), plan: plan, simulator: simulator)
    }

    private static func testRowsShowTheDeepestMeasuredLevelAndAParentsRemainder() {
        let ledger = DiskLedger().appending([
            sample("Library", 100),
            sample("Library/Developer", 60),
            sample("Library/Caches", 10),
            sample("Library/Developer/Xcode/DerivedData", 25),
            sample("proj", 40),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        expect(byName["DerivedData"]?.bytes == 25 && byName["DerivedData"]?.kind == .folder, "a folder with no measured descendant is a plain row")
        expect(byName["proj"]?.bytes == 40, "so is a top-level folder")
        expect(byName["Developer (rest)"]?.bytes == 35 && byName["Developer (rest)"]?.kind == .remainder, "a parent shows only what its measured children do not explain: 60 - 25, got \(String(describing: byName["Developer (rest)"]))")
        expect(byName["Library (rest)"]?.bytes == 30, "Library's direct measured children are Developer and Caches, not DerivedData: 100 - 60 - 10, got \(String(describing: byName["Library (rest)"]))")
        expect(byName["Library"] == nil && byName["Developer"] == nil, "a parent never appears whole beside its children")
        expect(rows.count == 5, "one row per measured path, got \(rows.map(\.name))")
    }

    private static func testRowsFoldSimulatorDevicesIntoOneGroupDatedByTheOldest() {
        let a = SimulatorInfo(udid: "A", name: "iPhone 17", runtime: "iOS 26.5", lastBootedAt: now)
        let b = SimulatorInfo(udid: "B", name: "iPad", runtime: "iOS 26.5", lastBootedAt: nil)
        let ledger = DiskLedger().appending([
            sample("Library/Developer", 100),
            sample("Library/Developer/CoreSimulator/Devices/A", 30, ago: 3600, plan: .simulators, simulator: a),
            sample("Library/Developer/CoreSimulator/Devices/B", 20, plan: .simulators, simulator: b),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let group = rows.first { $0.kind == .simulatorGroup }
        expect(group?.name == "Simulators · 2 devices" && group?.bytes == 50, "devices fold into one group row with their count and total, got \(String(describing: group))")
        expect(group?.path == "\(home)/Library/Developer/CoreSimulator/Devices", "the group sits at the Devices folder")
        expect(group?.measuredAt == now.addingTimeInterval(-3600), "the group is as old as its oldest device, never flattered")
        expect(rows.first { $0.name == "Developer (rest)" }?.bytes == 50, "the group counts as Developer's measured child: 100 - 50")
        let devices = DiskRows.simulatorRows(from: ledger)
        expect(devices.map(\.name) == ["iPhone 17 · iOS 26.5", "iPad · iOS 26.5"], "device rows are named by simctl and sorted by size, got \(devices.map(\.name))")
        expect(devices.first?.simulator?.lastBootedAt == now && devices.first?.kind == .simulator, "and carry the simulator info")
    }

    private static func testBiggestRanksBySizeAndHidesEmptyRows() {
        let rows = [
            DiskRow(name: "small", path: "/s", bytes: 1, measuredAt: now, kind: .folder, simulator: nil),
            DiskRow(name: "gone", path: "/g", bytes: 0, measuredAt: now, kind: .folder, simulator: nil),
            DiskRow(name: "big", path: "/b", bytes: 9, measuredAt: now, kind: .folder, simulator: nil),
        ]
        expect(DiskRows.biggest(rows).map(\.name) == ["big", "small"], "biggest first, zero-byte rows left out, got \(DiskRows.biggest(rows).map(\.name))")
        expect(DiskRows.biggest(rows, limit: 1).map(\.name) == ["big"], "the limit cuts the tail")
    }

    private static func testMoversRankByAbsoluteChangeAndNameNewAndFreed() {
        let ledger = DiskLedger().appending([
            sample("grew", 10, ago: 2 * day), sample("grew", 40),
            sample("shrank", 50, ago: 2 * day), sample("shrank", 45),
            sample("freed", 20, ago: 2 * day), sample("freed", 0),
            sample("fresh", 7, ago: 3600),
            sample("same", 5, ago: 2 * day), sample("same", 5),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.map(\.row.name) == ["grew", "freed", "fresh", "shrank"], "ranked by the size of the change; unchanged rows are absent, got \(movers.map(\.row.name))")
        expect(movers[0].change == .grew(30) && movers[1].change == .freed(20), "a growth and a path that went to zero")
        expect(movers[2].change == .new && movers[3].change == .shrank(5), "a path first seen inside the window is new; a shrink is a shrink")
    }

    private static func testMoversSayNothingForARowWithNoEarlierSample() {
        let ledger = DiskLedger().appending([sample("old", 7, ago: 3 * day)])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.isEmpty, "a row measured once, before the window, has no change to report and is not called new, got \(movers)")
    }

    private static func testDistributionIsTopRowsThenEverythingElseThenFree() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 200, isRoot: true)
        let biggest = [
            DiskRow(name: "Simulators · 3 devices", path: "/sims", bytes: 300, measuredAt: now, kind: .simulatorGroup, simulator: nil),
            DiskRow(name: "proj", path: "/Users/ada/proj", bytes: 100, measuredAt: now, kind: .folder, simulator: nil),
            DiskRow(name: "proj", path: "/opt/proj", bytes: 50, measuredAt: now, kind: .folder, simulator: nil),
        ]
        let segments = DiskRows.distribution(biggest: biggest, volume: volume, homeDirectory: home, limit: 2)
        expect(segments.map(\.label) == ["Simulators · 3 devices", "proj", "Everything else", "Free"], "the top rows, then the rest of used, then free, got \(segments.map(\.label))")
        expect(segments.map(\.value) == [300, 100, 400, 200], "everything else is used minus the shown rows: 800 - 400, got \(segments.map(\.value))")
        let all = DiskRows.distribution(biggest: biggest, volume: volume, homeDirectory: home, limit: 3)
        expect(all.map(\.label) == ["Simulators · 3 devices", "proj", "proj · /opt/proj", "Everything else", "Free"], "a repeated name gets its path, because a legend needs distinct labels, got \(all.map(\.label))")
    }

    private static func testDirectChildrenIgnoresPrefixSiblings() {
        let paths = ["/a/b", "/a/bc"]
        expect(DiskRows.directChildren(of: "/a", among: paths).sorted() == paths, "a path that merely starts with a sibling's name is a sibling, got \(DiskRows.directChildren(of: "/a", among: paths))")
        expect(DiskRows.directChildren(of: "/a/b", among: paths).isEmpty, "/a/bc is not inside /a/b")
    }

    private static func testRemainderClampsWhenChildrenOutgrowTheParent() {
        let ledger = DiskLedger().appending([
            sample("p", 10),
            sample("p/c", 25, ago: 3600),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let rest = rows.first { $0.name == "p (rest)" }
        expect(rest?.bytes == 0 && rest?.kind == .remainder, "a child measured later and bigger than its parent leaves a zero remainder, not an underflow, got \(String(describing: rest))")
        expect(!DiskRows.biggest(rows).contains { $0.name == "p (rest)" }, "and a zero remainder is not listed")
        expect(rest?.measuredAt == now.addingTimeInterval(-3600), "a remainder is as old as the oldest of its parent and children")
    }

    private static func testMoversStaySilentAfterAFirstScan() {
        let ledger = DiskLedger().appending([sample("a", 10, ago: 3600), sample("b", 5)])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.isEmpty, "a plan that never ran before the window cannot call anything new, got \(movers.map(\.row.name))")
    }

    private static func testMoversNameANewPathOnlyWhenItsPlanHadLookedBefore() {
        let ledger = DiskLedger().appending([
            sample("x", 5, ago: 2 * day), sample("x", 5), sample("y", 3),
            sample("z", 9, plan: .developer),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.map(\.row.name) == ["y"] && movers.first?.change == .new, "the overview looked two days ago and did not see y, so y is new; the developer plan had never looked, so z is silent, got \(movers)")
    }

    static let deviceA = SimulatorInfo(udid: "A", name: "iPhone 17", runtime: "iOS 26.5", lastBootedAt: nil)
    static let deviceB = SimulatorInfo(udid: "B", name: "iPad", runtime: "iOS 26.5", lastBootedAt: nil)
    static let deviceC = SimulatorInfo(udid: "C", name: "iPhone SE", runtime: "iOS 18.0", lastBootedAt: nil)
    static let devices = "Library/Developer/CoreSimulator/Devices"

    /// A and B measured two days ago; today A grew, B is gone and C is new.
    static func deviceLedger() -> DiskLedger {
        DiskLedger().appending([
            sample("\(devices)/A", 30, ago: 2 * day, plan: .simulators, simulator: deviceA),
            sample("\(devices)/B", 20, ago: 2 * day, plan: .simulators, simulator: deviceB),
            sample("\(devices)/A", 35, plan: .simulators, simulator: deviceA),
            sample("\(devices)/B", 0, plan: .simulators, simulator: deviceB),
            sample("\(devices)/C", 10, plan: .simulators, simulator: deviceC),
        ])
    }

    private static func testMoversListSimulatorDevicesNotTheGroup() {
        let ledger = deviceLedger()
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.map(\.row.path) == ["B", "C", "A"].map { "\(home)/\(devices)/\($0)" }, "each device is ranked on its own: freed 20, new 10, grew 5, got \(movers.map(\.row.path))")
        expect(movers.map(\.change) == [.freed(20), .new, .grew(5)], "got \(movers.map(\.change))")
        expect(movers.allSatisfy { $0.row.kind == .simulator }, "the group never appears among movers")
        expect(movers.first?.row.name == "iPad · iOS 26.5", "a device mover is named as the device list names it")
    }

    private static func testDeletedDevicesLeaveTheGroupCountAndList() {
        let ledger = deviceLedger()
        let group = DiskRows.rows(from: ledger, homeDirectory: home).first { $0.kind == .simulatorGroup }
        expect(group?.name == "Simulators · 2 devices" && group?.bytes == 45, "a device measured at zero is gone and not counted, got \(String(describing: group))")
        expect(DiskRows.simulatorRows(from: ledger).map(\.name) == ["iPhone 17 · iOS 26.5", "iPhone SE · iOS 18.0"], "nor listed, got \(DiskRows.simulatorRows(from: ledger).map(\.name))")
    }

    private static func testSampleHistoryAgreesWithTheLedgerOnTies() {
        let ledger = DiskLedger().appending([sample("t", 1, ago: 2 * day), sample("t", 2, ago: 2 * day), sample("t", 5)])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        let ledgerEarlier = ledger.sample(of: "\(home)/t", atOrBefore: now.addingTimeInterval(-day))?.bytes
        expect(ledgerEarlier == 1 && movers.first?.change == .grew(4), "two samples at one instant: the movers compare with the one the ledger picks, got \(movers.map(\.change)) against \(String(describing: ledgerEarlier))")
    }

    private static func testDisplayPathShortensHome() {
        expect(DiskRows.displayPath("\(home)/proj", homeDirectory: home) == "~/proj", "paths under home read as ~/...")
        expect(DiskRows.displayPath(home, homeDirectory: home) == "~", "home itself is ~")
        expect(DiskRows.displayPath("/opt", homeDirectory: home) == "/opt", "others are as they are")
    }
}
