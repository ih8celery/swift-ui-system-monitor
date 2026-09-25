import Darwin
import Foundation
import SystemBarKit

/// The Memory tab's sampler. The kernel's memory figures are read on every collect (every 3
/// seconds); memory_pressure and ioreg are slower subprocesses, so their answers are cached and
/// refreshed every 30 seconds. Only the plugin's queue calls `sample`, which is what makes the
/// unlocked cache safe.
final class MemoryCollector: @unchecked Sendable {
    private let host: HostServices
    private var lastPressureRefresh = Date.distantPast
    private var cachedPressure: Double?
    private var cachedGPU = GPUSnapshot()

    init(host: HostServices) {
        self.host = host
    }

    func sample(at date: Date = Date()) -> MemoryReading {
        let memory = Self.collectMemorySnapshot()
        if date.timeIntervalSince(lastPressureRefresh) >= MemorySampling.pressureRefreshInterval {
            lastPressureRefresh = date
            cachedPressure = collectMemoryPressure()
            cachedGPU = collectGPUSnapshot()
        }
        return MemoryReading(memory: memory, gpu: cachedGPU, pressure: cachedPressure, sampledAt: date)
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

    private func collectMemoryPressure() -> Double? {
        let result = host.run(path: "/usr/bin/memory_pressure", arguments: [])
        guard result.status == 0 else { return nil }

        for line in result.output.split(whereSeparator: \.isNewline) {
            guard line.contains("System-wide memory free percentage") else { continue }
            let digits = line.filter(\.isNumber)
            guard let freePercent = Double(String(digits)) else { return nil }
            return max(0, min(100, 100 - freePercent))
        }

        return nil
    }

    private func collectGPUSnapshot() -> GPUSnapshot {
        let result = host.run(path: "/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXAccelerator", "-d", "2"])
        guard result.status == 0, result.output.contains("AGXAccelerator") else {
            return GPUSnapshot()
        }

        return GPUSnapshot(
            deviceUtilization: Self.doubleValue(in: result.output, key: "Device Utilization %") ?? 0,
            inUseMemory: Self.uint64Value(in: result.output, key: "In use system memory") ?? 0
        )
    }

    private static func stringValue(in text: String, key: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") ?? text.range(of: key),
              let equalsRange = text[keyRange.upperBound...].range(of: "=") else {
            return nil
        }

        let suffix = text[equalsRange.upperBound...].drop(while: { $0 == " " })
        if suffix.first == "\"" {
            let afterOpeningQuote = suffix.index(after: suffix.startIndex)
            guard let closingQuote = suffix[afterOpeningQuote...].firstIndex(of: "\"") else {
                return nil
            }
            return String(suffix[afterOpeningQuote..<closingQuote])
        }

        let token = suffix.prefix { !$0.isNewline && $0 != "," && $0 != "}" }
        return String(token).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func doubleValue(in text: String, key: String) -> Double? {
        guard let value = stringValue(in: text, key: key) else { return nil }
        return Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    private static func uint64Value(in text: String, key: String) -> UInt64? {
        guard let value = stringValue(in: text, key: key) else { return nil }
        return UInt64(value.filter { $0.isNumber })
    }
}
