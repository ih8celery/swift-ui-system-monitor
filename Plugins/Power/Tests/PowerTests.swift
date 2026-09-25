import Foundation
import SystemBarKit

/// Main-actor because a plugin is constructed on the main thread, by contract.
@MainActor
enum PowerTests {
    static func runAll() {
        testBatteryParsing()
        testParseSleepAssertions()
        testContributorsComeFromTheProcessFeed()
        testCollectRunsPmsetTwiceAndReadsTheAnswers()
        testCollectSaysWhatIsUnavailableWhenPmsetFails()
        testContributorsFollowTheProcessFeed()
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

    private static func testCollectRunsPmsetTwiceAndReadsTheAnswers() {
        let recorder = PowerCallRecorder()
        let batteryOutput = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1234567)\t77%; charging; 0:20 remaining present: true
        """
        let assertionsOutput = """
                PreventUserIdleSystemSleep     1
        """
        let host = SystemBarPluginTests.makeHost { path, arguments, _, _ in
            recorder.record((path: path, arguments: arguments))
            if arguments == ["-g", "batt"] {
                return CommandOutput(output: batteryOutput, error: "", status: 0, didTimeout: false)
            }
            if arguments == ["-g", "assertions"] {
                return CommandOutput(output: assertionsOutput, error: "", status: 0, didTimeout: false)
            }
            return CommandOutput(output: "", error: "unexpected arguments", status: 1, didTimeout: false)
        }

        let snapshot = PowerCollector.collect(using: host)
        let seen = recorder.seen

        expect(seen.count == 2, "collect reads battery and assertions, got \(seen.count) calls")
        expect(seen.allSatisfy { $0.path == "/usr/bin/pmset" }, "both reads go through pmset, got \(seen.map(\.path))")
        expect(seen.contains { $0.arguments == ["-g", "batt"] }, "one read asks pmset for battery status")
        expect(seen.contains { $0.arguments == ["-g", "assertions"] }, "the other asks pmset for sleep assertions")
        expect(snapshot.batteryPercent == 77, "the snapshot carries the parsed battery percent, got \(String(describing: snapshot.batteryPercent))")
        expect(snapshot.sleepAssertions.contains { $0.contains("PreventUserIdleSystemSleep") }, "the snapshot carries the parsed assertions, got \(snapshot.sleepAssertions)")
        expect(snapshot.status == "Power sample OK", "both reads succeeding reports OK, got \(snapshot.status)")
        expect(snapshot.health == .ok, "both reads succeeding is healthy")
    }

    private static func testCollectSaysWhatIsUnavailableWhenPmsetFails() {
        let host = SystemBarPluginTests.makeHost { _, _, _, _ in
            CommandOutput(output: "", error: "boom", status: 1, didTimeout: false)
        }

        let snapshot = PowerCollector.collect(using: host)

        expect(snapshot.status == "battery unavailable, assertions unavailable", "both failures are named, got \(snapshot.status)")
        expect(snapshot.health == .degraded, "a failed pmset read is degraded")
    }

    private static func testContributorsFollowTheProcessFeed() {
        let feed = Feed(initial: ProcessSummary())
        let host = SystemBarPluginTests.makeHost(processes: feed)
        let plugin = PowerPlugin(host: host)
        let rows = [
            ProcessSnapshot(name: "clang", count: 1, physical: 1_000, virtualSize: 0, cpu: 50),
            ProcessSnapshot(name: "idle", count: 1, physical: 500, virtualSize: 0, cpu: 0),
        ]

        feed.send(ProcessSummary(rows: rows, limit: rows.count))

        let deadline = Date().addingTimeInterval(1)
        while plugin.contributors.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        expect(plugin.contributors.map(\.name) == rows.map(\.name),
               "contributors track the process feed in order, got \(plugin.contributors.map(\.name))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = PowerPlugin(host: SystemBarPluginTests.makeHost())
        expect(PowerPlugin.identifier == "power" && plugin.title == "Power" && plugin.systemImage == "bolt.heart", "the bundle keeps the tab's id, title and icon")
        expect(plugin.refreshInterval == 60 && plugin.sharedFeeds == [.processes], "the bundle keeps the tab's interval and its need for the process feed")
    }
}

/// Captures every `(path, arguments)` pair a `@Sendable` runner closure saw, under a lock,
/// mirroring `Recorder` in SystemBarPluginTests.swift — but keeping every call, since a single
/// `collect()` reads pmset twice and both calls need checking.
private final class PowerCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(path: String, arguments: [String])] = []

    func record(_ call: (path: String, arguments: [String])) {
        lock.withLock { calls.append(call) }
    }

    var seen: [(path: String, arguments: [String])] {
        lock.withLock { calls }
    }
}
