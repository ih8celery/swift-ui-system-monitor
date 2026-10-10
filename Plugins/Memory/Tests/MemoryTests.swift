import Darwin
import Foundation
import SystemBarKit

/// The Memory tab: its arithmetic, its formatting, its sampler's cadence, and the plugin that
/// follows the process feed.
@MainActor
enum MemoryTests {
    static func runAll() {
        testSwapStatText()
        testUsedBreakdownNamesEveryPart()
        testMemorySegmentsMatchEveryBarSegment()
        testUsedAndAvailableFollowActivityMonitor()
        testUsedNeverExceedsTotalAndAppMemoryNeverGoesNegative()
        testMemorySnapshotDoesNotLeakHostPortRights()
        testPressureLevelComesFromTheKernel()
        testGPUFiguresComeFromIoreg()
        testAnUnquotedKeyPrefixIsNotMistakenForTheKey()
        testGPUIsReadEveryThirtySecondsAndPressureEverySample()
        testUnknownPressureShowsAsUnknown()
        testPluginPublishesWhatItCollected()
        testProcessesFollowTheFeed()
        testPluginIdentityMatchesTheOldTab()
    }

    private static func testSwapStatText() {
        expect(
            swapStatText(used: 2_147_483_648, total: 8_589_934_592) == "2.00 GB / 8.00 GB",
            "swap stat should show used and reserved totals, not just used"
        )
        expect(
            swapStatText(used: 0, total: 0) == "0 B / 0 B",
            "zero swap should still render both sides rather than dividing by zero"
        )
    }

    private static func testUsedBreakdownNamesEveryPart() {
        let gib: UInt64 = 1_073_741_824
        let memory = MemorySnapshot(used: 46 * gib, appMemory: 20 * gib, cachedFiles: 14 * gib, wired: 23 * gib, compressed: 3 * gib)
        let text = usedBreakdownText(memory: memory)
        expect(
            text.hasPrefix("46.0 GB used, as Activity Monitor counts it: 20.0 GB app memory + 23.0 GB wired + 3.00 GB compressed."),
            "the tooltip spells out the sum behind used, got \(text)"
        )
        expect(text.contains("14.0 GB of cached files is not counted"), "and says what the file cache is, got \(text)")
    }

    private static func testMemorySegmentsMatchEveryBarSegment() {
        let memory = MemorySnapshot(active: 10, inactive: 40, wired: 20, compressed: 30, purgeable: 0, free: 5)
        let segments = memorySegments(for: memory)
        let kinds = Set(segments.map { $0.kind })
        expect(
            kinds == Set(MemorySegmentKind.allCases),
            "every non-zero memory category the bar can draw must also appear in the legend's segment set"
        )

        let zeroFree = MemorySnapshot(active: 10, inactive: 40, wired: 20, compressed: 30, purgeable: 0, free: 0)
        expect(
            !memorySegments(for: zeroFree).contains { $0.kind == .free },
            "a zero-value category should be omitted from both the bar and the legend, not just one"
        )

        let names = MemorySegmentKind.allCases.map { $0.rawValue }
        expect(names.count == Set(names).count, "every segment kind must have a unique display name")
    }

    private static let page: UInt64 = 16_384

    /// Activity Monitor's arithmetic: app memory is the anonymous (internal) pages less the
    /// purgeable ones; used is app memory plus wired plus compressed; available is the rest.
    private static func testUsedAndAvailableFollowActivityMonitor() {
        let counts = MemoryPageCounts(
            total: 1_000 * page, pageSize: page,
            free: 100, active: 300, inactive: 200, wired: 250, compressor: 50,
            purgeable: 40, internal: 320, external: 190
        )
        let memory = memorySnapshot(from: counts)

        expect(memory.appMemory == 280 * page, "app memory is internal minus purgeable (320 - 40 pages), got \(memory.appMemory / page) pages")
        expect(memory.cachedFiles == 190 * page, "cached files are the external (file-backed) pages, got \(memory.cachedFiles / page) pages")
        expect(memory.used == 580 * page, "used is app memory + wired + compressed (280 + 250 + 50 pages), got \(memory.used / page) pages")
        expect(memory.available == 420 * page, "available is total minus used (1000 - 580 pages), got \(memory.available / page) pages")
        expect(memory.total == 1_000 * page, "total is passed through, got \(memory.total)")
        expect(
            memory.active == 300 * page && memory.inactive == 200 * page && memory.wired == 250 * page
                && memory.compressed == 50 * page && memory.purgeable == 40 * page && memory.free == 100 * page,
            "the bar's categories are the page counts in bytes"
        )
    }

    private static func testUsedNeverExceedsTotalAndAppMemoryNeverGoesNegative() {
        let odd = MemoryPageCounts(
            total: 100 * page, pageSize: page,
            free: 0, active: 0, inactive: 0, wired: 90, compressor: 20,
            purgeable: 30, internal: 10, external: 0
        )
        let memory = memorySnapshot(from: odd)
        expect(memory.appMemory == 0, "more purgeable than internal pages saturates app memory at zero, got \(memory.appMemory)")
        expect(memory.used == 100 * page, "used is clamped to the total, got \(memory.used / page) pages")
        expect(memory.available == 0, "and nothing is available, got \(memory.available)")
    }

    private static let ioregOutput = """
    +-o AGXAcceleratorG14X  <class AGXAcceleratorG14X, id 0x100000abc, registered, matched, active>
        "PerformanceStatistics" = {"In use system memory (driver)"=0,"Alloc system memory"=14671822848,"Device Utilization %"=12,"In use system memory"=123456789}
    """

    private static let answers = [
        "/usr/sbin/ioreg -r -c AGXAccelerator -d 2": ioregOutput,
    ]

    private static func testMemorySnapshotDoesNotLeakHostPortRights() {
        // mach_host_self() hands back a send right and bumps its user-reference count; the
        // caller owns that reference. A sampler that never deallocates it leaks one per call,
        // unbounded, in a process that runs for weeks.
        let probePort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, probePort) }

        var before: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, probePort, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before)
        for _ in 0..<50 {
            _ = MemoryCollector.collectMemorySnapshot()
        }
        var after: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, probePort, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after)

        expect(after <= before + 5, "host port send-right refs should not grow with repeated sampling: before=\(before) after=\(after)")
    }

    /// The kernel's memorystatus level is the only pressure signal shown: 1 normal, 2 warning,
    /// 4 critical. Anything else is unknown, and no subprocess is involved.
    private static func testPressureLevelComesFromTheKernel() {
        expect(MemoryPressureLevel(kernelLevel: 1) == .normal, "kernel level 1 is normal")
        expect(MemoryPressureLevel(kernelLevel: 2) == .warning, "kernel level 2 is warning")
        expect(MemoryPressureLevel(kernelLevel: 4) == .critical, "kernel level 4 is critical")
        expect(MemoryPressureLevel(kernelLevel: 3) == nil && MemoryPressureLevel(kernelLevel: 0) == nil, "any other level is unknown rather than guessed")
        expect(
            MemoryPressureLevel.normal.label == "Normal" && MemoryPressureLevel.warning.label == "Warning" && MemoryPressureLevel.critical.label == "Critical",
            "each level has the name Activity Monitor uses"
        )

        let recorder = LogRecorder()
        let collector = MemoryCollector(host: makeHost(runner: recordingRunner(recorder, answers: answers)), kernelPressureLevel: { 2 })
        let reading = collector.sample(at: Date(timeIntervalSince1970: 10_000))
        expect(reading.pressure == .warning, "the reading carries the kernel's level, got \(String(describing: reading.pressure))")
        expect(!recorder.messages.contains { $0.hasPrefix("/usr/bin/memory_pressure") }, "the level is a sysctl, so memory_pressure is never run, got \(recorder.messages)")

        let silent = MemoryCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)), kernelPressureLevel: { nil })
        expect(silent.sample(at: Date(timeIntervalSince1970: 10_000)).pressure == nil, "a kernel that does not answer leaves the level unknown")
    }

    private static func testGPUFiguresComeFromIoreg() {
        let collector = MemoryCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)), kernelPressureLevel: { 1 })
        let gpu = collector.sample(at: Date(timeIntervalSince1970: 10_000)).gpu
        expect(gpu.deviceUtilization == 12, "the busy percentage is ioreg's Device Utilization, got \(gpu.deviceUtilization)")
        expect(gpu.inUseMemory == 123_456_789, "in-use memory is the plain 'In use system memory' key, not the '(driver)' one that precedes it, got \(gpu.inUseMemory)")
        expect(gpu.allocatedMemory == 14_671_822_848, "allocated memory is 'Alloc system memory', got \(gpu.allocatedMemory)")
    }

    private static let driverOnlyIoregOutput = """
    +-o AGXAcceleratorG14X  <class AGXAcceleratorG14X, id 0x100000abc, registered, matched, active>
        "PerformanceStatistics" = {"In use system memory (driver)"=777,"Device Utilization %"=3}
    """

    private static func testAnUnquotedKeyPrefixIsNotMistakenForTheKey() {
        let answers = ["/usr/sbin/ioreg -r -c AGXAccelerator -d 2": driverOnlyIoregOutput]
        let collector = MemoryCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)), kernelPressureLevel: { 1 })
        let gpu = collector.sample(at: Date(timeIntervalSince1970: 10_000)).gpu
        expect(gpu.inUseMemory == 0, "with no 'In use system memory' key, the '(driver)' figure must not stand in for it, got \(gpu.inUseMemory)")
        expect(gpu.allocatedMemory == 0 && gpu.deviceUtilization == 3, "the other figures are unaffected, got \(gpu)")
    }

    private static func testGPUIsReadEveryThirtySecondsAndPressureEverySample() {
        let recorder = LogRecorder()
        let pressureReads = LogRecorder()
        let collector = MemoryCollector(
            host: makeHost(runner: recordingRunner(recorder, answers: answers)),
            kernelPressureLevel: { pressureReads.record("read"); return 1 }
        )
        let start = Date(timeIntervalSince1970: 10_000)

        let first = collector.sample(at: start)
        let soon = collector.sample(at: start.addingTimeInterval(3))
        _ = collector.sample(at: start.addingTimeInterval(31))

        expect(first.gpu.deviceUtilization == 12 && soon.gpu.deviceUtilization == 12, "between refreshes the cached GPU figures stand")
        expect(recorder.messages.filter { $0.hasPrefix("/usr/sbin/ioreg ") }.count == 2, "ioreg runs at the first sample and again once 30 seconds have passed, not every 3 seconds, got \(recorder.messages)")
        expect(pressureReads.count == 3, "the kernel's pressure level is cheap and read on every sample, got \(pressureReads.count)")
    }

    private static func testUnknownPressureShowsAsUnknown() {
        let known = MemoryStatsSnapshot().recording(MemoryReading(memory: MemorySnapshot(), gpu: GPUSnapshot(), pressure: .critical, sampledAt: Date(timeIntervalSince1970: 0)))
        expect(known.pressure == .critical, "a reading's level is what the panel shows")

        let unknownAt = Date(timeIntervalSince1970: 1)
        let unknown = known.recording(MemoryReading(memory: MemorySnapshot(), gpu: GPUSnapshot(), pressure: nil, sampledAt: unknownAt))
        expect(unknown.pressure == nil && unknown.lastUpdated == unknownAt, "an unknown level shows as unknown rather than keeping the old one, and the sample is still dated")
    }

    private static func testPluginPublishesWhatItCollected() {
        let plugin = MemoryPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)))
        plugin.collect()
        waitUntil { plugin.stats.lastUpdated != nil }
        expect(plugin.stats.gpu.inUseMemory == 123_456_789, "collect() publishes the reading for the panel, got \(plugin.stats.gpu)")
        expect(plugin.stats.pressure != nil, "the real kernel always has a pressure level to report")
        expect(plugin.stats.memory.total > 0 && plugin.stats.memory.used > 0, "the kernel's memory figures are read directly, got total \(plugin.stats.memory.total) used \(plugin.stats.memory.used)")
        expect(plugin.stats.memory.used + plugin.stats.memory.available == plugin.stats.memory.total, "used and available add up to the machine's memory")
    }

    private static func testProcessesFollowTheFeed() {
        let first = ProcessSnapshot(name: "Safari", count: 1, physical: 2_000, virtualSize: 0, cpu: 1)
        let feed = Feed(initial: ProcessSummary(rows: [first], memoryLimit: 1, cpuLimit: 1))
        let plugin = MemoryPlugin(host: makeHost(processes: feed))
        expect(plugin.processes.topMemory.map(\.name) == ["Safari"], "a new plugin starts from the feed's latest reading")

        let next = ProcessSnapshot(name: "Xcode", count: 1, physical: 4_000, virtualSize: 0, cpu: 1)
        feed.send(ProcessSummary(rows: [next], memoryLimit: 1, cpuLimit: 1))
        waitUntil { plugin.processes.topMemory.first?.name == "Xcode" }
        expect(plugin.processes.topMemory.map(\.name) == ["Xcode"], "and follows every reading after, got \(plugin.processes.topMemory.map(\.name))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = MemoryPlugin(host: makeHost())
        expect(MemoryPlugin.identifier == "memory" && plugin.title == "Memory" && plugin.systemImage == "memorychip", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.good, "and its accent")
        expect(plugin.refreshInterval == 3 && plugin.sharedFeeds == [.processes], "and its 3-second interval and its need for the process feed")
        expect(MemorySampling.gpuRefreshInterval == 30, "ioreg stays on its 30-second cache")
    }
}
