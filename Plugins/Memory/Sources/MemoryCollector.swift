import Darwin
import Foundation
import SystemBarKit

/// The Memory tab's sampler. The kernel's memory figures and its pressure level are sysctls and
/// Mach calls, read on every collect (every 3 seconds); ioreg is a slower subprocess, so its
/// answer is cached and refreshed every 30 seconds. Only the plugin's queue calls `sample`,
/// which is what makes the unlocked cache safe.
final class MemoryCollector: @unchecked Sendable {
    private let host: HostServices
    private let kernelPressureLevel: () -> Int32?
    private var lastGPURefresh = Date.distantPast
    private var cachedGPU = GPUSnapshot()

    /// `kernelPressureLevel` reads `kern.memorystatus_vm_pressure_level` in the app and is a
    /// fake in tests.
    init(host: HostServices, kernelPressureLevel: @escaping () -> Int32? = MemoryCollector.readKernelPressureLevel) {
        self.host = host
        self.kernelPressureLevel = kernelPressureLevel
    }

    func sample(at date: Date = Date()) -> MemoryReading {
        let memory = Self.collectMemorySnapshot()
        let pressure = kernelPressureLevel().flatMap(MemoryPressureLevel.init(kernelLevel:))
        if date.timeIntervalSince(lastGPURefresh) >= MemorySampling.gpuRefreshInterval {
            lastGPURefresh = date
            cachedGPU = collectGPUSnapshot()
        }
        return MemoryReading(memory: memory, gpu: cachedGPU, pressure: pressure, sampledAt: date)
    }

    /// The kernel's pressure level, or nil when the sysctl fails.
    static func readKernelPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    /// The kernel's memory figures. When the page counters cannot be read, the snapshot carries
    /// only the total and the swap, so the tab shows nothing available rather than everything.
    static func collectMemorySnapshot() -> MemorySnapshot {
        let total = readTotalMemory()
        let swap = readSwapUsage()
        guard let counts = readPageCounts(total: total) else {
            return MemorySnapshot(total: total, swapTotal: swap.total, swapUsed: swap.used)
        }
        return memorySnapshot(from: counts, swap: swap)
    }

    private static func readTotalMemory() -> UInt64 {
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &totalSize, nil, 0) == 0 else { return 0 }
        return total
    }

    private static func readPageCounts(total: UInt64) -> MemoryPageCounts? {
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return MemoryPageCounts(
            total: total,
            pageSize: UInt64(vm_kernel_page_size),
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count),
            internal: UInt64(stats.internal_page_count),
            external: UInt64(stats.external_page_count)
        )
    }

    private static func readSwapUsage() -> SwapUsage {
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else { return SwapUsage() }
        return SwapUsage(total: swap.xsu_total, used: swap.xsu_used)
    }

    private func collectGPUSnapshot() -> GPUSnapshot {
        let result = host.run(path: "/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXAccelerator", "-d", "2"])
        guard result.status == 0, result.output.contains("AGXAccelerator") else {
            return GPUSnapshot()
        }

        return GPUSnapshot(
            deviceUtilization: Self.doubleValue(in: result.output, key: "Device Utilization %") ?? 0,
            inUseMemory: Self.uint64Value(in: result.output, key: "In use system memory") ?? 0,
            allocatedMemory: Self.uint64Value(in: result.output, key: "Alloc system memory") ?? 0
        )
    }

    /// The value after `"key"=` in ioreg's output. The key is matched with both its quotes, and
    /// only that way, so "In use system memory" never matches "In use system memory (driver)".
    private static func stringValue(in text: String, key: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\""),
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
