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
        testProcessTableResolvesPathsWithSpaces()
        testProcessTableStatsOnceForASpaceFreePath()
        testProcessTableFallsBackWhenTheExecutableIsGone()
        testProcessTableNeverStatsARelativeCommand()
        testProcessTableCapCountsWords()
        testRegularFileCheckAcceptsOnlyRegularFiles()
        MainActor.assumeIsolated { CPUTests.runAll() }
        MainActor.assumeIsolated { PowerTests.runAll() }
        MainActor.assumeIsolated { DiskTests.runAll() }
        MainActor.assumeIsolated { DiskLedgerTests.runAll() }
        MainActor.assumeIsolated { DiskRowsTests.runAll() }
        MainActor.assumeIsolated { DiskStoreTests.runAll() }
        MainActor.assumeIsolated { DiskScanTests.runAll() }
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
        MainActor.assumeIsolated { SystemBarPreviewTests.runAll() }
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
        let summary = ProcessSummary(rows: rows, memoryLimit: 2, cpuLimit: 2)
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
        expect(clang?.path == "/Applications/Xcode.app/Contents/Developer/usr/bin/clang", "a space-free path is the first token of args")
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

    /// A fake existence check: answers from `existing` and writes every path it is asked about
    /// into `asked`, so a test can count the stats without touching the disk.
    private static func fakeFileExists(_ existing: Set<String>, asked: LogRecorder) -> (String) -> Bool {
        { path in
            asked.record(path)
            return existing.contains(path)
        }
    }

    private static func psRow(pid: Int32, args: String) -> String {
        """
          PID  PPID  %CPU    RSS     ELAPSED ARGS
        \(pid)     1   2.0   4096    00:01:00 \(args)
        """
    }

    private static func testProcessTableResolvesPathsWithSpaces() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let oneSpace = ProcessTable.parse(
            psRow(pid: 7, args: "\(chrome) --type=renderer --lang=en-US"),
            fileExists: fakeFileExists([chrome], asked: LogRecorder())
        )
        expect(oneSpace[7]?.path == chrome, "a path with one space resolves to the existing file, got \(String(describing: oneSpace[7]?.path))")
        expect(oneSpace[7]?.name == "Google Chrome", "name is the basename of the resolved path, got \(String(describing: oneSpace[7]?.name))")
        expect(oneSpace[7]?.args == "\(chrome) --type=renderer --lang=en-US", "args is unchanged by path resolution")

        let helper = "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/Frameworks/Docker Desktop Helper (Renderer).app/Contents/MacOS/Docker Desktop Helper (Renderer)"
        let several = ProcessTable.parse(
            psRow(pid: 8, args: "\(helper) --type=renderer"),
            fileExists: fakeFileExists([helper], asked: LogRecorder())
        )
        expect(several[8]?.path == helper, "a path with several spaces resolves, got \(String(describing: several[8]?.path))")
        expect(several[8]?.name == "Docker Desktop Helper (Renderer)", "and its name is the whole basename, got \(String(describing: several[8]?.name))")

        let bare = ProcessTable.parse(psRow(pid: 9, args: chrome), fileExists: fakeFileExists([chrome], asked: LogRecorder()))
        expect(bare[9]?.path == chrome, "a command line that is only the path resolves too, got \(String(describing: bare[9]?.path))")
    }

    private static func testProcessTableStatsOnceForASpaceFreePath() {
        let asked = LogRecorder()
        let table = ProcessTable.parse(
            psRow(pid: 10, args: "/usr/bin/ssh-agent -l -a /tmp/agent socket"),
            fileExists: fakeFileExists(["/usr/bin/ssh-agent"], asked: asked)
        )
        expect(table[10]?.path == "/usr/bin/ssh-agent" && table[10]?.name == "ssh-agent", "a space-free path is the first token, got \(String(describing: table[10]?.path))")
        expect(asked.messages == ["/usr/bin/ssh-agent"], "the ordinary row costs exactly one existence check, got \(asked.messages)")
    }

    private static func testProcessTableFallsBackWhenTheExecutableIsGone() {
        let short = LogRecorder()
        let deleted = ProcessTable.parse(
            psRow(pid: 11, args: "/Applications/Old App.app/Contents/MacOS/Old App --flag"),
            fileExists: fakeFileExists([], asked: short)
        )
        expect(deleted[11]?.path == "/Applications/Old" && deleted[11]?.name == "Old", "an executable gone from disk falls back to the first token, got \(String(describing: deleted[11]?.path))")
        expect(short.count == 4, "every prefix of a short command line is tried once, got \(short.messages)")

        let long = LogRecorder()
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let gone = ProcessTable.parse(psRow(pid: 12, args: "/opt/gone/tool \(words)"), fileExists: fakeFileExists([], asked: long))
        expect(gone[12]?.path == "/opt/gone/tool", "a long command line falls back to the first token, got \(String(describing: gone[12]?.path))")
        expect(long.count == ProcessTable.maximumPathPrefixes, "no more prefixes are tried than the cap, got \(long.count)")
    }

    private static func testProcessTableNeverStatsARelativeCommand() {
        let asked = LogRecorder()
        let table = ProcessTable.parse(
            psRow(pid: 13, args: "python3 script.py --watch"),
            fileExists: fakeFileExists(["python3", "python3 script.py"], asked: asked)
        )
        expect(table[13]?.path == "python3" && table[13]?.name == "python3", "a relative command keeps its first token, got \(String(describing: table[13]?.path))")
        expect(asked.messages.isEmpty, "a relative command is never looked up on disk, got \(asked.messages)")
    }

    /// The cap counts words: a path of exactly `maximumPathPrefixes` words (one fewer spaces)
    /// still resolves, and one word more falls back to the first word.
    private static func testProcessTableCapCountsWords() {
        let cap = ProcessTable.maximumPathPrefixes
        let atCap = "/p" + (1..<cap).map { " w\($0)" }.joined()
        let fits = ProcessTable.parse(psRow(pid: 14, args: "\(atCap) --flag value"), fileExists: fakeFileExists([atCap], asked: LogRecorder()))
        expect(fits[14]?.path == atCap, "a path of exactly \(cap) words resolves, got \(String(describing: fits[14]?.path))")

        let pastCap = atCap + " w\(cap)"
        let tooLong = ProcessTable.parse(psRow(pid: 15, args: "\(pastCap) --flag value"), fileExists: fakeFileExists([pastCap], asked: LogRecorder()))
        expect(tooLong[15]?.path == "/p", "a path of \(cap + 1) words falls back to the first word, got \(String(describing: tooLong[15]?.path))")
    }

    /// The real check, against the real disk, in a folder of the test's own. The folder is removed
    /// before any assertion, because a failed `expect` exits without running `defer`.
    private static func testRegularFileCheckAcceptsOnlyRegularFiles() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systembar-regular-file-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("tool with spaces")
        let created = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            && FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        let folderIsRegular = ProcessTable.isExistingRegularFile(atPath: folder.path)
        let fileIsRegular = ProcessTable.isExistingRegularFile(atPath: file.path)
        let missingIsRegular = ProcessTable.isExistingRegularFile(atPath: folder.appendingPathComponent("missing").path)
        try? FileManager.default.removeItem(at: folder)

        expect(created, "could not create the test folder and file")
        expect(!folderIsRegular, "a folder is not a regular file")
        expect(fileIsRegular, "a regular file is one")
        expect(!missingIsRegular, "a missing path is not a regular file")
        expect(!ProcessTable.isExistingRegularFile(atPath: "/dev/null"), "a device such as /dev/null is not a regular file")
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
