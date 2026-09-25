import Foundation
import SystemBarKit

/// The Dev tab as a plugin: what it declares, and whole collect runs through a fake host.
@MainActor
enum DevPluginTests {
    static func runAll() {
        testPluginIdentityMatchesTheOldTab()
        testSamplingIntervalsStayConservative()
        testCollectRunsItsThreeCommandsThroughTheHost()
        testCollectNamesEachCommandThatFailed()
        testPluginPublishesWhatItCollected()
    }

    private static let listenOutput = """
    COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    node    1234 adam   21u  IPv6 0xabc      0t0  TCP *:3000 (LISTEN)
    Python  2345 adam    7u  IPv4 0xdef      0t0  TCP 127.0.0.1:8000 (LISTEN)
    """

    private static let answers = [
        "/bin/ps -eo pid,ppid,pcpu,rss,etime,args": "  PID  PPID %CPU   RSS     ELAPSED ARGS\n    1     0  0.0 20000 10-00:00:00 /sbin/launchd\n",
        "/usr/sbin/lsof -n -P -iTCP -sTCP:LISTEN": listenOutput,
        "/usr/bin/pmset -g therm": "No thermal warning level has been recorded\nNo performance warning level has been recorded\n",
    ]

    private static func busyFeed(_ percent: Double) -> Feed<FastStatsSnapshot> {
        var snapshot = FastStatsSnapshot()
        snapshot.cpuUsagePercent = percent
        return Feed(initial: snapshot)
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = DevPlugin(host: makeHost())
        expect(DevPlugin.identifier == "dev" && plugin.title == "Dev" && plugin.systemImage == "terminal", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.purple, "and its accent")
        expect(plugin.refreshInterval == 60, "and its 60-second interval")
        expect(plugin.sharedFeeds == [.fastStats], "it declares the 1-second feed, because the capacity grade reads its CPU figure")
    }

    private static func testSamplingIntervalsStayConservative() {
        expect(DevSampling.refreshInterval >= 60, "capacity collector should be conservative")
        expect(DevSampling.sampleWindow < DevSampling.refreshInterval, "the rusage sample window must fit inside the refresh interval so ticks never overlap")
    }

    private static func testCollectRunsItsThreeCommandsThroughTheHost() {
        let recorder = LogRecorder()
        let host = makeHost(fastStats: busyFeed(55), runner: recordingRunner(recorder, answers: answers))
        let snapshot = CapacityCollector.collect(using: host, sampleWindow: 0)
        for command in answers.keys {
            expect(recorder.messages.contains(command), "\(command) runs through the host, got \(recorder.messages)")
        }
        expect(snapshot.cpuBusyPercent == 55, "the grade reads the host's 1-second CPU figure, got \(String(describing: snapshot.cpuBusyPercent))")
        expect(snapshot.ports.map(\.port) == ["3000", "8000"], "listening ports come from lsof, got \(snapshot.ports.map(\.port))")
        expect(snapshot.health == .ok && snapshot.status.hasPrefix("Capacity sample OK"), "three good reads are a healthy sample, got \(snapshot.status)")
        expect(snapshot.assessment != nil && snapshot.lastUpdated != nil, "a finished tick carries a grade and a time")
    }

    private static func testCollectNamesEachCommandThatFailed() {
        let host = makeHost(runner: recordingRunner(LogRecorder(), answers: [:]))
        let snapshot = CapacityCollector.collect(using: host, sampleWindow: 0)
        for failure in ["process table unavailable", "lsof listen unavailable", "thermal warnings unavailable"] {
            expect(snapshot.status.contains(failure), "the status names \(failure), got \(snapshot.status)")
        }
        expect(snapshot.health == .degraded, "a failed read is degraded")
    }

    private static func testPluginPublishesWhatItCollected() {
        let plugin = DevPlugin(host: makeHost(fastStats: busyFeed(12), runner: recordingRunner(LogRecorder(), answers: answers)))
        // The real one-second sample window: collect() blocks for it, as it does on the plugin's queue.
        plugin.collect()
        waitUntil(3) { plugin.capacity.lastUpdated != nil }
        expect(plugin.capacity.cpuBusyPercent == 12, "collect() publishes its snapshot for the panel, got \(String(describing: plugin.capacity.cpuBusyPercent))")
    }
}
