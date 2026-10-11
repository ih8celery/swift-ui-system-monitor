import Foundation
import SystemBarKit

struct DiskVolume: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    /// Plain free space, what `df` calls available. Space macOS could purge is not counted:
    /// it is still on the disk, and the map on this tab is of what is on the disk.
    let free: UInt64
    let isRoot: Bool

    var used: UInt64 {
        total > free ? total - free : 0
    }

    var freeRatio: Double {
        Double(free) / Double(max(total, 1))
    }
}

/// Everything the panel draws. Volume fields come from each 30-second reading; the row fields
/// are derived from the ledger whenever it changes; the scan fields say what is running now.
struct DiskSnapshot {
    var volumes: [DiskVolume] = []
    var localSnapshotCount = 0
    var status = "Waiting for disk sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?

    var biggest: [DiskRow] = []
    var movers24h: [DiskMover] = []
    var movers7d: [DiskMover] = []
    var simulators: [DiskRow] = []
    /// When each plan last measured anything; absent for a plan that never ran.
    var planAges: [DiskPlanKind: Date] = [:]

    var isScanning = false
    var scanStatus = "No scan yet"
    /// The saved ledger could not be read and was moved aside. Stays for the session: the old
    /// sizes are gone however later saves go.
    var ledgerNote: String?
    /// The last save failed, worded for the footer; cleared by the next save that succeeds.
    var saveProblem: String?
    /// The last plan runs that did not measure everything, worded for the footer; nil when the
    /// last run of every plan measured every target.
    var scanWarning: String?
    /// A settings value the plugin could not use, worded for the footer.
    var settingsProblem: String?

    var boot: DiskVolume? {
        volumes.first(where: \.isRoot)
    }

    var otherVolumes: [DiskVolume] {
        volumes.filter { !$0.isRoot }
    }

    /// A copy with a volume reading applied; everything else is left alone.
    func applying(_ reading: DiskVolumeReading) -> DiskSnapshot {
        var next = self
        next.volumes = reading.volumes
        next.localSnapshotCount = reading.localSnapshotCount
        next.status = reading.status
        next.health = reading.health
        next.lastUpdated = reading.sampledAt
        return next
    }

    /// A copy with derived rows applied; the volume and scan fields are left alone. Only copies,
    /// so it is cheap enough to run on main.
    func applying(_ derived: DiskDerivedRows) -> DiskSnapshot {
        var next = self
        next.biggest = derived.biggest
        next.movers24h = derived.movers24h
        next.movers7d = derived.movers7d
        next.simulators = derived.simulators
        next.planAges = derived.planAges
        return next
    }

    func scanning(_ isScanning: Bool, status: String) -> DiskSnapshot {
        var next = self
        next.isScanning = isScanning
        next.scanStatus = status
        return next
    }

    func noting(_ note: String) -> DiskSnapshot {
        var next = self
        next.ledgerNote = note
        return next
    }

    /// A copy with the save outcome applied: a problem to show, or nil after a save that worked.
    func savingProblem(_ problem: String?) -> DiskSnapshot {
        var next = self
        next.saveProblem = problem
        return next
    }

    /// A copy with the incomplete-scan summary applied, or nil once every plan measured everything.
    func warning(_ text: String?) -> DiskSnapshot {
        var next = self
        next.scanWarning = text
        return next
    }
}

/// The snapshot's ledger-derived fields. Deriving them takes several passes over every sample,
/// so the plugin does it on its scan queue and hands main only the result.
struct DiskDerivedRows {
    let biggest: [DiskRow]
    let movers24h: [DiskMover]
    let movers7d: [DiskMover]
    let simulators: [DiskRow]
    /// When each plan last measured anything; absent for a plan that never ran.
    let planAges: [DiskPlanKind: Date]

    static func derive(from ledger: DiskLedger, homeDirectory: String, now: Date) -> DiskDerivedRows {
        let rows = DiskRows.rows(from: ledger, homeDirectory: homeDirectory)
        return DiskDerivedRows(
            biggest: DiskRows.biggest(rows),
            movers24h: DiskRows.movers(rows: rows, ledger: ledger, window: 86_400, now: now),
            movers7d: DiskRows.movers(rows: rows, ledger: ledger, window: 7 * 86_400, now: now),
            simulators: DiskRows.simulatorRows(from: ledger),
            planAges: Dictionary(uniqueKeysWithValues: DiskPlanKind.allCases.compactMap { kind in
                ledger.newestMeasurement(of: kind).map { (kind, $0) }
            })
        )
    }
}

/// How often the Disk tab samples, and how long its scans may run. The README's interval table
/// quotes these, so change them together.
enum DiskSampling {
    /// Volumes and `tmutil` while the tab shows.
    static let refreshInterval: TimeInterval = 30
    /// The host's `collect()` while the tab is hidden: a due check, and the scans it starts.
    static let backgroundInterval: TimeInterval = 900
    /// One `du` per row. Generous, because `~/Library` alone takes a minute warm and far longer
    /// cold; bounded, so one pathological tree cannot hold a plan open.
    static let rowTimeout: TimeInterval = 300
    /// Each plan's whole-run ceiling, well under every cadence so plans never overlap.
    static let planBudget: TimeInterval = 900
    static let overviewCadence: TimeInterval = 3 * 3600
    static let developerCadence: TimeInterval = 6 * 3600
    static let simulatorsCadence: TimeInterval = 6 * 3600
    /// Every sample is kept this long, so same-day comparisons work.
    static let fullRetention: TimeInterval = 2 * 86_400
    /// After that, one sample per path per day up to this age; nothing older.
    static let dailyRetention: TimeInterval = 30 * 86_400
    /// The fastest the list refreshes while a plan runs. Rows still appear as trees finish, but a
    /// burst of small folders cannot queue a derivation per folder on main.
    static let previewInterval: TimeInterval = 1
}

/// What one 30-second volume read found.
struct DiskVolumeReading {
    let volumes: [DiskVolume]
    let localSnapshotCount: Int
    let sampledAt: Date

    var status: String { volumes.isEmpty ? "No readable volumes found" : "Disk sample OK" }
    var health: SampleHealth { SampleHealth(isOK: !volumes.isEmpty) }
}
