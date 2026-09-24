import Foundation
import SwiftUI

/// Tests for the plugin model: the contract a tab conforms to and the runner the host gives it.
/// Later tasks add the config file and the catalog here.
struct SystemBarPluginTests {
    static func runAll() {
        testPluginIsConstructedThroughItsMetatype()
        testHostServicesForwardsToTheRunner()
        testRunnerPassesAnExplicitEnvironment()
        testRunnerInheritsTheEnvironmentByDefault()
        testParserReadsEveryEntryShape()
        testParserDefaultsEnabledToTrue()
        testParserRejectsUnknownTopLevelKey()
        testParserRejectsUnknownEntryKey()
        testParserRejectsBothNameAndPath()
        testParserRejectsNeitherNameNorPath()
        testParserRejectsNonBooleanEnabled()
        testParserRejectsNonListPlugins()
        testParserReportsMalformedJSON()
        testEncodeThenParseRoundTrips()
    }

    static func makeHost(
        runner: @escaping CommandRunner = { _, _, _, _ in
            CommandOutput(output: "", error: "", status: 0, didTimeout: false)
        }
    ) -> HostServices {
        HostServices(homeDirectory: "/tmp/systembar-tests", runner: runner, log: { _ in })
    }

    // MARK: - Contract

    private static func testPluginIsConstructedThroughItsMetatype() {
        let type: TabPlugin.Type = FakeTab.self
        let plugin = type.init(host: makeHost())
        expect(type.identifier == "fake", "the identifier is read from the metatype, not the instance")
        expect(plugin.title == "Fake", "the instance carries its title")
        _ = plugin.makeView()
        plugin.visibilityChanged(isVisible: true)
        // FakeTab does not write visibilityChanged; compiling it proves the default exists.
    }

    private static func testHostServicesForwardsToTheRunner() {
        var seen: (path: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval)?
        let host = makeHost { path, arguments, environment, timeout in
            seen = (path, arguments, environment, timeout)
            return CommandOutput(output: "ran", error: "", status: 0, didTimeout: false)
        }
        let output = host.run(path: "/bin/echo", arguments: ["hi"], environment: ["PATH": "/x"], timeout: 3)
        expect(output.output == "ran", "run returns what the runner returned")
        expect(seen?.path == "/bin/echo" && seen?.arguments == ["hi"], "path and arguments reach the runner unchanged")
        expect(seen?.environment == ["PATH": "/x"] && seen?.timeout == 3, "environment and timeout reach the runner unchanged")
    }

    // MARK: - Runner

    private static func testRunnerPassesAnExplicitEnvironment() {
        let output = ProcessRunner.run(path: "/usr/bin/env", arguments: [], environment: ["SYSTEMBAR_TEST": "yes"])
        expect(output.status == 0, "env should exit cleanly")
        expect(output.output.trimmingCharacters(in: .whitespacesAndNewlines) == "SYSTEMBAR_TEST=yes",
               "an explicit environment replaces the inherited one entirely, got: \(output.output)")
    }

    private static func testRunnerInheritsTheEnvironmentByDefault() {
        let output = ProcessRunner.run(path: "/usr/bin/env", arguments: [])
        expect(output.status == 0, "env should exit cleanly, got status \(output.status)")
        let inherited = ProcessInfo.processInfo.environment
        guard let key = inherited.keys.sorted().first(where: { inherited[$0]?.isEmpty == false }) else {
            expect(false, "the test process has no environment to inherit from")
            return
        }
        expect(output.output.contains("\(key)="), "with no environment given, the child inherits this process's; expected \(key) in: \(output.output.prefix(200))")
    }

    // MARK: - Config parsing

    private static func parse(_ json: String) -> Result<PluginConfig, PluginConfigError> {
        PluginConfigParser.parse(Data(json.utf8))
    }

    private static func failure(_ result: Result<PluginConfig, PluginConfigError>) -> PluginConfigError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private static func testParserReadsEveryEntryShape() {
        let result = parse("""
        { "plugins": [
            { "name": "CPU.bundle" },
            { "path": "~/Library/Application Support/SystemBar/PlugIns/Leases.bundle", "enabled": true },
            { "name": "Power.bundle", "enabled": false }
        ] }
        """)
        let expected = PluginConfig(plugins: [
            PluginEntry(name: "CPU.bundle", path: nil, isEnabled: true),
            PluginEntry(name: nil, path: "~/Library/Application Support/SystemBar/PlugIns/Leases.bundle", isEnabled: true),
            PluginEntry(name: "Power.bundle", path: nil, isEnabled: false),
        ])
        expect((try? result.get()) == expected, "name, path and enabled entries parse in order: \(result)")
    }

    private static func testParserDefaultsEnabledToTrue() {
        let config = try? parse(#"{ "plugins": [ { "name": "CPU.bundle" } ] }"#).get()
        expect(config?.plugins.first?.isEnabled == true, "an entry without \"enabled\" is enabled")
    }

    private static func testParserRejectsUnknownTopLevelKey() {
        let error = failure(parse(#"{ "plugin": [] }"#))
        expect(error == .unknownKey("plugin", where: "the top level"), "a misspelt top-level key is an error, got \(String(describing: error))")
    }

    private static func testParserRejectsUnknownEntryKey() {
        let error = failure(parse(#"{ "plugins": [ { "name": "CPU.bundle", "enable": false } ] }"#))
        expect(error == .unknownKey("enable", where: "plugins[0]"), "a misspelt entry key cannot silently do nothing, got \(String(describing: error))")
    }

    private static func testParserRejectsBothNameAndPath() {
        let error = failure(parse(#"{ "plugins": [ { "name": "A.bundle", "path": "/x/A.bundle" } ] }"#))
        expect(error == .entryHasBoth(where: "plugins[0]"), "an entry says where it is exactly one way, got \(String(describing: error))")
    }

    private static func testParserRejectsNeitherNameNorPath() {
        let error = failure(parse(#"{ "plugins": [ { "name": "A.bundle" }, { "enabled": true } ] }"#))
        expect(error == .entryNeedsNameOrPath(where: "plugins[1]"), "an entry with no location is an error at its own index, got \(String(describing: error))")
    }

    private static func testParserRejectsNonBooleanEnabled() {
        let error = failure(parse(#"{ "plugins": [ { "name": "A.bundle", "enabled": 1 } ] }"#))
        expect(error == .wrongType(key: "enabled", expected: "true or false", where: "plugins[0]"),
               "JSON 1 is not a boolean even though NSNumber would let it through, got \(String(describing: error))")
    }

    private static func testParserRejectsNonListPlugins() {
        let error = failure(parse(#"{ "plugins": { "name": "A.bundle" } }"#))
        expect(error == .wrongType(key: "plugins", expected: "a list", where: "the top level"), "plugins must be a list, got \(String(describing: error))")
    }

    private static func testParserReportsMalformedJSON() {
        guard case .malformedJSON(let detail)? = failure(parse(#"{ "plugins": [ "#)) else {
            expect(false, "truncated JSON must be reported as malformed")
            return
        }
        expect(!detail.isEmpty, "the malformed-JSON error carries Foundation's description of where it went wrong")
    }

    private static func testEncodeThenParseRoundTrips() {
        let config = PluginConfig(plugins: [
            PluginEntry(name: "CPU.bundle", path: nil, isEnabled: true),
            PluginEntry(name: nil, path: "/tmp/Leases.bundle", isEnabled: false),
        ])
        guard let data = try? PluginConfigParser.encode(config) else {
            expect(false, "encoding a config must not throw")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        expect(text.contains("\"enabled\" : false"), "a disabled entry writes enabled: false")
        expect(!text.contains("\"enabled\" : true"), "an enabled entry leaves enabled out, since true is the default")
        expect((try? PluginConfigParser.parse(data).get()) == config, "what encode writes, parse reads back unchanged")
    }
}

/// The smallest possible plugin. Shared by every test that needs a tab.
final class FakeTab: TabPlugin {
    static let identifier = "fake"
    let title = "Fake"
    let systemImage = "questionmark"
    let accent = Color.white
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(Text("fake")) }
}
