import Foundation

/// Whether a background sample came back clean, decoupled from the human-readable status text
/// shown next to it — so UI coloring never depends on matching that text verbatim.
public enum SampleHealth: Sendable {
    case ok
    case degraded

    public init(isOK: Bool) {
        self = isOK ? .ok : .degraded
    }
}

public struct ProcessSnapshot: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int
    public let physical: UInt64
    public let virtualSize: UInt64
    public let cpu: Double

    public init(name: String, count: Int, physical: UInt64, virtualSize: UInt64, cpu: Double) {
        self.name = name
        self.count = count
        self.physical = physical
        self.virtualSize = virtualSize
        self.cpu = cpu
    }
}

/// Turns `ps` pcpu (a percentage of a *single* core) into a whole-machine
/// 0-100 percentage so per-process numbers share the headline's denominator.
public enum ProcessCPUScale {
    /// Summed pcpu divided by the active core count.
    /// `grep` at 89% of one core on 8 cores -> ~11%; `clang (26)` summing to 620% -> ~78%.
    public static func wholeMachinePercent(summedPcpu: Double, coreCount: Int) -> Double {
        guard coreCount > 0 else { return 0 }
        return summedPcpu / Double(coreCount)
    }

    /// Absolute share of the machine as a 0-1 bar fraction (not a rank against other rows).
    public static func barFraction(wholeMachinePercent: Double) -> Double {
        min(max(wholeMachinePercent / 100, 0), 1)
    }
}

public enum BoundedHistory {
    public static func append(_ value: Double, to values: inout [Double], limit: Int) {
        values.append(value)
        let overflow = values.count - limit
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}

public struct FastStatsSnapshot: Sendable {
    public var currentDownloadRate: Double = 0
    public var currentUploadRate: Double = 0
    public var cpuUsagePercent: Double = 0
    public var cpuHistory: [Double] = []
    public var downloadHistory: [Double] = []
    public var uploadHistory: [Double] = []

    public init() {}
}

public struct ProcessSummary: Sendable {
    /// How many rows `topMemory` and `topCPU` keep. The host samples only this many per list,
    /// so a plugin sees at most these.
    public static let memoryDisplayLimit = 18
    public static let cpuDisplayLimit = 28

    public private(set) var totalCount = 0
    public private(set) var topMemory: [ProcessSnapshot] = []
    public private(set) var topCPU: [ProcessSnapshot] = []
    public private(set) var maxPhysical: UInt64 = 1

    public init() {}

    public init(rows: [ProcessSnapshot], limit: Int) {
        self.init(rows: rows, memoryLimit: limit, cpuLimit: limit)
    }

    public init(
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
