import Foundation
import SystemBarKit

@main
struct SystemBarPerformanceTests {
    static func main() {
        testSamplingPlan()
        testBoundedHistory()
        testProcessSummary()
        testProcessCPUScale()
        testProcessTableParsing()
        testProcessTableCarriesTheColumnsItParses()
        testParentChainWalk()
        testGroupDetailRows()
        testProcessClassifier()
        MainActor.assumeIsolated { PowerTests.runAll() }
        MainActor.assumeIsolated { DiskTests.runAll() }
        testRunProcessDrainsLargeStderrConcurrently()
        testRunProcessTimesOutHungCommand()
        testCollectorsDoNotLeakHostPortRights()
        testGroupsNeedingRefinement()
        MainActor.assumeIsolated { MemoryTests.runAll() }
        testUpdatedAgoText()
        testHostnameCacheEntryExpiry()
        testParseCSVLine()
        testParseNettopCSV()
        testParseLsofTCP()
        testIsLANAddress()
        testParseNetworkQualityJSON()
        testParseNetworkQualitySummary()
        testSampleHealthFromIsOK()
        MainActor.assumeIsolated { CapacityTests.runAll() }
        MainActor.assumeIsolated { DevPluginTests.runAll() }
        MainActor.assumeIsolated { SystemBarConfigTests.runAll() }
        MainActor.assumeIsolated { SystemBarLoaderTests.runAll() }
        MainActor.assumeIsolated { SystemBarSchedulerTests.runAll() }
        print("SystemBarPerformanceTests passed")
    }

    private static func testSamplingPlan() {
        expect(MonitorSamplingPlan.jobs(isVisible: false, mode: .network).isEmpty, "hidden window should not run heavy samplers")
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .network) == [.network], "network mode should only run network heavy sampler")
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .cpu).isEmpty, "cpu mode needs nothing of the monitor; both its feeds come from the host samplers")
        expect(MonitorSamplingPlan.networkRefreshInterval >= 30, "network refresh interval should protect idle CPU")
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

    private static func testParentChainWalk() {
        let map = ProcessTable.parse(psSample)

        let twoHops = UnifiedMonitor.parentChain(of: 201, in: map, hops: 2)
        expect(twoHops == ["clang", "ssh-agent"], "2-hop walk resolves parent then grandparent names")

        // A chain that runs out before 2 hops must not crash or invent names.
        let short = UnifiedMonitor.parentChain(of: 100, in: map, hops: 2)
        expect(short == ["launchd"], "walk stops when the chain is shorter than the hop count")

        let none = UnifiedMonitor.parentChain(of: 1, in: map, hops: 2)
        expect(none.isEmpty, "a process whose parent is not in the map yields no ancestors")
    }

    private static func testGroupDetailRows() {
        let map = ProcessTable.parse(psSample)
        let rows = UnifiedMonitor.groupDetail(name: "clang", in: map, coreCount: 8)
        expect(rows.count == 2, "group detail returns one row per PID in the named group")

        let sorted = rows.sorted { $0.pid < $1.pid }
        let first = sorted[0]
        expect(first.pid == 200, "detail rows carry their PID")
        expect(first.parentName == "ssh-agent", "parent name comes from the ppid walk")
        expect(abs(first.cpuPercent - 50.0 / 8.0) < 0.001, "per-PID cpu is normalized to the whole machine")
        expect(first.uptime == "00:10:00", "uptime is the ps ELAPSED field")
        expect(first.command == "/Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c foo.c", "command is the full args")
    }

    private static func detail(
        pid: Int32 = 1,
        command: String,
        path: String,
        parent: String = "unknown",
        grandparent: String = ""
    ) -> ProcessDetail {
        ProcessDetail(
            pid: pid,
            command: command,
            path: path,
            name: (path as NSString).lastPathComponent,
            parentName: parent,
            grandparentName: grandparent,
            cpuPercent: 0,
            memory: 0,
            uptime: "00:00:00"
        )
    }

    private static func testProcessClassifier() {
        // Xcode build: exe lives under Xcode.app; label counts the jobs.
        let xcode = (0..<3).map { i in
            detail(pid: Int32(100 + i), command: "/Applications/Xcode.app/Contents/Developer/usr/bin/clang -c a.c", path: "/Applications/Xcode.app/Contents/Developer/usr/bin/clang")
        }
        expect(ProcessClassifier.likelyLabel(for: xcode) == "Xcode compiling (3 jobs)", "Xcode toolchain path should classify as an Xcode build")

        // MCP server: args mention mcp and the parent is Claude/node.
        let mcp = [detail(command: "/opt/homebrew/bin/node /Users/x/mcp-server/index.js", path: "/opt/homebrew/bin/node", parent: "Claude")]
        expect(ProcessClassifier.likelyLabel(for: mcp) == "MCP server started by Claude", "mcp args under a Claude parent should classify as an MCP server")

        // Browser jobs: a browser parent plus a renderer/gpu/utility type.
        let browser = [detail(command: "/Applications/Google Chrome.app/.../Helper --type=renderer", path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", parent: "Google Chrome")]
        expect(ProcessClassifier.likelyLabel(for: browser) == "Chrome page/tab work", "renderer under a Chrome parent should classify as browser work")

        // Node/JS tooling: a node/vite/esbuild parent, no mcp signal.
        let node = [detail(command: "/usr/local/bin/esbuild --bundle", path: "/usr/local/bin/esbuild", parent: "node")]
        expect(ProcessClassifier.likelyLabel(for: node) == "Node build tooling", "a node parent without mcp should classify as node tooling")

        // Terminal job: the ppid chain hits a shell.
        let term = [detail(command: "/usr/bin/make", path: "/usr/bin/make", parent: "zsh", grandparent: "login")]
        expect(ProcessClassifier.likelyLabel(for: term) == "Started from your terminal", "a shell ancestor should classify as a terminal job")

        // System daemon: exe under /usr/libexec.
        let daemon = [detail(command: "/usr/libexec/secd", path: "/usr/libexec/secd", parent: "launchd")]
        expect(ProcessClassifier.likelyLabel(for: daemon) == "macOS system service", "a system path should classify as a macOS service")

        // Fallback: nothing matches, so degrade to honest raw facts.
        let unknown = [detail(command: "/opt/weird/thing --run", path: "/opt/weird/thing", parent: "supervisord")]
        expect(ProcessClassifier.likelyLabel(for: unknown) == "Started by supervisord — /opt/weird/thing", "unmatched input degrades to the honest fallback")

        expect(ProcessClassifier.likelyLabel(for: []) == "No live processes", "an empty group must not crash")
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

    private static func testHostnameCacheEntryExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)

        let freshFailure = HostnameCacheEntry(hostname: "", cachedAt: now)
        expect(
            UnifiedMonitor.isHostnameCacheEntryValid(freshFailure, now: now, ttl: 60),
            "a failed lookup should stay cached until its TTL elapses"
        )

        let staleFailure = HostnameCacheEntry(hostname: "", cachedAt: now.addingTimeInterval(-61))
        expect(
            !UnifiedMonitor.isHostnameCacheEntryValid(staleFailure, now: now, ttl: 60),
            "a failed lookup past its TTL should be treated as expired so it can be retried"
        )

        let oldSuccess = HostnameCacheEntry(hostname: "example.com", cachedAt: now.addingTimeInterval(-100_000))
        expect(
            UnifiedMonitor.isHostnameCacheEntryValid(oldSuccess, now: now, ttl: 60),
            "a successful lookup should never expire regardless of age"
        )
    }

    private static func testParseCSVLine() {
        expect(
            UnifiedMonitor.parseCSVLine("foo,bar,baz") == ["foo", "bar", "baz"],
            "a plain comma-separated line should split on every comma"
        )
        expect(
            UnifiedMonitor.parseCSVLine("x,\"1,2,3\",y") == ["x", "1,2,3", "y"],
            "commas inside a quoted field must not split the field"
        )
        expect(
            UnifiedMonitor.parseCSVLine("a,\"say \"\"hi\"\"\",b") == ["a", "say \"hi\"", "b"],
            "a doubled quote inside a quoted field should decode to one literal quote"
        )
    }

    private static func testParseNettopCSV() {
        let csv = """
        Name,bytes_in,bytes_out
        Safari.501,1000,500
        Chrome.502,2000,800
        Name,bytes_in,bytes_out
        Safari.501,50,20
        Chrome.502,80,40
        """
        let rows = UnifiedMonitor.parseNettopCSV(csv).reduce(into: [String: NetworkProcessSnapshot]()) { $0[$1.name] = $1 }

        expect(rows["Safari"]?.totalDownloaded == 1000, "first CSV block should be treated as cumulative totals")
        expect(rows["Safari"]?.totalUploaded == 500, "first CSV block's third field is the uploaded total")
        expect(rows["Safari"]?.downloadRate == 50, "second CSV block should be treated as the current rate")
        expect(rows["Chrome"]?.downloadRate == 80, "each process name (with its .pid suffix stripped) gets its own row")
        expect(rows["Safari.501"] == nil, "the numeric .pid suffix must be stripped from the process name")
    }

    private static func testParseLsofTCP() {
        let output = """
        COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Safari   1234  adamu   50u  IPv4 0x1  0t0  TCP 192.168.1.5:54321->17.253.144.10:443 (ESTABLISHED)
        Safari   1234  adamu   50w  IPv4 0x1  0t0  TCP 192.168.1.5:54321->17.253.144.10:443 (ESTABLISHED)
        sshd     999   root    10u  IPv4 0x3  0t0  TCP *:22 (LISTEN)
        Terminal 5555  adamu   12u  IPv4 0x4  0t0  TCP 192.168.1.5:60000->192.168.1.10:22 (ESTABLISHED)
        """
        let connections = UnifiedMonitor.parseLsofTCP(output)

        expect(connections.count == 2, "an exact duplicate connection and a LISTEN-state row should both be dropped")
        expect(
            connections.contains { $0.process == "Safari" && $0.remoteAddress == "17.253.144.10" && $0.isInternet },
            "an ESTABLISHED connection to a public IP should be parsed and flagged as internet-facing"
        )
        expect(
            connections.contains { $0.process == "Terminal" && $0.remoteAddress == "192.168.1.10" && !$0.isInternet },
            "a connection to a private LAN address should not be flagged as internet-facing"
        )
    }

    private static func testIsLANAddress() {
        expect(UnifiedMonitor.isLANAddress("192.168.1.5"), "192.168.0.0/16 is a private LAN range")
        expect(UnifiedMonitor.isLANAddress("10.1.2.3"), "10.0.0.0/8 is a private LAN range")
        expect(UnifiedMonitor.isLANAddress("172.16.0.1"), "172.16.0.0/12's lower bound is a private LAN range")
        expect(!UnifiedMonitor.isLANAddress("172.32.0.1"), "172.32.0.0 is just outside the 172.16-31 private range")
        expect(UnifiedMonitor.isLANAddress("127.0.0.1"), "loopback is a LAN address")
        expect(!UnifiedMonitor.isLANAddress("8.8.8.8"), "a public IPv4 address is not a LAN address")
        expect(UnifiedMonitor.isLANAddress("::1"), "the IPv6 loopback address is a LAN address")
        expect(UnifiedMonitor.isLANAddress("fe80::1"), "fe80::/10 link-local IPv6 is a LAN address")
        expect(!UnifiedMonitor.isLANAddress("2001:4860:4860::8888"), "a public IPv6 address is not a LAN address")
    }

    private static func testParseNetworkQualityJSON() {
        let json = """
        {"dl_throughput": 150000000, "ul_throughput": 20000000, "base_rtt": 12.5, "interface_name": "en0", "test_endpoint": "https://mensura.cdn-apple.com"}
        """
        let result = UnifiedMonitor.parseNetworkQualityJSON(json, measuredAt: Date(timeIntervalSince1970: 0), duration: 10)
        expect(result?.downloadMbps == 150, "dl_throughput is in bits/sec and should be converted to Mbps")
        expect(result?.uploadMbps == 20, "ul_throughput is in bits/sec and should be converted to Mbps")
        expect(result?.latencyMS == 12.5, "base_rtt should be passed through as milliseconds")
        expect(result?.interfaceName == "en0", "interface_name should be extracted as-is")
        expect(result?.endpoint == "https://mensura.cdn-apple.com", "test_endpoint should be extracted as-is")

        expect(
            UnifiedMonitor.parseNetworkQualityJSON("{}", measuredAt: Date(timeIntervalSince1970: 0), duration: 10) == nil,
            "JSON with none of the expected keys should yield no result rather than a zeroed-out one"
        )
    }

    private static func testParseNetworkQualitySummary() {
        let summary = """
        ==== SUMMARY ====
        Uplink capacity: 45.230 Mbps
        Downlink capacity: 220.710 Mbps
        Idle Latency: 8.123 milliseconds
        """
        let result = UnifiedMonitor.parseNetworkQualitySummary(summary, measuredAt: Date(timeIntervalSince1970: 0), duration: 10)
        expect(result?.downloadMbps == 220.71, "'Downlink capacity' line should be parsed as the download rate")
        expect(result?.uploadMbps == 45.23, "'Uplink capacity' line should be parsed as the upload rate")
        expect(result?.latencyMS == 8.123, "'Idle Latency' line should be parsed as the latency")
    }

    private static func testSampleHealthFromIsOK() {
        expect(SampleHealth(isOK: true) == .ok, "a healthy sample should map to .ok")
        expect(SampleHealth(isOK: false) == .degraded, "an unhealthy sample should map to .degraded")
    }
}
