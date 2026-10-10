import Foundation
import SystemBarKit

/// The kernel's page counters as `host_statistics64` reports them, with the page size and the
/// machine's memory in bytes. `memorySnapshot(from:)` turns them into the figures the tab shows.
struct MemoryPageCounts {
    var total: UInt64 = 0
    var pageSize: UInt64 = 0
    var free: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressor: UInt64 = 0
    var purgeable: UInt64 = 0
    /// Anonymous pages: heaps and stacks, not backed by any file.
    var `internal`: UInt64 = 0
    /// File-backed pages: the file cache.
    var external: UInt64 = 0
}

/// Swap as `vm.swapusage` reports it, in bytes.
struct SwapUsage {
    var total: UInt64 = 0
    var used: UInt64 = 0
}

struct MemorySnapshot {
    var total: UInt64 = 0
    /// What Activity Monitor calls Memory Used: app memory plus wired plus compressed.
    var used: UInt64 = 0
    /// `total` less `used`.
    var available: UInt64 = 0
    /// What Activity Monitor calls App Memory: anonymous pages less the purgeable ones.
    var appMemory: UInt64 = 0
    /// What Activity Monitor calls Cached Files: file-backed pages the kernel drops at will.
    var cachedFiles: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var purgeable: UInt64 = 0
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
}

/// Activity Monitor's arithmetic. App memory is the anonymous pages less the purgeable ones
/// (saturating at zero); used is app memory plus wired plus compressed, never more than the
/// total; available is whatever is left. File cache is reported on its own and is not "used",
/// and inactive app memory is not "available": the kernel would have to compress or swap it
/// first.
func memorySnapshot(from counts: MemoryPageCounts, swap: SwapUsage = SwapUsage()) -> MemorySnapshot {
    let bytes = { (pages: UInt64) in pages * counts.pageSize }
    let appMemory = bytes(counts.internal - min(counts.internal, counts.purgeable))
    let used = min(counts.total, appMemory + bytes(counts.wired) + bytes(counts.compressor))
    return MemorySnapshot(
        total: counts.total,
        used: used,
        available: counts.total - used,
        appMemory: appMemory,
        cachedFiles: bytes(counts.external),
        active: bytes(counts.active),
        inactive: bytes(counts.inactive),
        wired: bytes(counts.wired),
        compressed: bytes(counts.compressor),
        purgeable: bytes(counts.purgeable),
        free: bytes(counts.free),
        swapTotal: swap.total,
        swapUsed: swap.used
    )
}

/// The kernel's own memory pressure signal, `kern.memorystatus_vm_pressure_level`. It is what
/// colours Activity Monitor's pressure graph; there is no finer-grained public figure.
enum MemoryPressureLevel: Equatable {
    case normal
    case warning
    case critical

    /// The sysctl's values are 1, 2 and 4. Anything else is unknown rather than guessed.
    init?(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

struct GPUSnapshot {
    /// ioreg's "Device Utilization %": how busy the GPU's compute units were at the last
    /// read. A compute figure, nothing to do with memory.
    var deviceUtilization: Double = 0
    /// ioreg's "In use system memory": what the GPU driver is using right now.
    var inUseMemory: UInt64 = 0
    /// ioreg's "Alloc system memory": what the GPU driver has set aside. It is wired RAM that no
    /// process list attributes to a process, and it is usually much larger than the in-use figure.
    var allocatedMemory: UInt64 = 0
}

struct MemoryStatsSnapshot {
    var memory = MemorySnapshot()
    var gpu = GPUSnapshot()
    var pressure: MemoryPressureLevel?
    var lastUpdated: Date?
}

/// How often the Memory tab samples.
enum MemorySampling {
    static let refreshInterval: TimeInterval = 3
    /// ioreg is a subprocess whose answers change slowly, so it is read this often and cached in
    /// between. The kernel counters and the pressure level are sysctls, read on every sample.
    static let gpuRefreshInterval: TimeInterval = 30
}

/// One collect's worth of readings.
struct MemoryReading {
    let memory: MemorySnapshot
    let gpu: GPUSnapshot
    let pressure: MemoryPressureLevel?
    let sampledAt: Date
}

extension MemoryStatsSnapshot {
    /// A copy with one reading applied. An unknown pressure level shows as unknown.
    func recording(_ reading: MemoryReading) -> MemoryStatsSnapshot {
        MemoryStatsSnapshot(
            memory: reading.memory,
            gpu: reading.gpu,
            pressure: reading.pressure,
            lastUpdated: reading.sampledAt
        )
    }
}
