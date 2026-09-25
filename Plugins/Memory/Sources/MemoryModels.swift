import Foundation
import SystemBarKit

struct MemorySnapshot {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var available: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var purgeable: UInt64 = 0
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
}

struct GPUSnapshot {
    var deviceUtilization: Double = 0
    var inUseMemory: UInt64 = 0
}

struct MemoryStatsSnapshot {
    var memory = MemorySnapshot()
    var gpu = GPUSnapshot()
    var pressure: Double?
    var pressureHistory: [Double] = []
    var lastUpdated: Date?
}

/// How often the Memory tab samples.
enum MemorySampling {
    static let refreshInterval: TimeInterval = 3
    /// memory_pressure and ioreg are subprocesses whose answers change slowly, so they are read
    /// this often and cached in between.
    static let pressureRefreshInterval: TimeInterval = 30
    /// Eighty readings: four minutes of history at the 3-second interval.
    static let pressureHistoryLimit = 80
}

/// One collect's worth of readings.
struct MemoryReading {
    let memory: MemorySnapshot
    let gpu: GPUSnapshot
    let pressure: Double?
    let sampledAt: Date
}

extension MemoryStatsSnapshot {
    /// A copy with one reading applied. An unknown pressure shows as unknown and adds nothing to
    /// the history.
    func recording(_ reading: MemoryReading) -> MemoryStatsSnapshot {
        var next = self
        next.memory = reading.memory
        next.gpu = reading.gpu
        next.pressure = reading.pressure
        if let pressure = reading.pressure {
            BoundedHistory.append(pressure, to: &next.pressureHistory, limit: MemorySampling.pressureHistoryLimit)
        }
        next.lastUpdated = reading.sampledAt
        return next
    }
}
