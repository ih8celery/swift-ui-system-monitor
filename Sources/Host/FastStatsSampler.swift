import Darwin
import Foundation
import SystemBarKit

/// The 1-second sample: CPU busy percent (whole machine, each core, user and system) and
/// network rates, each worked out from how far the kernel's counters moved since the last
/// sample, with their short histories. Only HostSamplers' fast queue calls `sample()`, which is
/// what makes the unlocked state safe.
final class FastStatsSampler: @unchecked Sendable {
    /// Ninety one-second samples: the "last 90s" the CPU and Network graphs are labelled with.
    static let historyLimit = 90

    private var previousCPU: CPUCounters?
    private var previousNetwork: NetworkCounters?
    private var previousDate: Date?
    private var last = FastStatsSnapshot()

    func sample() -> FastStatsSnapshot {
        sample(cpu: Self.collectCPUCounters(), network: NetworkCounters(interfaces: Self.readInterfaceCounters()), at: Date())
    }

    /// The rate math, kept apart from the kernel reads so a test can feed it counters. Until
    /// there is a previous reading to compare with, the last figures stand.
    func sample(cpu: CPUCounters, network: NetworkCounters, at date: Date) -> FastStatsSnapshot {
        let cpuPercent = Self.busyPercent(from: previousCPU, to: cpu) ?? last.cpuUsagePercent
        let shares = Self.shares(from: previousCPU, to: cpu)
            ?? (user: last.cpuUserPercent, system: last.cpuSystemPercent)
        let perCore = Self.perCoreBusyPercent(from: previousCPU, to: cpu) ?? last.perCoreUsage
        let rates = Self.rates(from: previousNetwork, at: previousDate, to: network, at: date)
            ?? (download: last.currentDownloadRate, upload: last.currentUploadRate)

        var next = last
        next.cpuUsagePercent = cpuPercent
        next.cpuUserPercent = shares.user
        next.cpuSystemPercent = shares.system
        next.perCoreUsage = perCore
        next.currentDownloadRate = rates.download
        next.currentUploadRate = rates.upload
        BoundedHistory.append(cpuPercent, to: &next.cpuHistory, limit: Self.historyLimit)
        BoundedHistory.append(rates.download, to: &next.downloadHistory, limit: Self.historyLimit)
        BoundedHistory.append(rates.upload, to: &next.uploadHistory, limit: Self.historyLimit)

        previousCPU = cpu
        previousNetwork = network
        previousDate = date
        last = next
        return next
    }

    /// Nil when there is nothing to compare with or no CPU time passed.
    static func busyPercent(from previous: CPUCounters?, to current: CPUCounters) -> Double? {
        guard let previous else { return nil }
        let totalDelta = delta(previous.total, current.total)
        guard totalDelta > 0 else { return nil }
        return Double(delta(previous.active, current.active)) / Double(totalDelta) * 100
    }

    /// User (with nice) and system time as percents of all cores together; nil as `busyPercent`.
    static func shares(from previous: CPUCounters?, to current: CPUCounters) -> (user: Double, system: Double)? {
        guard let previous else { return nil }
        let totalDelta = delta(previous.total, current.total)
        guard totalDelta > 0 else { return nil }
        let userDelta = delta(previous.user, current.user) + delta(previous.nice, current.nice)
        let systemDelta = delta(previous.system, current.system)
        return (user: Double(userDelta) / Double(totalDelta) * 100, system: Double(systemDelta) / Double(totalDelta) * 100)
    }

    /// Each core's busy percent over the interval, in the kernel's order. Nil when there is no
    /// previous reading or the core count changed, since pairing cores by index would then pair
    /// the wrong ones. A core with no ticks at all reads as idle.
    static func perCoreBusyPercent(from previous: CPUCounters?, to current: CPUCounters) -> [Double]? {
        guard let previous, previous.cores.count == current.cores.count else { return nil }
        return zip(previous.cores, current.cores).map { before, after in
            let total = delta(before.total, after.total)
            guard total > 0 else { return 0 }
            return Double(delta(before.active, after.active)) / Double(total) * 100
        }
    }

    /// A counter that went backwards counts as no change rather than a huge wrapped number.
    private static func delta(_ before: UInt64, _ after: UInt64) -> UInt64 {
        after >= before ? after - before : 0
    }

    /// Bytes per second since the previous reading, summed over the interfaces present in both;
    /// nil for the first one. An interface in only one reading adds nothing, and one whose
    /// counter went backwards (an interface reset) reads as no traffic, so neither can spike.
    static func rates(
        from previous: NetworkCounters?,
        at previousDate: Date?,
        to current: NetworkCounters,
        at date: Date
    ) -> (download: Double, upload: Double)? {
        guard let previous, let previousDate else { return nil }
        let elapsed = max(0.001, date.timeIntervalSince(previousDate))
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in current.interfaces {
            guard let before = previous.interfaces[name] else { continue }
            received += delta(before.received, now.received)
            sent += delta(before.sent, now.sent)
        }
        return (download: Double(received) / elapsed, upload: Double(sent) / elapsed)
    }

    static func collectCPUCounters() -> CPUCounters {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount = mach_msg_type_number_t(0)
        var processorCount = natural_t(0)

        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return CPUCounters(user: 0, system: 0, idle: 0, nice: 0)
        }

        let stride = Int(CPU_STATE_MAX)
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(processorCount))

        for cpuIndex in 0..<Int(processorCount) {
            let offset = cpuIndex * stride
            // The kernel's counters are unsigned 32-bit; read them as such so a count past Int32.max cannot trap.
            cores.append(CoreTicks(
                user: UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_NICE)]))
            ))
        }

        let byteCount = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteCount)

        return CPUCounters(cores: cores)
    }
}

/// One core's cumulative tick counts, as `host_processor_info` reports them.
struct CoreTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var active: UInt64 { user + system + nice }
    var total: UInt64 { active + idle }
}

/// Every core's ticks from one read. The sums are what the headline needs; the cores are what
/// the per-core figures need.
struct CPUCounters {
    let cores: [CoreTicks]
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let active: UInt64
    let total: UInt64

    init(cores: [CoreTicks]) {
        self.cores = cores
        user = cores.reduce(0) { $0 + $1.user }
        system = cores.reduce(0) { $0 + $1.system }
        nice = cores.reduce(0) { $0 + $1.nice }
        active = cores.reduce(0) { $0 + $1.active }
        total = cores.reduce(0) { $0 + $1.total }
    }

    /// The whole machine as one core: for a read that failed, and for tests of the rate math.
    init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.init(cores: [CoreTicks(user: user, system: system, idle: idle, nice: nice)])
    }
}
