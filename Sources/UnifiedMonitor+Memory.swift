import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    func collectMemory() {
        guard !isCollectingMemory else { return }
        isCollectingMemory = true
        defer { isCollectingMemory = false }

        let sampleDate = Date()
        let memory = Self.collectMemorySnapshot()
        let shouldCollectPressure = sampleDate.timeIntervalSince(lastPressureRefresh) >= MonitorSamplingPlan.pressureRefreshInterval
        let pressure = shouldCollectPressure ? Self.collectMemoryPressure() : cachedPressure
        let gpu = shouldCollectPressure ? Self.collectGPUSnapshot() : cachedGPU

        if shouldCollectPressure {
            lastPressureRefresh = sampleDate
            cachedPressure = pressure
            cachedGPU = gpu
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snapshot = self.memoryStats
            snapshot.memory = memory
            snapshot.gpu = gpu
            snapshot.pressure = pressure
            if let pressure {
                BoundedHistory.append(pressure, to: &snapshot.pressureHistory, limit: 80)
            }
            snapshot.lastUpdated = sampleDate
            self.memoryStats = snapshot
        }
    }


    static func collectMemorySnapshot() -> MemorySnapshot {
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &totalSize, nil, 0)

        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let used = result == KERN_SUCCESS ? min(total, active + wired + compressed) : 0
        let available = total > used ? total - used : free + inactive + purgeable

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 {
            swap.xsu_total = 0
            swap.xsu_used = 0
        }

        return MemorySnapshot(
            total: total,
            used: used,
            available: available,
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed,
            purgeable: purgeable,
            free: free,
            swapTotal: swap.xsu_total,
            swapUsed: swap.xsu_used
        )
    }

    private static func collectMemoryPressure() -> Double? {
        let result = runProcess(path: "/usr/bin/memory_pressure", arguments: [])
        guard result.status == 0 else { return nil }

        for line in result.output.split(whereSeparator: \.isNewline) {
            guard line.contains("System-wide memory free percentage") else { continue }
            let digits = line.filter(\.isNumber)
            guard let freePercent = Double(String(digits)) else { return nil }
            return max(0, min(100, 100 - freePercent))
        }

        return nil
    }

    private static func collectGPUSnapshot() -> GPUSnapshot {
        let result = runProcess(path: "/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXAccelerator", "-d", "2"])
        guard result.status == 0, result.output.contains("AGXAccelerator") else {
            return GPUSnapshot()
        }

        return GPUSnapshot(
            deviceUtilization: doubleValue(in: result.output, key: "Device Utilization %") ?? 0,
            inUseMemory: uint64Value(in: result.output, key: "In use system memory") ?? 0
        )
    }


}
