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

    private static func testDisplayPathShortensHome() {
        expect(DiskRows.displayPath("\(home)/proj", homeDirectory: home) == "~/proj", "paths under home read as ~/...")
        expect(DiskRows.displayPath(home, homeDirectory: home) == "~", "home itself is ~")
        expect(DiskRows.displayPath("/opt", homeDirectory: home) == "/opt", "others are as they are")
    }
}
