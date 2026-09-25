import Foundation
import SwiftUI
import SystemBarKit

/// Tests for turning plugins.json into tabs: the loader, the catalog and its list report, the
/// compiled-in tabs, plugin paths, bundle loading, and the relauncher.
@MainActor
struct SystemBarLoaderTests {
    static func runAll() {
        testLoaderWritesTheDefaultAndLoadsFiveTabsAndOneErrorOnFirstRun()
        testLoaderTurnsAnUnparseableFileIntoOneErrorTab()
        testLoaderReportsNothingForAnEmptyList()
        testCatalogKeepsOrderAndSkipsDisabledEntries()
        testCatalogShowsAFailedEntryInItsPlace()
        testCatalogRefusesADuplicateIdentifier()
        testCatalogCarriesOnAfterAFailure()
        testCatalogRefusesADuplicateBeforeConstructingIt()
        testCatalogLogsWhenInitPassesTheSlowThreshold()
        testCatalogLogsNothingForAFastInit()
        testListReportPrintsOneLinePerEntry()
        testEveryCompiledInTabIsInTheDefaultList()
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
        testSameBundleCheckFollowsSymlinks()
        testRelauncherBuildsLaunchctlArguments()
        testRelauncherReadsThePidFromLaunchctlPrint()
    }

    // MARK: - Loader

    private static func testLoaderWritesTheDefaultAndLoadsFiveTabsAndOneErrorOnFirstRun() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        let loaded = TabLoader.load(store: store, source: BuiltinTabSource(), host: makeHost())
        expect(loaded.map(\.title) == ["Error", "Dev", "Memory", "Disk", "Network", "CPU"],
               "a fresh file lists every default: the five compiled-in tabs load, and Power, now a bundle, cannot come from the built-in table so it is the one error tab, got \(loaded.map(\.title))")
        if case let .failed(_, reason)? = loaded.first {
            expect(reason.contains("Power.bundle"), "the failure names the entry, got \(reason)")
        }
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

    private static func testCatalogLogsWhenInitPassesTheSlowThreshold() {
        let log = LogRecorder()
        let host = makeHost(log: { log.record($0) })
        let source = MapTabSource(types: ["slow-init": SlowInitTab.self])
        let config = PluginConfig(plugins: [entry("slow-init")])
        let tabs = TabCatalog.build(config: config, source: source, host: host)
        expect(tabs.compactMap(\.plugin).count == 1, "a slow init(host:) still loads the plugin, got \(tabs)")
        expect(log.count == 1, "a slow init(host:) logs exactly one line, got \(log.count): \(log.messages)")
        let message = log.messages.first ?? ""
        expect(message.contains(SlowInitTab.identifier) && message.contains("init(host:)"),
               "the log line names the plugin id and init(host:), got: \(message)")
    }

    private static func testCatalogLogsNothingForAFastInit() {
        let log = LogRecorder()
        let host = makeHost(log: { log.record($0) })
        let config = PluginConfig(plugins: [entry("fake-first")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: host)
        expect(tabs.compactMap(\.plugin).count == 1, "the fast plugin loads, got \(tabs)")
        expect(log.count == 0, "a fast init(host:) logs nothing, got \(log.count): \(log.messages)")
    }

    private static func testListReportPrintsOneLinePerEntry() {
        let config = PluginConfig(plugins: [entry("fake-first"), entry("nope")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(PluginListReport.lines(for: tabs) == ["ok fake Fake fake-first", "error nope: no tab for nope"],
               "--list-plugins prints ok/error lines in order, got \(PluginListReport.lines(for: tabs))")
    }

    // MARK: - Built-in tabs

    private static func testEveryCompiledInTabIsInTheDefaultList() {
        expect(Set(BuiltinTabSource.types.keys).isSubset(of: DefaultPlugins.names), "every compiled-in tab is somewhere in the default list")
        expect(DefaultPlugins.names.count == 6 && Set(DefaultPlugins.names).count == 6, "six distinct default names")
        expect(DefaultPlugins.names.allSatisfy { $0.hasSuffix(".bundle") }, "names are the bundle names each tab will have once it is a real bundle")
    }

    private static func testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode() {
        let config = PluginConfig.builtins(named: DefaultPlugins.names)
        let tabs = TabCatalog.build(config: config, source: BuiltinTabSource(), host: makeHost())
        let plugins = tabs.compactMap(\.plugin)
        expect(plugins.count == 5, "all five compiled-in tabs load, got \(PluginListReport.lines(for: tabs))")
        let ids = Set(plugins.map { type(of: $0).identifier })
        expect(ids.count == 5, "the five built-ins have five different ids, got \(ids)")
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

    private static func testSameBundleCheckFollowsSymlinks() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("Real.bundle")
        expect((try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)) != nil, "setup: create Real.bundle")
        let link = root.appendingPathComponent("Link.bundle")
        expect((try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)) != nil, "setup: symlink Link.bundle to Real.bundle")
        let otherFolder = root.appendingPathComponent("Other.bundle")
        expect((try? FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)) != nil, "setup: create Other.bundle")

        expect(FoundationBundleLoader.isSameBundle(link, real),
               "a symlink to a bundle and the bundle itself are the same bundle")
        expect(!FoundationBundleLoader.isSameBundle(real, otherFolder),
               "two genuinely distinct folders are not the same bundle")
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

/// A plugin whose init(host:) sleeps past TabCatalog.slowInitThreshold, for the catalog's own
/// slow-init logging test.
final class SlowInitTab: TabPlugin {
    static let identifier = "slow-init"
    let title = "Slow Init"
    let systemImage = "tortoise"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []

    init(host: HostServices) { Thread.sleep(forTimeInterval: 0.15) }
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("slow-init")) }
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
