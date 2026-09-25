import Darwin
import Foundation
import SystemBarKit

/// The 1-second sample: CPU busy percent and network rates, each worked out from how far the
/// kernel's counters moved since the last sample, with their short histories. Only
/// HostSamplers' serial queue calls `sample()`, which is what makes the unlocked state safe.
final class FastStatsSampler: @unchecked Sendable {
    /// Ninety one-second samples: the "last 90s" the CPU and Network graphs are labelled with.
    static let historyLimit = 90

    private var previousCPU: CPUCounters?
    private var previousNetwork: NetworkCounters?
    private var previousDate: Date?
    private var last = FastStatsSnapshot()

    func sample() -> FastStatsSnapshot {
        sample(cpu: Self.collectCPUCounters(), network: Self.collectNetworkCounters(), at: Date())
    }

    /// The rate math, kept apart from the kernel reads so a test can feed it counters. Until
    /// there is a previous reading to compare with, the last figures stand.
    func sample(cpu: CPUCounters, network: NetworkCounters, at date: Date) -> FastStatsSnapshot {
        let cpuPercent = Self.busyPercent(from: previousCPU, to: cpu) ?? last.cpuUsagePercent
        let rates = Self.rates(from: previousNetwork, at: previousDate, to: network, at: date)
            ?? (download: last.currentDownloadRate, upload: last.currentUploadRate)

        var next = last
        next.cpuUsagePercent = cpuPercent
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

    /// Nil when there is nothing to compare with or no CPU time passed. A counter that went
    /// backwards counts as no change rather than a huge wrapped number.
    static func busyPercent(from previous: CPUCounters?, to current: CPUCounters) -> Double? {
        guard let previous else { return nil }
        let totalDelta = current.total >= previous.total ? current.total - previous.total : 0
        let activeDelta = current.active >= previous.active ? current.active - previous.active : 0
        guard totalDelta > 0 else { return nil }
        return Double(activeDelta) / Double(totalDelta) * 100
    }

    /// Bytes per second since the previous reading; nil for the first one. A counter that went
    /// backwards (an interface reset) reads as no traffic.
    static func rates(
        from previous: NetworkCounters?,
        at previousDate: Date?,
        to current: NetworkCounters,
        at date: Date
    ) -> (download: Double, upload: Double)? {
        guard let previous, let previousDate else { return nil }
        let elapsed = max(0.001, date.timeIntervalSince(previousDate))
        let received = current.received >= previous.received ? current.received - previous.received : 0
        let sent = current.sent >= previous.sent ? current.sent - previous.sent : 0
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

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)

        for cpuIndex in 0..<Int(processorCount) {
            let offset = cpuIndex * stride
            user += UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            system += UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            nice += UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
        }

        let byteCount = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteCount)

        return CPUCounters(user: user, system: system, idle: idle, nice: nice)
    }

    private static func collectNetworkCounters() -> NetworkCounters {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return NetworkCounters(received: 0, sent: 0)
        }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = pointer {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp, !isLoopback,
               interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(networkData.ifi_ibytes)
                sent += UInt64(networkData.ifi_obytes)
            }

            pointer = interface.ifa_next
        }

        return NetworkCounters(received: received, sent: sent)
    }
}

struct CPUCounters {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var active: UInt64 {
        user + system + nice
    }

    var total: UInt64 {
        active + idle
    }
}

struct NetworkCounters {
    let received: UInt64
    let sent: UInt64
}
