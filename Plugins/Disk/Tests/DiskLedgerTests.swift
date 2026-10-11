import Foundation
import SystemBarKit

/// The Disk tab's ledger: a value type of dated size samples, and the pure functions over it.
@MainActor
enum DiskLedgerTests {
    static func runAll() {
        testAppendingReturnsANewLedgerAndLeavesTheOldOne()
        testLatestIsTheNewestSamplePerPath()
        testSampleAtOrBeforeFindsTheNewestOldEnoughSample()
        testDueRuleUsesThePlansNewestSample()
        testCompactionKeepsEverythingRecentOnePerDayAfterAndNothingOld()
    }

    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    static func sample(_ path: String, _ bytes: UInt64, ago: TimeInterval, plan: DiskPlanKind = .overview) -> DiskSample {
        DiskSample(path: path, bytes: bytes, measuredAt: now.addingTimeInterval(-ago), plan: plan)
    }

    private static func testAppendingReturnsANewLedgerAndLeavesTheOldOne() {
        let empty = DiskLedger()
        let one = empty.appending([sample("/a", 1, ago: 0)])
        expect(empty.samples.isEmpty && one.samples.count == 1, "appending makes a new ledger; the old value is untouched")
        expect(one.version == DiskLedger.currentVersion, "a new ledger carries the current version")
    }

    private static func testLatestIsTheNewestSamplePerPath() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 2 * day),
            sample("/a", 5, ago: 0),
            sample("/b", 7, ago: day),
        ])
        expect(ledger.latest.map { "\($0.path)=\($0.bytes)" } == ["/a=5", "/b=7"], "latest keeps one sample per path, the newest, sorted by path, got \(ledger.latest)")
    }

    private static func testSampleAtOrBeforeFindsTheNewestOldEnoughSample() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 3 * day),
            sample("/a", 2, ago: 2 * day),
            sample("/a", 3, ago: 0),
        ])
        expect(ledger.sample(of: "/a", atOrBefore: now.addingTimeInterval(-day))?.bytes == 2, "the newest sample taken on or before the cut-off, not the newest overall")
        expect(ledger.sample(of: "/a", atOrBefore: now.addingTimeInterval(-4 * day)) == nil, "nothing that old is nil, never a guess")
        expect(ledger.sample(of: "/zzz", atOrBefore: now) == nil, "an unknown path is nil")
    }

    private static func testDueRuleUsesThePlansNewestSample() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 2 * 3600, plan: .overview),
            sample("/b", 1, ago: 7 * 3600, plan: .developer),
        ])
        expect(!ledger.isDue(.overview, cadence: 3 * 3600, now: now), "an overview two hours old is not due on a three-hour cadence")
        expect(ledger.isDue(.developer, cadence: 6 * 3600, now: now), "a developer scan seven hours old is due on a six-hour cadence")
        expect(ledger.isDue(.simulators, cadence: 6 * 3600, now: now), "a plan that never ran is due")
        expect(ledger.newestMeasurement(of: .simulators) == nil, "and has no newest measurement")
    }

    private static func testCompactionKeepsEverythingRecentOnePerDayAfterAndNothingOld() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 31 * day),            // too old: dropped
            sample("/a", 2, ago: 10 * day - 3600),     // day 90: older of two that day
            sample("/a", 3, ago: 10 * day - 7200),     // day 90: kept
            sample("/b", 4, ago: 10 * day - 7200),     // day 90, other path: kept
            sample("/a", 5, ago: day + 3600),          // within two days: kept
            sample("/a", 6, ago: 3600),                // within two days: kept
        ])
        let compacted = ledger.compacted(now: now, full: 2 * day, daily: 30 * day)
        expect(compacted.samples.map(\.bytes) == [3, 4, 5, 6], "two days of everything, then one per path per day, nothing past 30 days, in time order, got \(compacted.samples.map(\.bytes))")
        expect(ledger.samples.count == 6, "compaction returns a new ledger and leaves the old one alone")
    }
}
