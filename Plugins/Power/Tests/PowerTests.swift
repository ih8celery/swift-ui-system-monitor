import Foundation
import SystemBarKit

/// Main-actor because a plugin is constructed on the main thread, by contract.
@MainActor
enum PowerTests {
    static func runAll() {
        testBatteryParsing()
        testParseSleepAssertions()
        testContributorsComeFromTheProcessFeed()
        testPluginIdentityMatchesTheOldTab()
    }

    private static func testBatteryParsing() {
        let sample = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1234567)\t92%; charging; 0:14 remaining present: true
        """
        let parsed = PowerCollector.parseBatteryStatus(sample)
        expect(parsed.powerSource == "AC Power", "battery parser should extract power source")
        expect(parsed.percent == 92, "battery parser should extract percentage")
        expect(parsed.isCharging == true, "battery parser should identify charging state")
    }

    private static func testParseSleepAssertions() {
        let output = """
                PreventUserIdleSystemSleep     1
                PreventUserIdleDisplaySleep    0
                UserIsActive                   1
                AssertionType: PreventSystemSleep = 0
        """
        let assertions = PowerCollector.parseSleepAssertions(output)
        expect(assertions.count == 2, "only lines mentioning 'prevent' that aren't explicitly zeroed should be kept")
        expect(assertions.contains { $0.contains("PreventUserIdleSystemSleep") }, "an active prevent-sleep assertion should be included")
        expect(!assertions.contains { $0.contains("UserIsActive") }, "a line not mentioning 'prevent' should be excluded")
        expect(!assertions.contains { $0.contains("= 0") }, "an assertion explicitly set to 0 should be excluded")
    }

    private static func testContributorsComeFromTheProcessFeed() {
        let rows = [
            ProcessSnapshot(name: "clang", count: 4, physical: 2_000_000, virtualSize: 0, cpu: 240),
            ProcessSnapshot(name: "idle", count: 1, physical: 1_000, virtualSize: 0, cpu: 0),
        ]
        let contributors = PowerCollector.contributors(from: rows)
        expect(contributors.map(\.name) == ["clang", "idle"], "contributors are the feed's top CPU rows in order")
        expect(contributors[0].evidence.contains("CPU") && contributors[0].evidence.contains("memory"), "each contributor says why, got \(contributors[0].evidence)")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let host = HostServices(
            homeDirectory: "/tmp",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: ProcessRunner.run,
            log: { _ in }
        )
        let plugin = PowerPlugin(host: host)
        expect(PowerPlugin.identifier == "power" && plugin.title == "Power" && plugin.systemImage == "bolt.heart", "the bundle keeps the tab's id, title and icon")
        expect(plugin.refreshInterval == 60 && plugin.sharedFeeds == [.processes], "the bundle keeps the tab's interval and its need for the process feed")
    }
}
