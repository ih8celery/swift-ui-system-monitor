import Foundation

/// Whether a background sample came back clean, decoupled from the human-readable status text
/// shown next to it — so UI coloring never depends on matching that text verbatim.
public enum SampleHealth: Sendable {
    case ok
    case degraded

    /// `.ok` when `isOK` is true, `.degraded` otherwise.
    public init(isOK: Bool) {
        self = isOK ? .ok : .degraded
    }
}

/// One group of processes that share an executable name, as the host's process summary sees
/// them: every running copy of `clang` is one snapshot with `count` copies.
public struct ProcessSnapshot: Identifiable, Sendable {
    /// The group's name, which is unique within one summary.
    public var id: String { name }
    /// The executable's file name, e.g. `Google Chrome Helper`.
    public let name: String
    /// How many running processes the group holds.
    public let count: Int
    /// Memory in bytes, summed over the group: macOS's physical footprint (what Activity
    /// Monitor calls Memory) for the groups the host expects to show, resident size for the
    /// rest and for any process whose footprint could not be read.
    public let physical: UInt64
    /// Virtual address space in bytes, summed over the group. Usually far larger than
    /// `physical` and rarely worth showing on its own.
    public let virtualSize: UInt64
    /// `ps` pcpu summed over the group: percent of a single core, so a busy group, or one busy
    /// multi-threaded process, can exceed 100. `machineCPUPercent(_:)` turns it into a share of
    /// the whole machine.
    public let cpu: Double

    /// Builds a snapshot by hand, e.g. for a test or a preview.
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

/// Keeps a rolling history no longer than a limit.
public enum BoundedHistory {
    /// Appends `value` to the end of `values`, then drops the oldest values from the front until
    /// at most `limit` remain.
    public static func append(_ value: Double, to values: inout [Double], limit: Int) {
        values.append(value)
        let overflow = values.count - limit
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}

/// The host's 1-second reading of CPU load (the whole machine, each core, and the user/system
/// split) and network traffic, behind `HostServices.fastStats`. Every figure is worked out from
/// how far the kernel's counters moved since the previous second, so the very first reading is
/// all zeros.
public struct FastStatsSnapshot: Sendable {
    /// Bytes per second received, summed over every network interface that is up, loopback
    /// excluded.
    public var currentDownloadRate: Double = 0
    /// Bytes per second sent, summed the same way as `currentDownloadRate`.
    public var currentUploadRate: Double = 0
    /// How busy the CPU was over the last second, as a percent of all cores together, from 0
    /// to 100.
    public var cpuUsagePercent: Double = 0
    /// Past values of `cpuUsagePercent`, oldest first, one per second, at most ninety.
    public var cpuHistory: [Double] = []
    /// How busy each core was over the last second, as a percent from 0 to 100, in the kernel's
    /// core order (core 0 first). Empty until the second reading, and after any reading whose
    /// core count differed from the one before it.
    public var perCoreUsage: [Double] = []
    /// The part of `cpuUsagePercent` spent running programs (user and nice time), as a percent
    /// of all cores together.
    public var cpuUserPercent: Double = 0
    /// The part spent in the kernel on their behalf (system time), the same way. User plus
    /// system is `cpuUsagePercent`.
    public var cpuSystemPercent: Double = 0
    /// Past values of `currentDownloadRate` in bytes per second, oldest first, one per second,
    /// at most ninety.
    public var downloadHistory: [Double] = []
    /// Past values of `currentUploadRate` in bytes per second, oldest first, one per second, at
    /// most ninety.
    public var uploadHistory: [Double] = []

    /// An empty reading: every figure zero and every history empty.
    public init() {}
}

/// The host's 10-second process summary, behind `HostServices.processes`: the biggest process
/// groups by memory and by CPU. The host leaves out processes under a megabyte resident before
/// it groups, counts or ranks anything.
public struct ProcessSummary: Sendable {
    /// How many rows `topMemory` keeps in the host's feed. The host samples only this many, so a
    /// plugin sees at most this many.
    public static let memoryDisplayLimit = 18
    /// How many rows `topCPU` keeps in the host's feed, the same way.
    public static let cpuDisplayLimit = 28

    /// How many process groups were counted: groups, not processes, so eight copies of one
    /// helper count once.
    public private(set) var totalCount = 0
    /// The groups using the most memory, largest `physical` first, at most the limit the summary was
    /// built with (`memoryDisplayLimit` in the host's feed).
    public private(set) var topMemory: [ProcessSnapshot] = []
    /// The groups using the most CPU, largest `cpu` first, at most the limit the summary was built
    /// with (`cpuDisplayLimit` in the host's feed).
    public private(set) var topCPU: [ProcessSnapshot] = []
    /// The largest `physical` of any group, in bytes, and never less than 1, so a bar can
    /// divide by it safely.
    public private(set) var maxPhysical: UInt64 = 1

    /// An empty summary: no groups, as the host's feed holds before its first sample.
    public init() {}

    /// A summary of `rows`, ranked and cut to the given limits. Defaults to the display limits
    /// the host samples to.
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
