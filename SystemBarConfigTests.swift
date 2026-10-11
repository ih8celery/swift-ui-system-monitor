import Foundation
import SystemBarKit

/// Tests for the plugin contract, the runner HostServices forwards to, and the plugins.json
/// parser and store.
@MainActor
struct SystemBarConfigTests {
    static func runAll() {
        testPluginIsConstructedThroughItsMetatype()
        testHostServicesForwardsToTheRunner()
        testPluginSettingsReadsTypedValuesAndTellsAbsentFromWrongType()
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
        testParserTreatsNullLocationAsAbsent()
        testParserRejectsNullEnabled()
        testParserKeepsTheFirstOfTwoDuplicateKeys()
        testParserAcceptsATrailingComma()
        testStoreUsesApplicationSupportByDefault()
        testStoreHonoursTheEnvironmentOverride()
        testStoreWritesTheDefaultWhenTheFileIsMissing()
        testStoreWritesAFileThatEndsWithANewline()
        testStoreReadsAnExistingFileInsteadOfTheDefault()
        testStoreReportsAnUnreadableFile()
        testStoreReportsAnUnwritableLocation()
        testStoreExpandsTildeInTheOverride()
        testStoreSaysWhenAFolderSitsWhereTheFileShouldBe()
        testPluginFolderUsesApplicationSupportByDefault()
        testPluginFolderHonoursTheEnvironmentOverride()
        testPluginFolderExpandsTildeInTheOverride()
        testPluginFolderIgnoresAnEmptyOverride()
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

    private static func testPluginSettingsReadsTypedValuesAndTellsAbsentFromWrongType() {
        let settings = PluginSettings(values: [
            "backgroundScans": .bool(false),
            "limit": .number(25),
            "label": .string("x"),
            "oops": .string("true"),
        ])
        expect(settings.bool(forKey: "backgroundScans") == false, "a boolean reads back as a boolean")
        expect(settings.number(forKey: "limit") == 25, "a number reads back as a double")
        expect(settings.string(forKey: "label") == "x", "a string reads back as a string")
        expect(settings.bool(forKey: "missing") == nil && settings["missing"] == nil, "an absent key is nil both ways")
        expect(settings.bool(forKey: "oops") == nil && settings["oops"] == .string("true"), "a wrong-typed key is nil as a bool but present raw, so a plugin can report it")
        expect(PluginSettings.empty.values.isEmpty, "empty has no keys")
    }

    private static func testHostServicesForwardsToTheRunner() {
        let recorder = Recorder()
        let host = makeHost { path, arguments, environment, timeout in
            recorder.record((path, arguments, environment, timeout))
            return CommandOutput(output: "ran", error: "", status: 0, didTimeout: false)
        }
        let output = host.run(path: "/bin/echo", arguments: ["hi"], environment: ["PATH": "/x"], timeout: 3)
        let seen = recorder.seen
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
        expect(detail.contains("line 3"), "the error names the line the mistake is on, got: \(detail)")
        let occurrences = detail.components(separatedBy: "line 3").count - 1
        expect(occurrences == 1, "the line number is not said twice, even though Foundation's own text may also name it, got: \(detail)")
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

    private static func testParserTreatsNullLocationAsAbsent() {
        let config = try? parse(#"{ "plugins": [ { "name": null, "path": "/x/A.bundle" } ] }"#).get()
        expect(config?.plugins == [PluginEntry(name: nil, path: "/x/A.bundle", isEnabled: true)],
               "JSON null means the same as leaving the key out, so this is a path entry, not \"both\", got \(String(describing: config))")
    }

    private static func testParserRejectsNullEnabled() {
        let error = failure(parse(#"{ "plugins": [ { "name": "A.bundle", "enabled": null } ] }"#))
        expect(error == .wrongType(key: "enabled", expected: "true or false", where: "plugins[0]"),
               "null for enabled is neither true nor false; someone who wrote it probably meant off, so it must not silently mean on, got \(String(describing: error))")
    }

    private static func testParserKeepsTheFirstOfTwoDuplicateKeys() {
        let config = try? parse(#"{ "plugins": [ { "name": "A.bundle", "name": "B.bundle" } ] }"#).get()
        expect(config?.plugins.count == 1 && config?.plugins.first?.name == "A.bundle",
               "JSONSerialization keeps the first duplicate key, and the docs promise that; got \(String(describing: config))")
    }

    private static func testParserAcceptsATrailingComma() {
        let config = try? parse(#"{ "plugins": [ { "name": "A.bundle" }, ] }"#).get()
        expect(config?.plugins.count == 1, "JSONSerialization accepts a trailing comma, and the docs say so")
    }

    // MARK: - Config store

    private static let sampleDefault = PluginConfig.defaults(named: ["CPU.bundle", "Memory.bundle"])

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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("nested/plugins.json"))
        let result = store.loadOrCreate(default: sampleDefault)
        expect((try? result.get()) == sampleDefault, "a missing file yields the default, got \(result)")
        expect(FileManager.default.fileExists(atPath: store.fileURL.path), "and the default is written, creating its directory")
        let written = try? Data(contentsOf: store.fileURL)
        expect((try? store.loadOrCreate(default: .defaults(named: ["ignored.bundle"])).get()) == sampleDefault,
               "what was written reads back as the same config, and the default passed here is never used")
        expect((try? Data(contentsOf: store.fileURL)) == written, "the file exists, so this call never writes to it")
    }

    private static func testStoreWritesAFileThatEndsWithANewline() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        expect((try? store.write(sampleDefault)) != nil, "setup: the sample file could be written")
        let text = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        expect(text.hasSuffix("\n"), "a hand-edited file ends with a newline so editors and diffs behave")
        expect(!text.hasSuffix("\n\n"), "but only one")
    }

    private static func testStoreReadsAnExistingFileInsteadOfTheDefault() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        let existing = PluginConfig.defaults(named: ["Disk.bundle"])
        expect((try? store.write(existing)) != nil, "setup: the sample file could be written")
        let result = store.loadOrCreate(default: sampleDefault)
        expect((try? result.get()) == existing, "an existing file wins over the default, got \(result)")
    }

    private static func testStoreReportsAnUnreadableFile() {
        // A real file with permissions that forbid reading it: the general `.unreadable` branch,
        // as distinct from the folder case covered by testStoreSaysWhenAFolderSitsWhereTheFileShouldBe.
        guard getuid() != 0 else {
            expect(true, "running as root ignores permissions, so this file would read fine; skipping")
            return
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        try? Data("{}".utf8).write(to: store.fileURL)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path) }
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.fileURL.path)
        guard case .failure(.unreadable(let reason)) = store.loadOrCreate(default: sampleDefault) else {
            expect(false, "a file that exists but cannot be read is reported as unreadable, not silently replaced")
            return
        }
        expect(!reason.contains("folder"), "this is the general unreadable branch, not the folder case, got: \(reason)")
    }

    private static func testStoreReportsAnUnwritableLocation() {
        let store = PluginConfigStore(fileURL: URL(fileURLWithPath: "/systembar-cannot-create-this/plugins.json"))
        guard case .failure(.unwritable) = store.loadOrCreate(default: sampleDefault) else {
            expect(false, "a location the default cannot be written to is reported, not swallowed")
            return
        }
    }

    private static func testStoreExpandsTildeInTheOverride() {
        let store = PluginConfigStore.standard(
            environment: [PluginConfigStore.environmentOverride: "~/somewhere/plugins.json"],
            applicationSupport: URL(fileURLWithPath: "/ignored")
        )
        expect(store.fileURL.path == NSHomeDirectory() + "/somewhere/plugins.json",
               "a ~ in SYSTEMBAR_PLUGINS_FILE means the home directory, even with no shell to expand it, got \(store.fileURL.path)")
    }

    private static func testStoreSaysWhenAFolderSitsWhereTheFileShouldBe() {
        let store = PluginConfigStore(fileURL: temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        guard case .failure(let error) = store.loadOrCreate(default: sampleDefault) else {
            expect(false, "a folder at the path is an error")
            return
        }
        expect(error.description.contains("is a folder"), "the message says what is actually there, got: \(error.description)")
    }

    // MARK: - Shared plugins folder

    private static func testPluginFolderUsesApplicationSupportByDefault() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
        let folder = PluginFolder.standard(environment: [:], applicationSupport: support)
        expect(folder.path == "/Users/someone/Library/Application Support/SystemBar/PlugIns",
               "other projects install bundles beside plugins.json, in PlugIns, got \(folder.path)")
    }

    private static func testPluginFolderHonoursTheEnvironmentOverride() {
        let folder = PluginFolder.standard(
            environment: [PluginFolder.environmentOverride: "/tmp/other/PlugIns"],
            applicationSupport: URL(fileURLWithPath: "/ignored")
        )
        expect(folder.path == "/tmp/other/PlugIns", "SYSTEMBAR_PLUGINS_DIR points the app at another folder, got \(folder.path)")
    }

    private static func testPluginFolderExpandsTildeInTheOverride() {
        let folder = PluginFolder.standard(
            environment: [PluginFolder.environmentOverride: "~/somewhere/PlugIns"],
            applicationSupport: URL(fileURLWithPath: "/ignored")
        )
        expect(folder.path == NSHomeDirectory() + "/somewhere/PlugIns",
               "a ~ in SYSTEMBAR_PLUGINS_DIR means the home directory, even with no shell to expand it, got \(folder.path)")
    }

    private static func testPluginFolderIgnoresAnEmptyOverride() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
        let folder = PluginFolder.standard(environment: [PluginFolder.environmentOverride: ""], applicationSupport: support)
        expect(folder.path == "/Users/someone/Library/Application Support/SystemBar/PlugIns",
               "an empty SYSTEMBAR_PLUGINS_DIR is the same as none, as it is for SYSTEMBAR_PLUGINS_FILE, got \(folder.path)")
    }
}

/// Captures what a `@Sendable` runner closure saw. A closure of that shape cannot mutate a
/// local `var` directly, so the value is stored here, under a lock, instead.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (path: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval)?

    func record(_ value: (path: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval)) {
        lock.withLock { stored = value }
    }

    var seen: (path: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval)? {
        lock.withLock { stored }
    }
}
