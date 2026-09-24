import Foundation

/// Whether a background sample came back clean, decoupled from the human-readable status text
/// shown next to it — so UI coloring never depends on matching that text verbatim.
enum SampleHealth {
    case ok
    case degraded

    init(isOK: Bool) {
        self = isOK ? .ok : .degraded
    }
}

struct ProcessSnapshot: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
    let physical: UInt64
    let virtualSize: UInt64
    let cpu: Double
}

/// Turns `ps` pcpu (a percentage of a *single* core) into a whole-machine
/// 0-100 percentage so per-process numbers share the headline's denominator.
enum ProcessCPUScale {
    /// Summed pcpu divided by the active core count.
    /// `grep` at 89% of one core on 8 cores -> ~11%; `clang (26)` summing to 620% -> ~78%.
    static func wholeMachinePercent(summedPcpu: Double, coreCount: Int) -> Double {
        guard coreCount > 0 else { return 0 }
        return summedPcpu / Double(coreCount)
    }

    /// Absolute share of the machine as a 0-1 bar fraction (not a rank against other rows).
    static func barFraction(wholeMachinePercent: Double) -> Double {
        min(max(wholeMachinePercent / 100, 0), 1)
    }
}

struct BoundedHistory {
    static func append(_ value: Double, to values: inout [Double], limit: Int) {
        values.append(value)
        let overflow = values.count - limit
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}

struct FastStatsSnapshot {
    var currentDownloadRate: Double = 0
    var currentUploadRate: Double = 0
    var cpuUsagePercent: Double = 0
    var cpuHistory: [Double] = []
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
}

struct ProcessSummary {
    /// Every displayed row groups by process name; only the groups that land in that display
    /// need a per-PID rusage syscall, so the snapshot pass and this slice share these limits.
    static let memoryDisplayLimit = 18
    static let cpuDisplayLimit = 28

    var totalCount = 0
    var topMemory: [ProcessSnapshot] = []
    var topCPU: [ProcessSnapshot] = []
    var maxPhysical: UInt64 = 1

    init() {}

    init(rows: [ProcessSnapshot], limit: Int) {
        self.init(rows: rows, memoryLimit: limit, cpuLimit: limit)
    }

    init(
        rows: [ProcessSnapshot],
        memoryLimit: Int = ProcessSummary.memoryDisplayLimit,
        cpuLimit: Int = ProcessSummary.cpuDisplayLimit
    ) {
        totalCount = rows.count
        topMemory = Array(rows.sorted { $0.physical > $1.physical }.prefix(memoryLimit))
        topCPU = Array(rows.sorted { $0.cpu > $1.cpu }.prefix(cpuLimit))
        maxPhysical = max(rows.map(\.physical).max() ?? 1, 1)
    }
}
