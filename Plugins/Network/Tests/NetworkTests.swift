import Foundation
import SystemBarKit

/// The Network tab: nettop and lsof parsing, the hostname cache, the speed test, and the plugin
/// that runs them and follows the 1-second feed.
@MainActor
enum NetworkTests {
    static func runAll() {
        testHostnameCacheEntryExpiry()
        testParseCSVLine()
        testParseNettopCSV()
        testParseLsofTCP()
        testIsLANAddress()
        testParseNetworkQualityJSON()
        testParseNetworkQualitySummary()
        testSampleRunsNettopAndLsofThroughTheHost()
        testSampleSaysWhichCommandFailed()
        testSummaryKeepsResolvedNamesAcrossSamples()
        testSpeedTestRunsNetworkQualityThroughTheHost()
        testSpeedTestStateShowsEachStage()
        testSpeedTestSaysItTimedOut()
        testSpeedTestReportsNetworkQualitysOwnError()
        testSpeedTestPartialRunKeepsTheLastGoodThroughput()
        testPluginRunsTheSpeedTestOffTheMainThread()
        testPluginPublishesWhatItCollected()
        testPluginFollowsTheFastFeed()
        testPluginIdentityMatchesTheOldTab()
    }

    private static func testHostnameCacheEntryExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)

        let freshFailure = HostnameCacheEntry(hostname: "", cachedAt: now)
        expect(
            NetworkCollector.isHostnameCacheEntryValid(freshFailure, now: now, ttl: 60),
            "a failed lookup should stay cached until its TTL elapses"
        )

        let staleFailure = HostnameCacheEntry(hostname: "", cachedAt: now.addingTimeInterval(-61))
        expect(
            !NetworkCollector.isHostnameCacheEntryValid(staleFailure, now: now, ttl: 60),
            "a failed lookup past its TTL should be treated as expired so it can be retried"
        )

        let oldSuccess = HostnameCacheEntry(hostname: "example.com", cachedAt: now.addingTimeInterval(-100_000))
        expect(
            NetworkCollector.isHostnameCacheEntryValid(oldSuccess, now: now, ttl: 60),
            "a successful lookup should never expire regardless of age"
        )
    }

    private static func testParseCSVLine() {
        expect(
            NetworkCollector.parseCSVLine("foo,bar,baz") == ["foo", "bar", "baz"],
            "a plain comma-separated line should split on every comma"
        )
        expect(
            NetworkCollector.parseCSVLine("x,\"1,2,3\",y") == ["x", "1,2,3", "y"],
            "commas inside a quoted field must not split the field"
        )
        expect(
            NetworkCollector.parseCSVLine("a,\"say \"\"hi\"\"\",b") == ["a", "say \"hi\"", "b"],
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
        let rows = NetworkCollector.parseNettopCSV(csv).reduce(into: [String: NetworkProcessSnapshot]()) { $0[$1.name] = $1 }

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
        let connections = NetworkCollector.parseLsofTCP(output)

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
        expect(NetworkCollector.isLANAddress("192.168.1.5"), "192.168.0.0/16 is a private LAN range")
        expect(NetworkCollector.isLANAddress("10.1.2.3"), "10.0.0.0/8 is a private LAN range")
        expect(NetworkCollector.isLANAddress("172.16.0.1"), "172.16.0.0/12's lower bound is a private LAN range")
        expect(!NetworkCollector.isLANAddress("172.32.0.1"), "172.32.0.0 is just outside the 172.16-31 private range")
        expect(NetworkCollector.isLANAddress("127.0.0.1"), "loopback is a LAN address")
        expect(!NetworkCollector.isLANAddress("8.8.8.8"), "a public IPv4 address is not a LAN address")
        expect(NetworkCollector.isLANAddress("::1"), "the IPv6 loopback address is a LAN address")
        expect(NetworkCollector.isLANAddress("fe80::1"), "fe80::/10 link-local IPv6 is a LAN address")
        expect(!NetworkCollector.isLANAddress("2001:4860:4860::8888"), "a public IPv6 address is not a LAN address")
    }

    private static func testParseNetworkQualityJSON() {
        let json = """
        {"dl_throughput": 150000000, "ul_throughput": 20000000, "base_rtt": 12.5, "interface_name": "en0", "test_endpoint": "https://mensura.cdn-apple.com"}
        """
        let result = SpeedTest.parseNetworkQualityJSON(json, measuredAt: Date(timeIntervalSince1970: 0), duration: 10)
        expect(result?.downloadMbps == 150, "dl_throughput is in bits/sec and should be converted to Mbps")
        expect(result?.uploadMbps == 20, "ul_throughput is in bits/sec and should be converted to Mbps")
        expect(result?.latencyMS == 12.5, "base_rtt should be passed through as milliseconds")
        expect(result?.interfaceName == "en0", "interface_name should be extracted as-is")
        expect(result?.endpoint == "https://mensura.cdn-apple.com", "test_endpoint should be extracted as-is")

        expect(
            SpeedTest.parseNetworkQualityJSON("{}", measuredAt: Date(timeIntervalSince1970: 0), duration: 10) == nil,
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
        let result = SpeedTest.parseNetworkQualitySummary(summary, measuredAt: Date(timeIntervalSince1970: 0), duration: 10)
        expect(result?.downloadMbps == 220.71, "'Downlink capacity' line should be parsed as the download rate")
        expect(result?.uploadMbps == 45.23, "'Uplink capacity' line should be parsed as the upload rate")
        expect(result?.latencyMS == 8.123, "'Idle Latency' line should be parsed as the latency")
    }

    private static let nettopCommand = "/usr/bin/nettop -d -P -L 2 -s 1 -x -n -J bytes_in,bytes_out"
    private static let lsofCommand = "/usr/sbin/lsof -n -P -iTCP"
    private static let speedTestCommand = "/usr/bin/networkQuality -c -M 20"

    private static let nettopOutput = """
    Name,bytes_in,bytes_out
    Safari.501,1000,500
    Chrome.502,2000,800
    Name,bytes_in,bytes_out
    Safari.501,50,20
    Chrome.502,80,40
    """

    private static let lsofOutput = """
    COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    Safari   1234  adamu   50u  IPv4 0x1  0t0  TCP 192.168.1.5:54321->17.253.144.10:443 (ESTABLISHED)
    Terminal 5555  adamu   12u  IPv4 0x4  0t0  TCP 192.168.1.5:60000->192.168.1.10:22 (ESTABLISHED)
    """

    /// Only a LAN connection, so a plugin test never starts a real reverse-DNS lookup.
    private static let lanOnlyLsofOutput = """
    COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    Terminal 5555  adamu   12u  IPv4 0x4  0t0  TCP 192.168.1.5:60000->192.168.1.10:22 (ESTABLISHED)
    """

    private static let speedTestJSON = """
    {"dl_throughput": 150000000, "ul_throughput": 20000000, "base_rtt": 12.5, "interface_name": "en0", "test_endpoint": "https://mensura.cdn-apple.com"}
    """

    private static func testSampleRunsNettopAndLsofThroughTheHost() {
        let recorder = LogRecorder()
        let collector = NetworkCollector(host: makeHost(runner: recordingRunner(recorder, answers: [nettopCommand: nettopOutput, lsofCommand: lsofOutput])))
        let reading = collector.sample()
        expect(Set(recorder.messages) == [nettopCommand, lsofCommand], "nettop and lsof run through the host by explicit path, got \(recorder.messages)")
        expect(reading.processes.map(\.name) == ["Chrome", "Safari"], "busiest first, by combined rate, got \(reading.processes.map(\.name))")
        expect(reading.destinations.map(\.remoteAddress) == ["17.253.144.10"], "only internet destinations are listed, got \(reading.destinations.map(\.remoteAddress))")
        expect(reading.status == "Network sample OK" && reading.health == .ok, "two good reads are a healthy sample, got \(reading.status)")
    }

    private static func testSampleSaysWhichCommandFailed() {
        let collector = NetworkCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        let reading = collector.sample()
        expect(reading.status == "nettop unavailable, lsof unavailable" && reading.health == .degraded, "each failed command is named, got \(reading.status)")
        expect(reading.processes.isEmpty && reading.destinations.isEmpty, "and nothing is invented")
    }

    private static func testSummaryKeepsResolvedNamesAcrossSamples() {
        let named = NetworkSummary().resolving("17.253.144.10", to: "apple.com")
        expect(named.resolvedHostnames == ["17.253.144.10": "apple.com"], "a finished lookup is recorded by address")
        let next = named.applying(NetworkReading(processes: [], destinations: [], status: "Network sample OK", health: .ok))
        expect(next.resolvedHostnames["17.253.144.10"] == "apple.com", "a new sample keeps the names already resolved")
        expect(next.status == "Network sample OK" && next.health == .ok, "and takes the new status")
    }

    private static func testSpeedTestRunsNetworkQualityThroughTheHost() {
        let recorder = LogRecorder()
        let outcome = SpeedTest.measure(using: makeHost(runner: recordingRunner(recorder, answers: [speedTestCommand: speedTestJSON])), startedAt: Date())
        expect(recorder.messages == [speedTestCommand], "networkQuality runs through the host by explicit path, got \(recorder.messages)")
        expect(outcome.result?.downloadMbps == 150 && outcome.result?.uploadMbps == 20, "its JSON is read, got \(String(describing: outcome.result))")

        let failing = makeHost(runner: { _, _, _, _ in
            CommandOutput(output: "", error: "no network\nsecond line", status: 1, didTimeout: false)
        })
        let failed = SpeedTest.measure(using: failing, startedAt: Date())
        expect(failed.result == nil && failed.failure == "Failed: no network", "a failed run says why in one line, got \(failed.failure)")
    }

    private static func testSpeedTestStateShowsEachStage() {
        let idle = SpeedTestState()
        expect(!idle.isRunning && idle.status == "Ready" && idle.health == .ok && idle.result == nil, "a fresh tab is ready")
        let running = idle.started()
        expect(running.isRunning && running.status == "Testing", "pressing the button shows it testing")

        let result = SpeedTestResult(downloadMbps: 100, uploadMbps: 10, latencyMS: 9, interfaceName: "en0", endpoint: "x", measuredAt: Date(timeIntervalSince1970: 0), duration: 12)
        let done = running.finished(with: SpeedTestOutcome(result: result, failure: "unused"))
        expect(!done.isRunning && done.result?.downloadMbps == 100 && done.health == .ok, "a good run shows its result")
        expect(done.status.hasPrefix("Last run "), "and when it ran, got \(done.status)")

        let failed = done.started().finished(with: SpeedTestOutcome(result: nil, failure: "Failed: offline"))
        expect(failed.status == "Failed: offline" && failed.health == .degraded, "a failed run says why")
        expect(failed.result?.downloadMbps == 100, "and keeps the last good result on screen")
    }

    /// On a bad link networkQuality ignores -M and runs until the host kills it.
    private static func testSpeedTestSaysItTimedOut() {
        let killed = makeHost(runner: { _, _, _, _ in
            CommandOutput(output: "", error: "", status: -1, didTimeout: true)
        })
        let outcome = SpeedTest.measure(using: killed, startedAt: Date())
        expect(outcome.result == nil, "a killed run has no result")
        expect(outcome.failure.localizedCaseInsensitiveContains("timed out"), "a killed run says it timed out, got \(outcome.failure)")
    }

    /// What networkQuality really printed, exit 0, when it could not reach its server.
    private static func testSpeedTestReportsNetworkQualitysOwnError() {
        let json = """
        {"end_date": "2026-09-30 16:16:01.185", "error_code": -1003, "error_domain": "NSURLErrorDomain", "os_version": "Version 26.6 (Build 25G72)", "start_date": "2026-09-30 16:16:01.173"}
        """
        let outcome = SpeedTest.measure(using: makeHost(runner: recordingRunner(LogRecorder(), answers: [speedTestCommand: json])), startedAt: Date())
        expect(outcome.result == nil, "an error run has no result")
        expect(outcome.failure != "Speed test output unreadable" && outcome.failure.contains("-1003"), "the error networkQuality reported is shown, got \(outcome.failure)")
    }

    /// Latency measured, then the throughput phase failed.
    private static func testSpeedTestPartialRunKeepsTheLastGoodThroughput() {
        let json = """
        {"base_rtt": 850.0, "error_code": -1001, "error_domain": "NSURLErrorDomain", "interface_name": "en0"}
        """
        let outcome = SpeedTest.measure(using: makeHost(runner: recordingRunner(LogRecorder(), answers: [speedTestCommand: json])), startedAt: Date())
        let good = SpeedTestResult(downloadMbps: 100, uploadMbps: 10, latencyMS: 9, interfaceName: "en0", endpoint: "x", measuredAt: Date(timeIntervalSince1970: 0), duration: 12)
        let before = SpeedTestState().started().finished(with: SpeedTestOutcome(result: good, failure: "unused"))
        let after = before.started().finished(with: outcome)
        expect(after.health == .degraded, "a run that reported an error is not shown as healthy, got \(after.status)")
        expect(after.result?.downloadMbps == 100, "and the last good throughput stays on screen, got \(String(describing: after.result))")
    }

    private static func testPluginRunsTheSpeedTestOffTheMainThread() {
        let plugin = NetworkPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [speedTestCommand: speedTestJSON])))
        plugin.runSpeedTest()
        expect(plugin.speedTest.isRunning, "the button shows the test running at once, before networkQuality answers")
        waitUntil(2) { !plugin.speedTest.isRunning }
        expect(plugin.speedTest.result?.downloadMbps == 150, "the result lands on main when the run finishes, got \(String(describing: plugin.speedTest.result))")
    }

    private static func testPluginPublishesWhatItCollected() {
        let answers = [nettopCommand: nettopOutput, lsofCommand: lanOnlyLsofOutput]
        let plugin = NetworkPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)))
        plugin.collect()
        waitUntil { !plugin.summary.processes.isEmpty }
        expect(plugin.summary.processes.map(\.name) == ["Chrome", "Safari"], "collect() publishes the sample for the panel, got \(plugin.summary.processes.map(\.name))")
        expect(plugin.summary.destinations.isEmpty && plugin.summary.status == "Network sample OK", "a LAN-only connection lists no destination")
    }

    private static func testPluginFollowsTheFastFeed() {
        var start = FastStatsSnapshot()
        start.currentDownloadRate = 5
        let feed = Feed(initial: start)
        let plugin = NetworkPlugin(host: makeHost(fastStats: feed))
        expect(plugin.fastStats.currentDownloadRate == 5, "a new plugin starts from the feed's latest reading")

        var next = FastStatsSnapshot()
        next.currentDownloadRate = 2_048
        next.downloadHistory = [5, 2_048]
        feed.send(next)
        waitUntil { plugin.fastStats.currentDownloadRate == 2_048 }
        expect(plugin.fastStats.downloadHistory == [5, 2_048], "the rate cards and graph follow the 1-second feed, got \(plugin.fastStats.downloadHistory)")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = NetworkPlugin(host: makeHost())
        expect(NetworkPlugin.identifier == "network" && plugin.title == "Network" && plugin.systemImage == "arrow.up.arrow.down", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.blue, "and its accent")
        expect(plugin.refreshInterval == 30, "network refresh interval should protect idle CPU")
        expect(plugin.sharedFeeds == [.fastStats], "it reads the 1-second feed for its rates and graph")
        expect(NetworkCollector.negativeHostnameCacheTTL == 60, "a failed reverse lookup is retried after a minute")
    }
}
