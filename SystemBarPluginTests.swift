import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// Tests for the plugin model: the contract a tab conforms to and the runner the host gives it.
/// Later tasks add the config file and the catalog here.
@MainActor
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
        testLoaderWritesTheDefaultAndLoadsSixTabsOnFirstRun()
        testLoaderTurnsAnUnparseableFileIntoOneErrorTab()
        testLoaderReportsNothingForAnEmptyList()
        testCatalogKeepsOrderAndSkipsDisabledEntries()
        testCatalogShowsAFailedEntryInItsPlace()
        testCatalogRefusesADuplicateIdentifier()
        testCatalogCarriesOnAfterAFailure()
        testCatalogRefusesADuplicateBeforeConstructingIt()
        testListReportPrintsOneLinePerEntry()
        testEveryDefaultNameIsABuiltin()
        testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode()
        testBuiltinSourceNamesTheUnknownTab()
        testBuiltinSourceDoesNotTakePaths()
        testPluginPathResolvesNamesInsideThePlugInsFolder()
        testPluginPathRejectsNamesThatLeaveTheFolder()
        testPluginPathKeepsAStrangeNameInsideTheFolder()
        testPluginPathResolvesAbsoluteAndTildePaths()
        testPluginPathRejectsRelativeAndEmptyPaths()
        testBundleSourceReportsEachFailureStep()
        testBundleSourceFindsAPrincipalClassThatAdoptsTabPlugin()
        testHostSourcePrefersABundleOverTheCompiledInTab()
        testFoundationLoaderRefusesABareFolder()
        testFoundationLoaderRefusesAPlainFile()
        testFoundationLoaderRefusesABundleWithNoPrincipalClass()
        testRelauncherBuildsLaunchctlArguments()
        testRelauncherReadsThePidFromLaunchctlPrint()
        testFeedHoldsTheLatestValueAndPublishesTheNext()
        testHostServicesCarriesTheFeedsItWasBuiltWith()
        testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps()
        testSchedulerCollectsAtOnceWhenATabAppears()
        testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt()
    }

    static func makeHost(
        runner: @escaping CommandRunner = { _, _, _, _ in
            CommandOutput(output: "", error: "", status: 0, didTimeout: false)
        }
    ) -> HostServices {
        HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: runner,
            log: { _ in }
        )
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
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("nested/plugins.json"))
        let result = store.loadOrCreate(default: sampleDefault)
        expect((try? result.get()) == sampleDefault, "a missing file yields the default, got \(result)")
        expect(FileManager.default.fileExists(atPath: store.fileURL.path), "and the default is written, creating its directory")
        let written = try? Data(contentsOf: store.fileURL)
        expect((try? store.loadOrCreate(default: .builtins(named: ["ignored.bundle"])).get()) == sampleDefault,
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
        let existing = PluginConfig.builtins(named: ["Disk.bundle"])
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

    // MARK: - Loader

    private static func testLoaderWritesTheDefaultAndLoadsSixTabsOnFirstRun() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        let loaded = TabLoader.load(store: store, source: BuiltinTabSource(), host: makeHost())
        expect(loaded.map(\.title) == ["Power", "Dev", "Memory", "Disk", "Network", "CPU"],
               "a fresh file loads every built-in in its default order, got \(loaded.map(\.title))")
        expect(FileManager.default.fileExists(atPath: store.fileURL.path), "and the default file is written")
    }

    private static func testLoaderTurnsAnUnparseableFileIntoOneErrorTab() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        try? Data(#"{ "plugins": [ { "name": } ] }"#.utf8).write(to: store.fileURL)
        let loaded = TabLoader.load(store: store, source: BuiltinTabSource(), host: makeHost())
        guard loaded.count == 1, case .failed(let location, let reason) = loaded[0] else {
            expect(false, "an unparseable file yields exactly one error tab, got \(loaded)")
            return
        }
        expect(location == store.fileURL.path, "the error tab names the file's own path, got \(location)")
        expect(reason.contains("line"), "the reason names the line the mistake is on, got: \(reason)")
    }

    private static func testLoaderReportsNothingForAnEmptyList() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        try? Data(#"{ "plugins": [ { "name": "CPU.bundle", "enabled": false } ] }"#.utf8).write(to: store.fileURL)
        let loaded = TabLoader.load(store: store, source: BuiltinTabSource(), host: makeHost())
        expect(loaded.isEmpty, "a disabled-only config loads nothing, got \(loaded)")
        expect(PluginListReport.lines(for: loaded).isEmpty, "and --list-plugins prints nothing for it")
    }

    // MARK: - Catalog

    private static let fakeSource = MapTabSource(types: ["fake-first": FakeTab.self, "fake-copy": FakeTab.self, "other": OtherFakeTab.self])

    private static func entry(_ name: String, enabled: Bool = true) -> PluginEntry {
        PluginEntry(name: name, path: nil, isEnabled: enabled)
    }

    private static func testCatalogKeepsOrderAndSkipsDisabledEntries() {
        let config = PluginConfig(plugins: [entry("other"), entry("fake-first", enabled: false), entry("fake-first")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(tabs.count == 2, "a disabled entry produces no tab at all, got \(tabs.count)")
        expect(tabs.map(\.title) == ["Other", "Fake"], "tabs come out in file order, got \(tabs.map(\.title))")
    }

    private static func testCatalogShowsAFailedEntryInItsPlace() {
        let config = PluginConfig(plugins: [entry("fake-first"), entry("nope")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        guard tabs.count == 2, case let .failed(location, reason) = tabs[1] else {
            expect(false, "an entry the source cannot load is a failed tab at its own position, got \(tabs)")
            return
        }
        expect(location == "nope" && reason == "no tab for nope", "the failure names the entry and repeats the source's reason")
        expect(tabs[1].title == "Error" && tabs[1].plugin == nil, "a failed tab is titled Error and has no plugin")
    }

    private static func testCatalogRefusesADuplicateIdentifier() {
        let config = PluginConfig(plugins: [entry("fake-first"), entry("fake-copy")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        guard tabs.count == 2, case .loaded = tabs[0], case let .failed(location, reason) = tabs[1] else {
            expect(false, "the first of two plugins with one id loads and the second fails, got \(tabs)")
            return
        }
        expect(location == "fake-copy", "the failure sits at the second entry's own location, got \(location)")
        expect(reason.contains("\"fake\"") && reason.contains("\"fake-first\"") && reason.contains("earlier in the list"),
               "the duplicate failure names the clashing id and the earlier entry, got: \(reason)")
    }

    private static func testCatalogCarriesOnAfterAFailure() {
        let config = PluginConfig(plugins: [entry("nope"), entry("other")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(tabs.map(\.title) == ["Error", "Other"], "a failure earlier in the list does not stop later entries, got \(tabs.map(\.title))")
    }

    private static func testCatalogRefusesADuplicateBeforeConstructingIt() {
        CountingTab.constructed = 0
        let source = MapTabSource(types: ["a": CountingTab.self, "b": CountingTab.self])
        let config = PluginConfig(plugins: [entry("a"), entry("b")])
        let tabs = TabCatalog.build(config: config, source: source, host: makeHost())
        expect(tabs.compactMap(\.plugin).count == 1, "one of the two loads")
        expect(CountingTab.constructed == 1, "the duplicate is refused before its init runs, got \(CountingTab.constructed) constructions")
    }

    private static func testListReportPrintsOneLinePerEntry() {
        let config = PluginConfig(plugins: [entry("fake-first"), entry("nope")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(PluginListReport.lines(for: tabs) == ["ok fake Fake fake-first", "error nope: no tab for nope"],
               "--list-plugins prints ok/error lines in order, got \(PluginListReport.lines(for: tabs))")
    }

    // MARK: - Built-in tabs

    private static func testEveryDefaultNameIsABuiltin() {
        let names = BuiltinTabSource.defaultNames
        expect(names.count == BuiltinTabSource.types.count, "the default file lists every built-in exactly once")
        expect(names.allSatisfy { BuiltinTabSource.types[$0] != nil }, "every default name resolves to a built-in type")
        expect(names.allSatisfy { $0.hasSuffix(".bundle") }, "names are the bundle names each tab will have once it is a real bundle")
        expect(Set(names) == Set(BuiltinTabSource.types.keys), "the default names and the known names are the same set")
    }

    private static func testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode() {
        let config = PluginConfig.builtins(named: BuiltinTabSource.defaultNames)
        let tabs = TabCatalog.build(config: config, source: BuiltinTabSource(), host: makeHost())
        let plugins = tabs.compactMap(\.plugin)
        expect(plugins.count == 6, "all six built-ins load, got \(PluginListReport.lines(for: tabs))")
        let ids = Set(plugins.map { type(of: $0).identifier })
        expect(ids.count == 6, "the six built-ins have six different ids, got \(ids)")
        for plugin in plugins {
            guard let backed = plugin as? MonitorBackedTab else {
                expect(false, "\(plugin.title) must say which MonitorMode drives its sampling until it owns a collector")
                continue
            }
            expect(backed.monitorMode.icon == plugin.systemImage, "\(plugin.title) keeps the icon its MonitorMode had")
            expect(backed.monitorMode.rawValue == plugin.title, "\(plugin.title) keeps the title its MonitorMode had")
        }
        expect(plugins.compactMap { ($0 as? MonitorBackedTab)?.monitorMode } == MonitorMode.allCases,
               "the default order is today's tab order, got \(plugins.map(\.title))")
    }

    private static func testBuiltinSourceNamesTheUnknownTab() {
        do {
            _ = try BuiltinTabSource().resolve(entry("Weather.bundle"))
            expect(false, "an unknown name throws")
        } catch {
            expect("\(error)".contains("Weather.bundle") && "\(error)".contains("CPU.bundle"),
                   "the error names the bad name and lists the real ones, got: \(error)")
        }
    }

    private static func testBuiltinSourceDoesNotTakePaths() {
        let pathEntry = PluginEntry(name: nil, path: "/tmp/X.bundle", isEnabled: true)
        do {
            _ = try BuiltinTabSource().resolve(pathEntry)
            expect(false, "a path entry cannot load until bundles exist")
        } catch {
            expect("\(error)".contains("path"), "the error says path entries are not supported yet, got: \(error)")
        }
    }

    // MARK: - Bundles

    private static let plugIns = URL(fileURLWithPath: "/App/Contents/PlugIns")

    private static func pathEntry(_ path: String) -> PluginEntry {
        PluginEntry(name: nil, path: path, isEnabled: true)
    }

    private static func testPluginPathResolvesNamesInsideThePlugInsFolder() {
        let url = try? PluginPath.resolve(entry("Power.bundle"), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
        expect(url?.path == "/App/Contents/PlugIns/Power.bundle", "a name is a bundle inside the app's PlugIns folder, got \(String(describing: url?.path))")
        do {
            _ = try PluginPath.resolve(entry("Power.bundle"), builtInPlugInsURL: nil, homeDirectory: "/Users/x")
            expect(false, "a build with no PlugIns folder cannot resolve a name")
        } catch {
            expect("\(error)".contains("PlugIns"), "the error says the folder is missing, got: \(error)")
        }
    }

    private static func testPluginPathRejectsNamesThatLeaveTheFolder() {
        for bad in ["", ".", "..", "../Other.bundle", "a/b.bundle", "/etc/passwd"] {
            do {
                _ = try PluginPath.resolve(entry(bad), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
                expect(false, "the name \"\(bad)\" must be refused")
            } catch {
                expect("\(error)".contains("\"\(bad)\""), "the error quotes the bad name, got: \(error)")
            }
        }
    }

    private static func testPluginPathKeepsAStrangeNameInsideTheFolder() {
        // appendingPathComponent does not collapse ".." on its own, but a NUL byte is not a
        // legal path character, so it is percent-encoded rather than letting the name walk out
        // of the folder: the resolved URL's parent is still PlugIns.
        let url = try? PluginPath.resolve(entry("..\u{0}x"), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
        expect(url?.standardizedFileURL.deletingLastPathComponent().path == plugIns.path,
               "a name with a NUL byte stays inside the PlugIns folder, got \(String(describing: url?.path))")
    }

    private static func testPluginPathResolvesAbsoluteAndTildePaths() {
        let absolute = try? PluginPath.resolve(pathEntry("/opt/tabs/X.bundle"), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
        expect(absolute?.path == "/opt/tabs/X.bundle", "an absolute path is used as is")
        let tilde = try? PluginPath.resolve(pathEntry("~/Library/X.bundle"), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
        expect(tilde?.path == "/Users/x/Library/X.bundle", "a ~ path starts at the home directory, got \(String(describing: tilde?.path))")
    }

    private static func testPluginPathRejectsRelativeAndEmptyPaths() {
        for bad in ["", "tabs/X.bundle", "~tabs/X.bundle"] {
            do {
                _ = try PluginPath.resolve(pathEntry(bad), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
                expect(false, "the path \"\(bad)\" must be refused")
            } catch {
                expect("\(error)".contains("absolute") , "the error says a path must be absolute or start with ~/, got: \(error)")
            }
        }
    }

    private static func testBundleSourceReportsEachFailureStep() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Empty.bundle", "Broken.bundle", "Plain.bundle"] {
            expect((try? FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)) != nil, "setup: create \(name)")
        }
        let loader = FakeBundleLoader(
            classes: ["Plain.bundle": NotATab.self],
            failures: ["Broken.bundle": "dyld says no"]
        )
        let source = BundleTabSource(builtInPlugInsURL: folder, homeDirectory: "/Users/x", loader: loader)
        let cases: [(String, String)] = [
            ("Missing.bundle", "nothing at"),
            ("Broken.bundle", "dyld says no"),
            ("Empty.bundle", "no principal class"),
            ("Plain.bundle", "does not adopt TabPlugin"),
        ]
        for (name, expected) in cases {
            do {
                _ = try source.resolve(entry(name))
                expect(false, "\(name) must fail to resolve")
            } catch {
                expect("\(error)".contains(expected), "\(name): expected the reason to mention \"\(expected)\", got: \(error)")
            }
        }
    }

    private static func testBundleSourceFindsAPrincipalClassThatAdoptsTabPlugin() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        expect((try? FileManager.default.createDirectory(at: folder.appendingPathComponent("ObjC.bundle"), withIntermediateDirectories: true)) != nil, "setup: create ObjC.bundle")
        let source = BundleTabSource(builtInPlugInsURL: folder, homeDirectory: "/Users/x", loader: FakeBundleLoader(classes: ["ObjC.bundle": FakeObjCTab.self]))
        let type = try? source.resolve(entry("ObjC.bundle"))
        expect(type?.identifier == "objc", "an NSObject subclass with an @objc name resolves through the protocol, got \(String(describing: type))")
    }

    private static func testHostSourcePrefersABundleOverTheCompiledInTab() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        expect((try? FileManager.default.createDirectory(at: folder.appendingPathComponent("CPU.bundle"), withIntermediateDirectories: true)) != nil, "setup: create CPU.bundle")
        let bundles = BundleTabSource(builtInPlugInsURL: folder, homeDirectory: "/Users/x", loader: FakeBundleLoader(classes: ["CPU.bundle": FakeObjCTab.self]))
        let source = HostTabSource(bundles: bundles, builtins: BuiltinTabSource())
        expect((try? source.resolve(entry("CPU.bundle")))?.identifier == "objc", "a bundle in PlugIns wins over the compiled-in tab of the same name")
        expect((try? source.resolve(entry("Memory.bundle")))?.identifier == "memory", "a name with no bundle still finds the compiled-in tab")
        do {
            _ = try source.resolve(entry("Weather.bundle"))
            expect(false, "an unknown name fails")
        } catch {
            expect("\(error)".contains("Weather.bundle"), "the error names the entry, got: \(error)")
        }
        do {
            _ = try source.resolve(pathEntry("/nowhere/X.bundle"))
            expect(false, "a path entry never falls back to the compiled-in table")
        } catch {
            expect("\(error)".contains("nothing at"), "the path went to the bundle source, got: \(error)")
        }
    }

    private static func testFoundationLoaderRefusesABareFolder() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundleURL = folder.appendingPathComponent("X.bundle")
        expect((try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)) != nil, "setup: create X.bundle")
        do {
            _ = try FoundationBundleLoader().principalClass(at: bundleURL)
            expect(false, "a bundle folder with no executable must fail to load")
        } catch {
            expect("\(error)".contains("X.bundle"), "the error names the bundle, got: \(error)")
        }
    }

    private static func testFoundationLoaderRefusesAPlainFile() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appendingPathComponent("Y.bundle")
        expect(FileManager.default.createFile(atPath: fileURL.path, contents: Data()), "setup: create Y.bundle as a plain file")
        do {
            // Bundle(url:) returns nil for a plain file rather than a bundle it fails to load,
            // so this is refused at the same step a non-bundle path would be.
            _ = try FoundationBundleLoader().principalClass(at: fileURL)
            expect(false, "a plain file named Y.bundle must fail to load")
        } catch {
            expect("\(error)".contains("is not a bundle"), "expected the reason to say it is not a bundle, got: \(error)")
        }
    }

    private static func testFoundationLoaderRefusesABundleWithNoPrincipalClass() {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundleURL = folder.appendingPathComponent("Z.bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        expect((try? FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)) != nil, "setup: create Z.bundle/Contents")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>Z</string>
        </dict>
        </plist>
        """
        expect((try? Data(plist.utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))) != nil, "setup: write Z.bundle's Info.plist")
        do {
            // No NSPrincipalClass, and no binary either: this must be refused before Foundation
            // ever tries to load it.
            _ = try FoundationBundleLoader().principalClass(at: bundleURL)
            expect(false, "a bundle with no NSPrincipalClass must be refused")
        } catch {
            expect("\(error)".contains("NSPrincipalClass"), "the error names the missing key, got: \(error)")
        }
    }

    // MARK: - Relaunch

    private static func testRelauncherBuildsLaunchctlArguments() {
        expect(Relauncher.launchctlProbeArguments(uid: 501, label: "com.example.bar") == ["print", "gui/501/com.example.bar"],
               "the probe asks launchd about this user's agent by label")
        expect(Relauncher.launchctlKickstartArguments(uid: 501, label: "com.example.bar") == ["kickstart", "-k", "gui/501/com.example.bar"],
               "the kickstart kills and restarts that same agent")
    }

    private static func testRelauncherReadsThePidFromLaunchctlPrint() {
        let output = """
        com.ih8celery.systembar = {
            active count = 1
            path = /Users/x/Library/LaunchAgents/com.ih8celery.systembar.plist
            state = running
            pid = 4242
            program = /Users/x/Applications/SystemBar.app/Contents/MacOS/SystemBar
        }
        """
        expect(Relauncher.pid(fromLaunchctlPrint: output) == 4242, "the running pid is read from the 'pid = N' line")
        expect(Relauncher.pid(fromLaunchctlPrint: "state = not running") == nil, "no pid line means no running instance")
        expect(Relauncher.pid(fromLaunchctlPrint: "\tpid = 4242\t") == 4242, "real launchctl output indents with tabs")
        expect(Relauncher.pid(fromLaunchctlPrint: "pid = abc") == nil, "a pid that is not a number is no pid")
        expect(Relauncher.pid(fromLaunchctlPrint: "pid = 99999999999") == nil, "a pid too big for Int32 is no pid")
    }

    // MARK: - Feed

    private static func testFeedHoldsTheLatestValueAndPublishesTheNext() {
        let feed = Feed(initial: 1)
        var received: [(value: Int, wasOnMain: Bool)] = []
        let subscription = feed.publisher.sink { value in
            received.append((value, Thread.isMainThread))
        }
        // Both sends come from one async block, so their order is fixed; two separate blocks
        // could be scheduled onto the global queue in either order.
        DispatchQueue.global().async {
            feed.send(2)
            feed.send(3)
        }
        let deadline = Date().addingTimeInterval(2)
        while received.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(received.map(\.value) == [2, 3], "the publisher delivers every reading after subscription, in order, got \(received.map(\.value))")
        expect(received.allSatisfy(\.wasOnMain), "every delivery lands on the main thread")
        expect(feed.value == 3, "value is the latest reading, got \(feed.value)")
        subscription.cancel()
    }

    private static func testHostServicesCarriesTheFeedsItWasBuiltWith() {
        let feed = Feed(initial: ProcessSummary())
        let host = HostServices(
            homeDirectory: "/tmp",
            processes: feed,
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: ProcessRunner.run,
            log: { _ in }
        )
        expect(host.processes.value.totalCount == 0, "the feed a host is built with is the one plugins read")
        expect(host.fastStats.value.cpuUsagePercent == 0, "the 1-second feed is there too, starting empty")
        feed.send(ProcessSummary(rows: [ProcessSnapshot(name: "x", count: 1, physical: 1, virtualSize: 1, cpu: 1)], limit: 1))
        expect(host.processes.value.totalCount == 1, "a reading sent to the feed is visible through the host")
    }

    // MARK: - Scheduler

    private static func testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps() {
        let plugin = TickingTab(host: makeHost())
        let scheduler = PluginScheduler()
        scheduler.setVisible(plugin, true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let whileVisible = plugin.count
        expect(whileVisible >= 3, "a visible tab is collected every refreshInterval, got \(whileVisible) in 0.4s at 0.05s")
        expect(!plugin.overlapped, "collect never runs concurrently with itself")
        scheduler.setVisible(plugin, false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterHiding = plugin.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(plugin.count == afterHiding, "a hidden tab is not collected, got \(plugin.count - afterHiding) more collects")
    }

    private static func testSchedulerCollectsAtOnceWhenATabAppears() {
        let plugin = TickingTab(host: makeHost())
        let scheduler = PluginScheduler()
        scheduler.setVisible(plugin, true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        expect(plugin.count >= 1, "showing a tab collects immediately, not after the first interval")
        scheduler.setVisible(plugin, false)
    }

    private static func testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt() {
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: nil, feeds: [.processes]) == [.processes], "a bundle tab that wants the process feed runs only that sampler")
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: nil, feeds: []).isEmpty, "a bundle tab that wants nothing runs nothing")
        expect(MonitorSamplingPlan.jobs(isVisible: false, mode: nil, feeds: [.processes]).isEmpty, "hidden means nothing runs, whatever is declared")
        expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .disk, feeds: [.processes]) == [.disk, .processes], "a compiled-in tab's plan and its declared feeds add up")
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
    @MainActor func makeView() -> AnyView { AnyView(Text("fake")) }
}

/// A second plugin with its own id, for duplicate-id and ordering tests.
final class OtherFakeTab: TabPlugin {
    static let identifier = "other"
    let title = "Other"
    let systemImage = "circle"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) {}
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("other")) }
}

/// A source that knows a fixed set of names, standing in for built-ins and bundles.
struct MapTabSource: TabSource {
    let types: [String: TabPlugin.Type]

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        guard let name = entry.name, let type = types[name] else {
            throw TabLoadError(description: "no tab for \(entry.location)")
        }
        return type
    }
}

/// Counts constructions, to prove a duplicate is refused before its init runs.
final class CountingTab: TabPlugin {
    static let identifier = "counting"
    nonisolated(unsafe) static var constructed = 0
    let title = "Counting"
    let systemImage = "number"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) { Self.constructed += 1 }
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("counting")) }
}

/// An NSObject subclass with an @objc name, the shape a real bundle's principal class has.
@objc(FakeObjCTab)
final class FakeObjCTab: NSObject, TabPlugin {
    static let identifier = "objc"
    let title = "ObjC"
    let systemImage = "circle"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) { super.init() }
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("objc")) }
}

final class NotATab: NSObject {}

/// Stands in for Foundation's Bundle: what the principal class is, or why loading failed,
/// keyed by the bundle's file name.
struct FakeBundleLoader: BundleLoading {
    var classes: [String: AnyClass] = [:]
    var failures: [String: String] = [:]

    func principalClass(at url: URL) throws -> AnyClass {
        if let reason = failures[url.lastPathComponent] {
            throw TabLoadError(description: reason)
        }
        guard let cls = classes[url.lastPathComponent] else {
            throw TabLoadError(description: "no principal class")
        }
        return cls
    }
}

/// Counts collects and checks none overlap, with an interval short enough to observe.
final class TickingTab: TabPlugin {
    static let identifier = "ticking"
    let title = "Ticking"
    let systemImage = "metronome"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 0.05
    let sharedFeeds: Set<SharedFeed> = []
    private let lock = NSLock()
    private var inFlight = false
    private(set) var collects = 0
    private(set) var overlapped = false

    init(host: HostServices) {}

    func collect() {
        lock.withLock {
            if inFlight { overlapped = true }
            inFlight = true
            collects += 1
        }
        Thread.sleep(forTimeInterval: 0.02)
        lock.withLock { inFlight = false }
    }

    var count: Int { lock.withLock { collects } }
    @MainActor func makeView() -> AnyView { AnyView(Text("ticking")) }
}
