import Foundation
import SystemBarKit

/// The CPU tab: the tap-to-explain drill-in, and the plugin that follows both shared feeds.
@MainActor
enum CPUTests {
    static func runAll() {
        testParentChainWalk()
        testGroupDetailRows()
        testProcessClassifier()
        testGroupDetailRunsPsThroughTheHost()
        testGroupDetailFindsAnAppWhosePathHasSpaces()
        testPluginFollowsBothFeeds()
        testPluginIdentityMatchesTheOldTab()
        testClusterLayoutPutsTheSlowestClusterAtCoreZero()
        testClusterUsageIsTheMeanOfItsCores()
        testThermalSpeedLimitParsing()
    }

    // A `ps -eo pid,ppid,pcpu,rss,etime,args` sample. Leading fields are
    // space-free; args is the whole trailing remainder (spaces preserved).
    // A copy of the one in SystemBarPerformanceTests, which tests the SDK parser with it.
    private static let psSample = """
    PID  PPID %CPU   RSS     ELAPSED ARGS
      1     0  0.0  20000 10-00:00:00 /sbin/launchd
    100     1  1.5   5000    01:00:00 /usr/bin/ssh-agent -l
    200   100 50.0  40000    00:10:00 /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c foo.c
    201   200 40.0  30000    00:05:00 /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c bar.c
    """

    private static func testParentChainWalk() {
        let map = ProcessTable.parse(psSample)

        let twoHops = ProcessDetail.parentChain(of: 201, in: map, hops: 2)
        expect(twoHops == ["clang", "ssh-agent"], "2-hop walk resolves parent then grandparent names")

        // A chain that runs out before 2 hops must not crash or invent names.
        let short = ProcessDetail.parentChain(of: 100, in: map, hops: 2)
        expect(short == ["launchd"], "walk stops when the chain is shorter than the hop count")

        let none = ProcessDetail.parentChain(of: 1, in: map, hops: 2)
        expect(none.isEmpty, "a process whose parent is not in the map yields no ancestors")
    }

    private static func testGroupDetailRows() {
        let map = ProcessTable.parse(psSample)
        let rows = ProcessDetail.groupDetail(name: "clang", in: map, coreCount: 8)
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

    private static func testGroupDetailRunsPsThroughTheHost() {
        let recorder = LogRecorder()
        let command = "/bin/ps -eo pid,ppid,pcpu,rss,etime,args"
        let plugin = CPUPlugin(host: makeHost(runner: recordingRunner(recorder, answers: [command: psSample])))
        let rows = plugin.groupDetail(named: "clang")
        expect(rows.map(\.pid).sorted() == [200, 201], "a tap lists every process in the group, got \(rows.map(\.pid))")
        expect(recorder.messages == [command], "one ps, through the host, by explicit path, got \(recorder.messages)")

        let failing = CPUPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.groupDetail(named: "clang").isEmpty, "a ps that fails gives an empty drill-in rather than a guess")
    }

    private static func testGroupDetailFindsAnAppWhosePathHasSpaces() {
        // The group a user taps is named from ps's comm column, so Chrome's group is "Google Chrome".
        // The existence check is a fake so the test does not depend on Chrome being installed.
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let table = """
        PID  PPID %CPU   RSS     ELAPSED ARGS
          1     0  0.0  20000 10-00:00:00 /sbin/launchd
        300     1 12.0  90000    02:00:00 \(chrome) --restore-last-session
        301   300  4.0  50000    01:00:00 /usr/bin/ssh-agent -l
        """
        let command = "/bin/ps -eo pid,ppid,pcpu,rss,etime,args"
        let host = makeHost(runner: recordingRunner(LogRecorder(), answers: [command: table]))
        let rows = ProcessDetail.fetchGroupDetail(name: "Google Chrome", using: host, fileExists: { [chrome, "/sbin/launchd", "/usr/bin/ssh-agent"].contains($0) })
        expect(rows.map(\.pid) == [300], "tapping Google Chrome lists Chrome's process, got \(rows.map(\.pid))")
        expect(rows.first?.path == chrome && rows.first?.parentName == "launchd", "the row carries the whole path and its parent, got \(String(describing: rows.first?.path))")
    }

    private static func testPluginFollowsBothFeeds() {
        var start = FastStatsSnapshot()
        start.cpuUsagePercent = 10
        let fastStats = Feed(initial: start)
        let processes = Feed(initial: ProcessSummary())
        let plugin = CPUPlugin(host: makeHost(processes: processes, fastStats: fastStats))
        expect(plugin.fastStats.cpuUsagePercent == 10, "a new plugin starts from the feed's latest reading")

        var busy = FastStatsSnapshot()
        busy.cpuUsagePercent = 73
        busy.cpuHistory = [10, 73]
        fastStats.send(busy)
        let row = ProcessSnapshot(name: "swift-frontend", count: 3, physical: 1, virtualSize: 0, cpu: 250)
        processes.send(ProcessSummary(rows: [row], memoryLimit: 1, cpuLimit: 1))

        waitUntil { plugin.fastStats.cpuUsagePercent == 73 && !plugin.processes.topCPU.isEmpty }
        expect(plugin.fastStats.cpuHistory == [10, 73], "the headline and graph follow the 1-second feed, got \(plugin.fastStats.cpuHistory)")
        expect(plugin.processes.topCPU.map(\.name) == ["swift-frontend"] && plugin.processes.totalCount == 1, "the list and count follow the process feed")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = CPUPlugin(host: makeHost())
        expect(CPUPlugin.identifier == "cpu" && plugin.title == "CPU" && plugin.systemImage == "cpu", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.warning, "and its accent")
        expect(plugin.sharedFeeds == [.processes, .fastStats], "it needs both shared feeds")
        expect(plugin.refreshInterval == PluginScheduler.maximumRefreshInterval, "its collect() does nothing, so it asks to be called as rarely as the host allows, got \(plugin.refreshInterval)")
    }

    // MARK: - Machine state

    private static func testClusterLayoutPutsTheSlowestClusterAtCoreZero() {
        // This Mac: sysctl lists Super (6) then Performance (12); the device tree puts the
        // Performance cores at 0-11 and the Super cores at 12-17.
        let thisMac = CPUClusters.layout(names: ["Super", "Performance"], counts: [6, 12], coreCount: 18)
        expect(thisMac == [CPUCluster(name: "Super", cores: 12..<18), CPUCluster(name: "Performance", cores: 0..<12)],
               "perflevel 0 is the fastest cluster and takes the last core indices, got \(String(describing: thisMac))")

        let m1 = CPUClusters.layout(names: ["Performance", "Efficiency"], counts: [4, 4], coreCount: 8)
        expect(m1 == [CPUCluster(name: "Performance", cores: 4..<8), CPUCluster(name: "Efficiency", cores: 0..<4)],
               "an M1's efficiency cores are 0-3, got \(String(describing: m1))")

        expect(CPUClusters.layout(names: ["Only"], counts: [8], coreCount: 8) == [CPUCluster(name: "Only", cores: 0..<8)],
               "one perflevel covers every core")
        expect(CPUClusters.layout(names: ["A", "B"], counts: [4, 4], coreCount: 10) == nil,
               "counts that do not add up to the core count give nil, so the view falls back to per-core bars")
        expect(CPUClusters.layout(names: [], counts: [], coreCount: 8) == nil, "no perflevels at all is nil too")
        expect(CPUClusters.layout(names: ["A"], counts: [4, 4], coreCount: 8) == nil, "mismatched name and count lists are nil rather than a trap")
    }

    private static func testClusterUsageIsTheMeanOfItsCores() {
        let cluster = CPUCluster(name: "Super", cores: 2..<4)
        expect(cluster.usage(perCore: [0, 0, 80, 20]) == 50, "a cluster's usage is the mean of its cores, got \(cluster.usage(perCore: [0, 0, 80, 20]))")
        expect(cluster.usage(perCore: []) == 0, "before the feed has per-core figures the cluster reads 0")
        expect(cluster.usage(perCore: [1, 2, 3]) == 0, "a feed with fewer cores than the cluster expects reads 0 rather than trapping")
        expect(cluster.coreCount == 2, "the core count is the range's length")
    }

    private static func testThermalSpeedLimitParsing() {
        let quiet = "Note: No thermal warning level has been recorded\nNote: No performance warning level has been recorded\nNote: No CPU power status has been recorded\n"
        expect(CPUThermal.parseSpeedLimit(quiet) == nil, "no CPU power status means no speed limit to show")

        let throttled = "CPU Power notify\n\tCPU_Scheduler_Limit \t= 100\n\tCPU_Available_CPUs \t= 18\n\tCPU_Speed_Limit \t= 80\n"
        expect(CPUThermal.parseSpeedLimit(throttled) == 80, "the speed limit is the CPU_Speed_Limit line, got \(String(describing: CPUThermal.parseSpeedLimit(throttled)))")
        expect(CPUThermal.parseSpeedLimit("CPU_Speed_Limit = banana") == nil, "a value that is not a number is nil, not a crash")

        expect(ThermalReading(state: .nominal, speedLimitPercent: nil).isNominal, "nominal with nothing recorded has nothing to say")
        expect(ThermalReading(state: .nominal, speedLimitPercent: 100).isNominal, "full speed is nothing to say either")
        expect(!ThermalReading(state: .fair, speedLimitPercent: nil).isNominal, "a fair state is worth a line")
        expect(!ThermalReading(state: .nominal, speedLimitPercent: 80).isNominal, "and so is a speed limit under 100")
    }
}
