import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectFastStats() {
        let sampleDate = Date()
        let cpuCounters = Self.collectCPUCounters()
        let networkCounters = Self.collectNetworkCounters()

        var snapshot = lastFastStats
        var cpuPercent = snapshot.cpuUsagePercent
        if let previous = previousCPUCounters {
            let totalDelta = cpuCounters.total >= previous.total ? cpuCounters.total - previous.total : 0
            let activeDelta = cpuCounters.active >= previous.active ? cpuCounters.active - previous.active : 0
            if totalDelta > 0 {
                cpuPercent = Double(activeDelta) / Double(totalDelta) * 100
            }
        }
        previousCPUCounters = cpuCounters

        var downloadRate = snapshot.currentDownloadRate
        var uploadRate = snapshot.currentUploadRate
        if let previous = previousNetworkCounters,
           let previousDate = previousNetworkDate {
            let elapsed = max(0.001, sampleDate.timeIntervalSince(previousDate))
            let receivedDelta = networkCounters.received >= previous.received ? networkCounters.received - previous.received : 0
            let sentDelta = networkCounters.sent >= previous.sent ? networkCounters.sent - previous.sent : 0
            downloadRate = Double(receivedDelta) / elapsed
            uploadRate = Double(sentDelta) / elapsed
        }
        previousNetworkCounters = networkCounters
        previousNetworkDate = sampleDate
        snapshot.cpuUsagePercent = cpuPercent
        snapshot.currentDownloadRate = downloadRate
        snapshot.currentUploadRate = uploadRate
        BoundedHistory.append(cpuPercent, to: &snapshot.cpuHistory, limit: 90)
        BoundedHistory.append(downloadRate, to: &snapshot.downloadHistory, limit: 90)
        BoundedHistory.append(uploadRate, to: &snapshot.uploadHistory, limit: 90)
        lastFastStats = snapshot

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fastStats = snapshot
        }
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
