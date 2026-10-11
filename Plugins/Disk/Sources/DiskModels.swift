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

    /// A copy with the rows derived from `ledger`; the volume and scan fields are left alone.
    func applying(ledger: DiskLedger, homeDirectory: String, now: Date) -> DiskSnapshot {
        var next = self
        let rows = DiskRows.rows(from: ledger, homeDirectory: homeDirectory)
        next.biggest = DiskRows.biggest(rows)
        next.movers24h = DiskRows.movers(rows: rows, ledger: ledger, window: 86_400, now: now)
        next.movers7d = DiskRows.movers(rows: rows, ledger: ledger, window: 7 * 86_400, now: now)
        next.simulators = DiskRows.simulatorRows(from: ledger)
        next.planAges = Dictionary(uniqueKeysWithValues: DiskPlanKind.allCases.compactMap { kind in
            ledger.newestMeasurement(of: kind).map { (kind, $0) }
        })
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
}

/// What one 30-second volume read found.
struct DiskVolumeReading {
    let volumes: [DiskVolume]
    let localSnapshotCount: Int
    let sampledAt: Date

    var status: String { volumes.isEmpty ? "No readable volumes found" : "Disk sample OK" }
    var health: SampleHealth { SampleHealth(isOK: !volumes.isEmpty) }
}
