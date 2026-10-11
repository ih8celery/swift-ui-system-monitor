import Foundation

/// Which scan plan measured a sample. Also the key for "when did this plan last run".
enum DiskPlanKind: String, Codable, CaseIterable, Sendable {
    case overview, developer, simulators

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .developer: return "Developer"
        case .simulators: return "Simulators"
        }
    }
}

/// What `simctl` knows about one simulator device, carried on its sample so a row can say
/// which device it is and when it last booted.
struct SimulatorInfo: Codable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let lastBootedAt: Date?
}

/// One measurement of one folder. `bytes` of zero means the folder was gone or empty when the
/// plan looked; the movers list shows a path that went from something to zero as freed.
/// `measuredAt` is kept rounded down to a whole second, because the ledger file keeps whole
/// seconds and memory and disk must agree.
struct DiskSample: Codable, Equatable, Sendable {
    let path: String
    let bytes: UInt64
    let measuredAt: Date
    let plan: DiskPlanKind
    let simulator: SimulatorInfo?

    init(path: String, bytes: UInt64, measuredAt: Date, plan: DiskPlanKind, simulator: SimulatorInfo? = nil) {
        self.path = path
        self.bytes = bytes
        self.measuredAt = Date(timeIntervalSince1970: measuredAt.timeIntervalSince1970.rounded(.down))
        self.plan = plan
        self.simulator = simulator
    }
}

/// Every sample the Disk tab has kept, as a value: applying samples or compacting returns a new
/// ledger. The derived views (newest per path, a sample from a day ago, which plan is due) are
/// pure functions, so they are tested with hand-built samples and fixed dates.
struct DiskLedger: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = DiskLedger.currentVersion
    var samples: [DiskSample] = []

    func appending(_ new: [DiskSample]) -> DiskLedger {
        DiskLedger(version: version, samples: samples + new)
    }

    /// The newest sample of each path, sorted by path.
    var latest: [DiskSample] {
        var byPath: [String: DiskSample] = [:]
        for sample in samples {
            if let current = byPath[sample.path], current.measuredAt >= sample.measuredAt { continue }
            byPath[sample.path] = sample
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    /// The newest sample of `path` taken at or before `date`, or nil: a comparison with nothing
    /// to compare against says so rather than inventing a zero.
    func sample(of path: String, atOrBefore date: Date) -> DiskSample? {
        samples
            .filter { $0.path == path && $0.measuredAt <= date }
            .max { $0.measuredAt < $1.measuredAt }
    }

    func newestMeasurement(of plan: DiskPlanKind) -> Date? {
        samples.filter { $0.plan == plan }.map(\.measuredAt).max()
    }

    /// A plan is due when it has never run or its newest sample is older than its cadence.
    func isDue(_ plan: DiskPlanKind, cadence: TimeInterval, now: Date) -> Bool {
        guard let newest = newestMeasurement(of: plan) else { return true }
        return now.timeIntervalSince(newest) >= cadence
    }

    /// Retention: every sample younger than `full`; one per path per day (UTC day number, so
    /// the result never depends on the machine's calendar) between `full` and `daily`; nothing
    /// older than `daily`. Returned in time order, then path order, so saves are stable.
    func compacted(now: Date, full: TimeInterval = DiskSampling.fullRetention, daily: TimeInterval = DiskSampling.dailyRetention) -> DiskLedger {
        let fullCutoff = now.addingTimeInterval(-full)
        let dailyCutoff = now.addingTimeInterval(-daily)
        var recent: [DiskSample] = []
        var lastOfDay: [String: DiskSample] = [:]
        for sample in samples {
            if sample.measuredAt < dailyCutoff { continue }
            if sample.measuredAt >= fullCutoff {
                recent.append(sample)
                continue
            }
            let dayNumber = Int((sample.measuredAt.timeIntervalSince1970 / 86_400).rounded(.down))
            let key = "\(sample.path)|\(dayNumber)"
            if let kept = lastOfDay[key], kept.measuredAt >= sample.measuredAt { continue }
            lastOfDay[key] = sample
        }
        let kept = (Array(lastOfDay.values) + recent).sorted {
            $0.measuredAt != $1.measuredAt ? $0.measuredAt < $1.measuredAt : $0.path < $1.path
        }
        return DiskLedger(version: version, samples: kept)
    }
}
