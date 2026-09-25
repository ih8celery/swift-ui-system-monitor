import Foundation
import SystemBarKit

@main
struct SystemBarPerformanceTests {
    static func main() {
        testBoundedHistory()
        testProcessSummary()
        testProcessCPUScale()
        testProcessTableParsing()
        testProcessTableCarriesTheColumnsItParses()
        MainActor.assumeIsolated { CPUTests.runAll() }
        MainActor.assumeIsolated { PowerTests.runAll() }
        MainActor.assumeIsolated { DiskTests.runAll() }
        testRunProcessDrainsLargeStderrConcurrently()
        testRunProcessTimesOutHungCommand()
        testCollectorsDoNotLeakHostPortRights()
        testGroupsNeedingRefinement()
        MainActor.assumeIsolated { MemoryTests.runAll() }
        testUpdatedAgoText()
        MainActor.assumeIsolated { NetworkTests.runAll() }
        testSampleHealthFromIsOK()
        MainActor.assumeIsolated { CapacityTests.runAll() }
        MainActor.assumeIsolated { DevPluginTests.runAll() }
        MainActor.assumeIsolated { SystemBarConfigTests.runAll() }
        MainActor.assumeIsolated { SystemBarLoaderTests.runAll() }
        MainActor.assumeIsolated { SystemBarSchedulerTests.runAll() }
        print("SystemBarPerformanceTests passed")
    }

    private static func testBoundedHistory() {
        var values: [Double] = [1, 2, 3]
        BoundedHistory.append(4, to: &values, limit: 3)
        expect(values == [2, 3, 4], "bounded history should keep the newest values")
    }

    private static func testProcessSummary() {
        let rows = [
            ProcessSnapshot(name: "small", count: 1, physical: 10, virtualSize: 20, cpu: 1),
            ProcessSnapshot(name: "cpu", count: 2, physical: 30, virtualSize: 40, cpu: 8),
            ProcessSnapshot(name: "memory", count: 1, physical: 50, virtualSize: 60, cpu: 3)
        ]
        let summary = ProcessSummary(rows: rows, limit: 2)
        expect(summary.totalCount == 3, "summary should preserve total row count")
        expect(summary.topMemory.map(\.name) == ["memory", "cpu"], "summary should pre-sort memory rows")
        expect(summary.topCPU.map(\.name) == ["cpu", "memory"], "summary should pre-sort cpu rows")
        expect(summary.maxPhysical == 50, "summary should precompute max memory")
    }

    private static func testProcessCPUScale() {
        // `ps` pcpu is a percentage of a single core; grep at 89% of one core on an
        // 8-core machine is a small slice of the whole machine.
        let grep = ProcessCPUScale.wholeMachinePercent(summedPcpu: 89, coreCount: 8)
        expect(abs(grep - 11.125) < 0.001, "single busy core should read as a small whole-machine share")

        // A grouped row summing to 620% pcpu really is using ~6 of 8 cores.
        let clang = ProcessCPUScale.wholeMachinePercent(summedPcpu: 620, coreCount: 8)
        expect(abs(clang - 77.5) < 0.001, "summed pcpu divides by core count for a whole-machine percent")

        expect(ProcessCPUScale.wholeMachinePercent(summedPcpu: 50, coreCount: 0) == 0, "zero cores must not divide by zero")

        // Bar fraction is the absolute share of the machine, clamped to 0-1.
        expect(abs(ProcessCPUScale.barFraction(wholeMachinePercent: 77.5) - 0.775) < 0.001, "bar fraction is percent over 100")
        expect(ProcessCPUScale.barFraction(wholeMachinePercent: 150) == 1, "bar fraction clamps above 100%")
        expect(ProcessCPUScale.barFraction(wholeMachinePercent: -10) == 0, "bar fraction clamps below zero")
    }

    // A `ps -eo pid,ppid,pcpu,rss,etime,args` sample. Leading fields are
    // space-free; args is the whole trailing remainder (spaces preserved).
    private static let psSample = """
    PID  PPID %CPU   RSS     ELAPSED ARGS
      1     0  0.0  20000 10-00:00:00 /sbin/launchd
    100     1  1.5   5000    01:00:00 /usr/bin/ssh-agent -l
    200   100 50.0  40000    00:10:00 /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c foo.c
    201   200 40.0  30000    00:05:00 /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c bar.c
    """

    private static func testProcessTableParsing() {
        let map = ProcessTable.parse(psSample)
        expect(map.count == 4, "parser should read every process row and skip the header")

        let clang = map[200]
        expect(clang?.ppid == 100, "parser should read ppid")
        expect(clang?.path == "/Applications/Xcode.app/Contents/Developer/usr/bin/clang", "path is the first token of args")
        expect(clang?.name == "clang", "name is the basename of the exe path")
        expect(clang?.args == "/Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c foo.c", "args keeps the full command line with spaces")
        expect(clang?.memory == 40000 * 1024, "ps rss is kilobytes and must scale to bytes")
        expect(map[100]?.args == "/usr/bin/ssh-agent -l", "args with flags stays intact")
    }

    private static func testProcessTableCarriesTheColumnsItParses() {
        expect(ProcessTable.executable == "/bin/ps", "the table is read from ps by explicit path")
        expect(ProcessTable.arguments == ["-eo", "pid,ppid,pcpu,rss,etime,args"], "the columns the parser depends on, in its order, got \(ProcessTable.arguments)")

        // What `ps -eo pid,ppid,pcpu,rss,etime,args` prints: a header, then the five space-free
        // fields and the whole command line, spaces and all.
        let sample = """
          PID  PPID  %CPU    RSS     ELAPSED ARGS
            1     0   0.0  20000 10-00:00:00 /sbin/launchd
          412     1  12.5  81920    01:02:03 /Applications/Some App.app/Contents/MacOS/Some App --flag value
        """
        let table = ProcessTable.parse(sample)
        expect(table.count == 2, "the header is skipped and both rows are read, got \(table.count)")
        expect(table[412]?.ppid == 1 && table[412]?.cpu == 12.5, "pid, ppid and pcpu come from the first three columns")
        expect(table[412]?.memory == 81_920 * 1024, "rss is in kilobytes and becomes bytes, got \(String(describing: table[412]?.memory))")
        expect(table[412]?.etime == "01:02:03", "etime is the fifth column, got \(String(describing: table[412]?.etime))")
        expect(table[412]?.args == "/Applications/Some App.app/Contents/MacOS/Some App --flag value", "args is the whole remainder, spaces included")
    }

    private static func testRunProcessDrainsLargeStderrConcurrently() {
        // A child that writes more than one pipe buffer (~64KB) to stderr
        // before it writes to stdout deadlocks a sequential
        // read-stdout-then-read-stderr implementation: the child blocks on
        // the full stderr pipe while the parent blocks on the empty stdout
        // pipe. Both streams must drain concurrently for this to return.
        let script = """
        for i in $(seq 1 2000); do echo "stderr line $i measuring pipe pressure for the deadlock regression test case here"; done 1>&2
        echo "stdout marker"
        """
        let result = ProcessRunner.run(path: "/bin/sh", arguments: ["-c", script], timeout: 5)
        expect(result.status == 0, "large-stderr command should exit cleanly rather than deadlock")
        expect(result.error.utf8.count > 64 * 1024, "stderr should be fully drained past one pipe buffer")
        expect(result.output.contains("stdout marker"), "stdout should still be captured while stderr is heavy")
    }

    private static func testRunProcessTimesOutHungCommand() {
        // A command that never exits must not block the caller forever.
        let start = Date()
        let result = ProcessRunner.run(path: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        expect(elapsed < 5, "a hung command should be terminated near the timeout, not run to completion")
        expect(result.status != 0, "a timed-out command should not report a clean exit status")
        expect(result.didTimeout, "a terminated command should be distinguishable from one that failed on its own")

        let clean = ProcessRunner.run(path: "/bin/echo", arguments: ["hi"], timeout: 5)
        expect(!clean.didTimeout, "a command that exits on its own must not be reported as timed out")
    }

    private static func testCollectorsDoNotLeakHostPortRights() {
        // mach_host_self() hands back a send right on the same port name each
        // call and bumps its user-reference count; the caller owns that
        // reference. A collector that never deallocates it leaks one ref per
        // call, unbounded, in a process that runs for weeks.
        let probePort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, probePort) }

        var before: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, probePort, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before)

        for _ in 0..<50 {
            _ = FastStatsSampler.collectCPUCounters()
        }

        var after: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, probePort, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after)

        expect(
            after <= before + 5,
            "host port send-right refs should not grow with repeated sampling: before=\(before) after=\(after)"
        )
    }

    private static func testGroupsNeedingRefinement() {
        // Only groups that would actually land in the displayed top-N by
        // memory or CPU are worth the per-PID proc_pid_rusage syscall;
        // everything else can trust ps's cheap rss/pcpu.
        let samples: [(name: String, rss: UInt64, cpu: Double)] = [
            ("big-mem", 10 * 1_048_576, 1),
            ("big-mem", 10 * 1_048_576, 1),
            ("big-cpu", 1_048_576, 50),
            ("small", 1_048_576, 1)
        ]

        let refined = ProcessSampler.groupsNeedingRefinement(samples: samples, memoryLimit: 1, cpuLimit: 1)
        expect(refined == ["big-mem", "big-cpu"], "only the top memory group and top CPU group should need refinement")

        let refinedAll = ProcessSampler.groupsNeedingRefinement(samples: samples, memoryLimit: 10, cpuLimit: 10)
        expect(refinedAll == ["big-mem", "big-cpu", "small"], "a generous limit should cover every group")
    }

    private static func testUpdatedAgoText() {
        let sample = Date(timeIntervalSince1970: 1_000)
        expect(
            updatedAgoText(lastUpdated: sample, now: sample.addingTimeInterval(7)) == "Updated 7s ago",
            "should report whole seconds elapsed since the last sample"
        )
        expect(
            updatedAgoText(lastUpdated: sample, now: sample.addingTimeInterval(-2)) == "Updated 0s ago",
            "a clock going backwards should clamp to 0, never show a negative age"
        )
        expect(
            updatedAgoText(lastUpdated: nil, now: sample) == "Waiting for sample",
            "no sample yet should say so instead of showing a bogus age"
        )
    }

    private static func testSampleHealthFromIsOK() {
        expect(SampleHealth(isOK: true) == .ok, "a healthy sample should map to .ok")
        expect(SampleHealth(isOK: false) == .degraded, "an unhealthy sample should map to .degraded")
    }
}
