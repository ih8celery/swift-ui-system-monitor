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
        testParserNamesTheLineOfMalformedJSON()
        testParserRejectsMissingPluginsKey()
        testParserRejectsNonObjectRootAndEntry()
        testParserRejectsNonStringName()
        testParserTreatsNullAsAbsent()
        testParserRejectsNullEnabled()
        testStoreUsesApplicationSupportByDefault()
        testStoreHonoursTheEnvironmentOverride()
        testStoreWritesTheDefaultWhenTheFileIsMissing()
        testStoreWritesAFileThatEndsWithANewline()
        testStoreReadsAnExistingFileInsteadOfTheDefault()
        testStoreReportsAnUnreadableFile()
        testStoreReportsAnUnwritableLocation()
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
        expect(text.contains("\"/tmp/Leases.bundle\""), "paths are written without escaped slashes, got: \(text)")
        expect((try? PluginConfigParser.parse(data).get()) == config, "what encode writes, parse reads back unchanged")
    }

    private static func testParserNamesTheLineOfMalformedJSON() {
        let result = parse("""
        { "plugins": [
            { "name": "A.bundle" },
            { name: "B.bundle" }
        ] }
        """)
        guard case .malformedJSON(let detail)? = failure(result) else {
            expect(false, "an unquoted key is malformed JSON")
            return
        }
        expect(detail.hasPrefix("line 3"), "the error names the line the mistake is on, got: \(detail)")
    }

    private static func testParserRejectsMissingPluginsKey() {
        let error = failure(parse("{}"))
        expect(error == .missingKey("plugins", where: "the top level"), "a file without \"plugins\" says so, rather than calling it the wrong type, got \(String(describing: error))")
    }

    private static func testParserRejectsNonObjectRootAndEntry() {
        expect(failure(parse("[]")) == .notAnObject(where: "the top level"), "a top-level list is not a config")
        expect(failure(parse(#"{ "plugins": [ 5 ] }"#)) == .notAnObject(where: "plugins[0]"), "an entry that is not an object is reported at its index")
    }

    private static func testParserRejectsNonStringName() {
        let error = failure(parse(#"{ "plugins": [ { "name": 5 } ] }"#))
        expect(error == .wrongType(key: "name", expected: "a string", where: "plugins[0]"), "a non-string name is a type error, got \(String(describing: error))")
    }

    private static func testParserTreatsNullAsAbsent() {
        let config = try? parse(#"{ "plugins": [ { "name": null, "path": "/x/A.bundle" } ] }"#).get()
        expect(config?.plugins == [PluginEntry(name: nil, path: "/x/A.bundle", isEnabled: true)],
               "JSON null means the same as leaving the key out, so this is a path entry, not \"both\", got \(String(describing: config))")
    }

    private static func testParserRejectsNullEnabled() {
        let error = failure(parse(#"{ "plugins": [ { "name": "A.bundle", "enabled": null } ] }"#))
        expect(error == .wrongType(key: "enabled", expected: "true or false", where: "plugins[0]"),
               "null for enabled is neither true nor false; someone who wrote it probably meant off, so it must not silently mean on, got \(String(describing: error))")
    }

    // MARK: - Config store

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let sampleDefault = PluginConfig.builtins(named: ["CPU.bundle", "Memory.bundle"])

    private static func testStoreUsesApplicationSupportByDefault() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
        let store = PluginConfigStore.standard(environment: [:], applicationSupport: support)
        expect(store.fileURL.path == "/Users/someone/Library/Application Support/SystemBar/plugins.json",
               "the file lives in the app's own Application Support folder, got \(store.fileURL.path)")
    }

    private static func testStoreHonoursTheEnvironmentOverride() {
        let store = PluginConfigStore.standard(
            environment: [PluginConfigStore.environmentOverride: "/tmp/other/plugins.json"],
            applicationSupport: URL(fileURLWithPath: "/ignored")
        )
        expect(store.fileURL.path == "/tmp/other/plugins.json", "SYSTEMBAR_PLUGINS_FILE points the app at another file")
    }

    private static func testStoreWritesTheDefaultWhenTheFileIsMissing() {
        let store = PluginConfigStore(fileURL: temporaryDirectory().appendingPathComponent("nested/plugins.json"))
        let result = store.loadOrCreate(default: sampleDefault)
        expect((try? result.get()) == sampleDefault, "a missing file yields the default, got \(result)")
        expect(FileManager.default.fileExists(atPath: store.fileURL.path), "and the default is written, creating its directory")
        expect((try? store.load().get()) == sampleDefault, "what was written reads back as the same config")
    }

    private static func testStoreWritesAFileThatEndsWithANewline() {
        let store = PluginConfigStore(fileURL: temporaryDirectory().appendingPathComponent("plugins.json"))
        try? store.write(sampleDefault)
        let text = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        expect(text.hasSuffix("\n"), "a hand-edited file ends with a newline so editors and diffs behave")
        expect(!text.hasSuffix("\n\n"), "but only one")
    }

    private static func testStoreReadsAnExistingFileInsteadOfTheDefault() {
        let store = PluginConfigStore(fileURL: temporaryDirectory().appendingPathComponent("plugins.json"))
        let existing = PluginConfig.builtins(named: ["Disk.bundle"])
        try? store.write(existing)
        let result = store.loadOrCreate(default: sampleDefault)
        expect((try? result.get()) == existing, "an existing file wins over the default, got \(result)")
    }

    private static func testStoreReportsAnUnreadableFile() {
        // A directory where the file should be: exists, but cannot be read as data.
        let store = PluginConfigStore(fileURL: temporaryDirectory())
        guard case .failure(.unreadable) = store.loadOrCreate(default: sampleDefault) else {
            expect(false, "a path that exists but cannot be read is reported as unreadable, not silently replaced")
            return
        }
    }

    private static func testStoreReportsAnUnwritableLocation() {
        let store = PluginConfigStore(fileURL: URL(fileURLWithPath: "/systembar-cannot-create-this/plugins.json"))
        guard case .failure(.unwritable) = store.loadOrCreate(default: sampleDefault) else {
            expect(false, "a location the default cannot be written to is reported, not swallowed")
            return
        }
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
