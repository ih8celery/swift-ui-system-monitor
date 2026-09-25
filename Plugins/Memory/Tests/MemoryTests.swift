import Darwin
import Foundation
import SystemBarKit

/// The Memory tab: its formatting, its sampler's cadence, and the plugin that follows the
/// process feed.
@MainActor
enum MemoryTests {
    static func runAll() {
        testSwapStatText()
        testMemorySegmentsMatchEveryBarSegment()
        testMemorySnapshotDoesNotLeakHostPortRights()
        testPressureAndGPUAreReadEveryThirtySeconds()
        testPressureHistoryIsBounded()
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

    private static let pressureOutput = """
    The system has 17179869184 (1048576 pages with a page size of 16384).
    System-wide memory free percentage: 63%
    """

    private static let ioregOutput = """
    +-o AGXAcceleratorG14X  <class AGXAcceleratorG14X, id 0x100000abc, registered, matched, active>
        "PerformanceStatistics" = {"In use system memory"=123456789,"Device Utilization %"=12}
    """

    private static let answers = [
        "/usr/bin/memory_pressure": pressureOutput,
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

    private static func testPressureAndGPUAreReadEveryThirtySeconds() {
        let recorder = LogRecorder()
        let collector = MemoryCollector(host: makeHost(runner: recordingRunner(recorder, answers: answers)))
        let start = Date(timeIntervalSince1970: 10_000)

        let first = collector.sample(at: start)
        let soon = collector.sample(at: start.addingTimeInterval(3))
        _ = collector.sample(at: start.addingTimeInterval(31))

        expect(first.pressure == 37, "63% free is 37% pressure, got \(String(describing: first.pressure))")
        expect(first.gpu.deviceUtilization == 12 && first.gpu.inUseMemory == 123_456_789, "the GPU figures come from ioreg, got \(first.gpu)")
        expect(soon.pressure == 37 && soon.gpu.deviceUtilization == 12, "between refreshes the cached figures stand")
        expect(recorder.messages.filter { $0 == "/usr/bin/memory_pressure" }.count == 2, "memory_pressure runs at the first sample and again once 30 seconds have passed, not every 3 seconds, got \(recorder.messages)")
        expect(recorder.messages.filter { $0.hasPrefix("/usr/sbin/ioreg ") }.count == 2, "and so does ioreg, got \(recorder.messages)")
    }

    private static func testPressureHistoryIsBounded() {
        let reading = MemoryReading(memory: MemorySnapshot(), gpu: GPUSnapshot(), pressure: 50, sampledAt: Date(timeIntervalSince1970: 0))
        let stats = (0..<100).reduce(MemoryStatsSnapshot()) { stats, _ in stats.recording(reading) }
        expect(stats.pressureHistory.count == MemorySampling.pressureHistoryLimit, "the pressure history keeps the last \(MemorySampling.pressureHistoryLimit) readings, got \(stats.pressureHistory.count)")

        let unknownAt = Date(timeIntervalSince1970: 1)
        let unknown = stats.recording(MemoryReading(memory: MemorySnapshot(), gpu: GPUSnapshot(), pressure: nil, sampledAt: unknownAt))
        expect(unknown.pressure == nil && unknown.lastUpdated == unknownAt, "an unknown pressure shows as unknown, and the sample is still dated")
        expect(unknown.pressureHistory.count == MemorySampling.pressureHistoryLimit, "and it adds nothing to the history")
    }

    private static func testPluginPublishesWhatItCollected() {
        let plugin = MemoryPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)))
        plugin.collect()
        waitUntil { plugin.stats.lastUpdated != nil }
        expect(plugin.stats.pressure == 37 && plugin.stats.pressureHistory == [37], "collect() publishes the reading for the panel, got \(plugin.stats.pressureHistory)")
        expect(plugin.stats.memory.total > 0, "the kernel's memory figures are read directly, got total \(plugin.stats.memory.total)")
    }

    private static func testProcessesFollowTheFeed() {
        let first = ProcessSnapshot(name: "Safari", count: 1, physical: 2_000, virtualSize: 0, cpu: 1)
        let feed = Feed(initial: ProcessSummary(rows: [first], limit: 1))
        let plugin = MemoryPlugin(host: makeHost(processes: feed))
        expect(plugin.processes.topMemory.map(\.name) == ["Safari"], "a new plugin starts from the feed's latest reading")

        let next = ProcessSnapshot(name: "Xcode", count: 1, physical: 4_000, virtualSize: 0, cpu: 1)
        feed.send(ProcessSummary(rows: [next], limit: 1))
        waitUntil { plugin.processes.topMemory.first?.name == "Xcode" }
        expect(plugin.processes.topMemory.map(\.name) == ["Xcode"], "and follows every reading after, got \(plugin.processes.topMemory.map(\.name))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = MemoryPlugin(host: makeHost())
        expect(MemoryPlugin.identifier == "memory" && plugin.title == "Memory" && plugin.systemImage == "memorychip", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.good, "and its accent")
        expect(plugin.refreshInterval == 3 && plugin.sharedFeeds == [.processes], "and its 3-second interval and its need for the process feed")
        expect(MemorySampling.pressureRefreshInterval == 30, "memory_pressure and ioreg stay on their 30-second cache")
    }
}
