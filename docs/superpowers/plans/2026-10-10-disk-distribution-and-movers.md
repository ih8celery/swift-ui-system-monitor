# Disk Distribution and Movers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Disk tab's fixed "Reclaimable Space" list with a map of where the disk space is and a list of what changed, read from a size ledger that is saved between scans and refreshed in the background on awake-time cadences.

**Architecture:** Three additive SDK changes come first: a per-plugin `settings` object passed through plugins.json, a per-plugin `dataDirectory` under Application Support, and (owned by the CPU epic ewy, Stage 1) `TabPlugin.backgroundInterval`, which makes the host call `collect()` while a tab is hidden. The Disk plugin then gets a value-type `DiskLedger` of dated size samples, pure functions that derive ranked rows, remainders and movers from it, a JSON store with atomic writes, a `DiskScanner` that runs tiered scan plans one `du` per folder, and a rewritten panel. Spec: `docs/one-page/systembar-ifd-disk-distribution-and-movers.md`. The background contract is the CPU spec's: `docs/one-page/systembar-ewy-cpu-machine-state-and-background-sampling.md`, "SDK Contract".

**Tech Stack:** Swift 5 mode, `swiftc` via `./build.sh` and `./test.sh` (no SPM, no XCTest: tests are `expect(_:_:)` calls in `static func runAll()` per file, registered in `SystemBarPerformanceTests.main()`). SwiftUI panel. `du`, `tmutil`, `xcrun simctl` through `HostServices.run`.

**Conventions every task follows:**
- Tests call `expect(condition, "message")` from `TestSupport.swift` and exit on the first failure. Every test file is a `@MainActor enum XTests { static func runAll() }` whose `runAll()` is listed in `SystemBarPerformanceTests.main()`.
- `./test.sh` builds everything and runs every test. It takes about a minute. Never pipe it into `head`; use `./test.sh 2>&1 | tail -20` or redirect to a file.
- Tests never touch `~/Library/Application Support`. Use `temporaryDirectory()` from `TestFakes.swift` and remove it in a `defer`.
- Public SDK symbols are only ever added, never changed or removed. A new `TabPlugin` requirement gets a default in the protocol extension.
- Commit after each task with the message given. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Before the first commit, run `bd update <id> --claim` on the task's bead; after it, `bd close <id>`.

---

### Task 0: Beads children

**Files:** none

- [ ] **Step 1: Create one child issue per task below under the epic**

```bash
cd /Users/adamu/proj/swift-ui-system-monitor
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="SDK: PluginSettings value type" --description="Sendable wrapper over a plugin's settings JSON with typed accessors. Spec ifd D6.1."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Host: plugins.json entries carry a settings object" --description="Parser accepts an optional settings object per entry, rejects a non-object, round-trips it; PluginEntry.settings. Spec ifd D6.1."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="SDK+Host: HostServices.settings and dataDirectory, one HostServices per plugin" --description="New HostServices initializer, package forPlugin(), PluginDataRoot with SYSTEMBAR_PLUGIN_DATA_ROOT, TabCatalog builds a per-plugin host. Spec ifd D6.1-2."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: drop purgeable, free is the headline" --description="DiskVolume loses purgeable; used = total - free; bar is Used/Free. Spec ifd D5."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: DiskLedger value type and retention" --description="Samples, latest per path, sample at-or-before, due rule, 2-day full then daily to 30 days. Spec ifd D4."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: rows, remainders, simulator group, movers, distribution" --description="Pure functions from ledger to panel rows. Spec ifd D5."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: DiskLedgerStore JSON file" --description="Atomic write, versioned, .broken move-aside. Spec ifd D4."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: scan plans, targets, simctl catalog" --description="Three plans with roots and cadences, children listing, biggest-known-first order, vanished paths. Spec ifd D3."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: DiskScanner measure loop and outcome" --description="One du per target within the plan budget, outcome counts and status text. Spec ifd D3."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: plugin wiring" --description="Settings, ledger load, scan queue, due plans on collect, backgroundInterval, snapshot. Spec ifd D2, D6."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Disk: panel rewrite" --description="Left distribution, right Biggest/Movers, footer ages and rescan. Spec ifd D5."
bd create --parent=swift-ui-system-monitor-ifd --type=task --priority=1 --title="Docs: README, CLAUDE.md, plugin spec, interval test" --description="Spec ifd D7."
bd list --status=open | grep 'ifd\.'
```

Record the ids: the tasks below refer to them as `ifd.1` to `ifd.12` in order.

- [ ] **Step 2: Record the cross-epic dependency once the CPU pane has created its Stage 1 issue**

```bash
bd dep add swift-ui-system-monitor-ifd.10 <ewy stage 1 id>   # plugin wiring needs backgroundInterval
```

---

### Task 1: SDK `PluginSettings` value type (ifd.1)

**Files:**
- Create: `Sources/Kit/PluginSettings.swift`
- Test: `SystemBarConfigTests.swift` (add tests and register them in `runAll()`)

- [ ] **Step 1: Write the failing tests**

Add to `SystemBarConfigTests.runAll()` after `testHostServicesForwardsToTheRunner()`:

```swift
        testPluginSettingsReadsTypedValuesAndTellsAbsentFromWrongType()
```

Add under `// MARK: - Contract`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `cannot find 'PluginSettings' in scope`.

- [ ] **Step 3: Write the type**

Create `Sources/Kit/PluginSettings.swift`:

```swift
import Foundation

/// The `settings` object from a plugin's entry in plugins.json, as the host hands it to the
/// plugin in `HostServices.settings`. The host checks only that it is an object; the keys and
/// their types are the plugin's to define and to check, so a plugin reports a bad value in its
/// own status line rather than refusing to load. An entry with no `settings` gets `.empty`.
///
/// Tell an absent key from a wrong-typed one with the subscript: `bool(forKey:)` is nil for
/// both, while `settings[key]` is nil only when the key is absent.
public struct PluginSettings: Sendable, Equatable {
    /// One JSON value. Numbers are doubles, as JSON has no integers. The enum is not frozen:
    /// a plugin switching over it needs `@unknown default`.
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)
        case list([Value])
        case object([String: Value])
        case null
    }

    /// Every key in the object, as written.
    public let values: [String: Value]

    /// No settings at all: what a plugin gets when its entry has no `settings` key.
    public static let empty = PluginSettings(values: [:])

    public init(values: [String: Value]) {
        self.values = values
    }

    /// The raw value under `key`, or nil when the key is absent.
    public subscript(key: String) -> Value? {
        values[key]
    }

    /// The boolean under `key`; nil when the key is absent or holds anything but true or false.
    public func bool(forKey key: String) -> Bool? {
        if case .bool(let flag)? = values[key] { return flag }
        return nil
    }

    /// The number under `key`; nil when the key is absent or holds anything but a number.
    public func number(forKey key: String) -> Double? {
        if case .number(let number)? = values[key] { return number }
        return nil
    }

    /// The string under `key`; nil when the key is absent or holds anything but a string.
    public func string(forKey key: String) -> String? {
        if case .string(let text)? = values[key] { return text }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed` and the three shell checks pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Kit/PluginSettings.swift SystemBarConfigTests.swift
git commit -m "Add PluginSettings, the SDK's view of a plugin's settings object

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: plugins.json entries carry a `settings` object (ifd.2)

**Files:**
- Modify: `Sources/Host/PluginConfig.swift` (PluginEntry)
- Modify: `Sources/Host/PluginConfigParser.swift`
- Test: `SystemBarConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

Register in `runAll()` after `testParserAcceptsATrailingComma()`:

```swift
        testParserPassesASettingsObjectThrough()
        testParserDefaultsSettingsToEmpty()
        testParserRejectsNonObjectSettings()
        testEncodeWritesSettingsOnlyWhenPresentAndRoundTrips()
```

Add under the parser tests (the file already has `parse(_:)`, `failure(_:)` and `success(_:)` helpers; use them):

```swift
    private static func testParserPassesASettingsObjectThrough() {
        let config = success(parse(#"{ "plugins": [ { "name": "Disk.bundle", "settings": { "backgroundScans": false, "limit": 25, "label": "x", "tags": ["a", 1], "nested": { "k": null } } } ] }"#))
        let settings = config?.plugins.first?.settings
        expect(settings?.bool(forKey: "backgroundScans") == false, "a JSON false arrives as a boolean, not a number, got \(String(describing: settings))")
        expect(settings?.number(forKey: "limit") == 25, "a JSON number arrives as a double")
        expect(settings?.string(forKey: "label") == "x", "a JSON string arrives as a string")
        expect(settings?["tags"] == .list([.string("a"), .number(1)]), "lists keep their order and element types")
        expect(settings?["nested"] == .object(["k": .null]), "nested objects and nulls survive")
    }

    private static func testParserDefaultsSettingsToEmpty() {
        let config = success(parse(#"{ "plugins": [ { "name": "A.bundle" }, { "name": "B.bundle", "settings": null } ] }"#))
        expect(config?.plugins.map(\.settings) == [.empty, .empty], "no settings and a null settings both mean empty")
    }

    private static func testParserRejectsNonObjectSettings() {
        let error = failure(parse(#"{ "plugins": [ { "name": "A.bundle", "settings": true } ] }"#))
        expect(error == .wrongType(key: "settings", expected: "an object", where: "plugins[0]"),
               "settings must be an object, and the error names the entry, got \(String(describing: error))")
    }

    private static func testEncodeWritesSettingsOnlyWhenPresentAndRoundTrips() {
        let plain = PluginEntry(name: "A.bundle", path: nil, isEnabled: true)
        let withSettings = PluginEntry(name: "B.bundle", path: nil, isEnabled: false, settings: PluginSettings(values: ["backgroundScans": .bool(false), "n": .number(3), "s": .string("x")]))
        let data = try! PluginConfigParser.encode(PluginConfig(plugins: [plain, withSettings]))
        let text = String(decoding: data, as: UTF8.self)
        expect(!text.contains(#""settings" : {}"#) && text.contains(#""backgroundScans" : false"#), "settings are written only for the entry that has them, got \(text)")
        let back = success(PluginConfigParser.parse(data))
        expect(back?.plugins == [plain, withSettings], "what encode writes parses back equal, got \(String(describing: back))")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `extra argument 'settings' in call` or `value of type 'PluginEntry' has no member 'settings'`.

- [ ] **Step 3: Extend `PluginEntry`**

In `Sources/Host/PluginConfig.swift`, add `import SystemBarKit` after `import Foundation`, and replace the `PluginEntry` struct with:

```swift
/// One line of plugins.json. Exactly one of `name` (a bundle shipped inside the app) or `path`
/// (a bundle anywhere on disk) is set; the parser refuses anything else.
struct PluginEntry: Equatable {
    let name: String?
    let path: String?
    let isEnabled: Bool
    /// The entry's `settings` object, passed to the plugin untouched; `.empty` when there is none.
    let settings: PluginSettings

    init(name: String?, path: String?, isEnabled: Bool, settings: PluginSettings = .empty) {
        self.name = name
        self.path = path
        self.isEnabled = isEnabled
        self.settings = settings
    }

    /// What the config called this entry, for error messages and the --list-plugins report.
    var location: String { name ?? path ?? "" }
}
```

- [ ] **Step 4: Extend the parser**

In `Sources/Host/PluginConfigParser.swift`, add `import SystemBarKit` after `import Foundation`. Change `entryKeys` to:

```swift
    private static let entryKeys: Set<String> = ["name", "path", "enabled", "settings"]
```

Replace the last statement of `parseEntry` (`return parseEnabled(...).map { ... }`) with:

```swift
        return parseEnabled(object["enabled"], where: place).flatMap { isEnabled in
            parseSettings(object["settings"], where: place).map { settings in
                PluginEntry(name: name as? String, path: path as? String, isEnabled: isEnabled, settings: settings)
            }
        }
```

Add after `parseEnabled`:

```swift
    /// `settings` is the plugin's, so only its shape is checked here: an object, or absent.
    private static func parseSettings(_ raw: Any?, where place: String) -> Result<PluginSettings, PluginConfigError> {
        guard let raw = present(raw) else { return .success(.empty) }
        guard let object = raw as? [String: Any] else {
            return .failure(.wrongType(key: "settings", expected: "an object", where: place))
        }
        return .success(PluginSettings(values: object.mapValues(settingsValue)))
    }

    /// JSONSerialization's value as the SDK's. Booleans are checked before numbers because
    /// NSNumber is both.
    private static func settingsValue(_ raw: Any) -> PluginSettings.Value {
        if raw is NSNull { return .null }
        if isBoolean(raw), let flag = raw as? Bool { return .bool(flag) }
        if let number = raw as? NSNumber { return .number(number.doubleValue) }
        if let text = raw as? String { return .string(text) }
        if let list = raw as? [Any] { return .list(list.map(settingsValue)) }
        if let object = raw as? [String: Any] { return .object(object.mapValues(settingsValue)) }
        return .null
    }

    private static func jsonObject(_ value: PluginSettings.Value) -> Any {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let text): return text
        case .list(let list): return list.map(jsonObject)
        case .object(let object): return object.mapValues(jsonObject)
        case .null: return NSNull()
        }
    }
```

Replace `object(for:)` with:

```swift
    /// `enabled` is written only when false, since true is the default a reader assumes, and
    /// `settings` only when the entry has any.
    private static func object(for entry: PluginEntry) -> [String: Any] {
        var object: [String: Any] = [:]
        if let name = entry.name {
            object["name"] = name
        } else if let path = entry.path {
            object["path"] = path
        }
        if !entry.isEnabled {
            object["enabled"] = false
        }
        if !entry.settings.values.isEmpty {
            object["settings"] = entry.settings.values.mapValues(jsonObject)
        }
        return object
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Host/PluginConfig.swift Sources/Host/PluginConfigParser.swift SystemBarConfigTests.swift
git commit -m "Let a plugins.json entry carry a settings object for its plugin

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `HostServices.settings`, `HostServices.dataDirectory`, one host per plugin (ifd.3)

**Files:**
- Modify: `Sources/Kit/HostServices.swift`
- Create: `Sources/Host/PluginDataRoot.swift`
- Modify: `Sources/Host/TabCatalog.swift` (build, makeTab, timedInit)
- Modify: `Sources/Host/TabLoader.swift`
- Modify: `Sources/Host/App.swift`
- Modify: `TestFakes.swift` (makeHost gains `settings` and `dataDirectory`)
- Test: `SystemBarConfigTests.swift`, `SystemBarLoaderTests.swift`

- [ ] **Step 1: Write the failing tests**

In `SystemBarConfigTests.runAll()` add after `testPluginSettingsReadsTypedValuesAndTellsAbsentFromWrongType()`:

```swift
        testHostServicesCarriesSettingsAndADataDirectory()
        testHostServicesOldInitializerStillWorksWithEmptySettings()
        testPluginDataRootUsesApplicationSupportOrTheOverride()
```

Add under `// MARK: - Contract`:

```swift
    private static func testHostServicesCarriesSettingsAndADataDirectory() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = PluginSettings(values: ["backgroundScans": .bool(false)])
        let host = makeHost(settings: settings, dataDirectory: directory)
        expect(host.settings == settings, "the settings handed in are the settings read back")
        expect(host.dataDirectory == directory, "and so is the data directory")
        let child = host.forPlugin(identifier: "disk", settings: .empty, dataRoot: URL(fileURLWithPath: "/root"))
        expect(child.dataDirectory.path == "/root/disk", "a per-plugin host's folder is the root plus the identifier, got \(child.dataDirectory.path)")
        expect(child.settings == .empty && child.homeDirectory == host.homeDirectory, "and it keeps the home directory while taking its own settings")
        expect(!FileManager.default.fileExists(atPath: child.dataDirectory.path), "nothing is created until a plugin writes")
    }

    private static func testHostServicesOldInitializerStillWorksWithEmptySettings() {
        let host = HostServices(
            homeDirectory: "/Users/test",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { _ in }
        )
        expect(host.settings == .empty, "the five-argument initializer, which plugin tests already use, gives empty settings")
        expect(host.dataDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path), "and a throwaway data folder under the temporary directory, got \(host.dataDirectory.path)")
    }

    private static func testPluginDataRootUsesApplicationSupportOrTheOverride() {
        let standard = PluginDataRoot.standard(environment: [:], applicationSupport: URL(fileURLWithPath: "/as"))
        expect(standard.path == "/as/SystemBar/Plugins", "plugin data lives beside plugins.json, got \(standard.path)")
        let overridden = PluginDataRoot.standard(environment: [PluginDataRoot.environmentOverride: "~/elsewhere"], applicationSupport: URL(fileURLWithPath: "/as"))
        expect(overridden.path == NSHomeDirectory() + "/elsewhere", "SYSTEMBAR_PLUGIN_DATA_ROOT wins and expands a tilde, got \(overridden.path)")
        let empty = PluginDataRoot.standard(environment: [PluginDataRoot.environmentOverride: ""], applicationSupport: URL(fileURLWithPath: "/as"))
        expect(empty.path == "/as/SystemBar/Plugins", "an empty override is ignored")
    }
```

In `SystemBarLoaderTests.runAll()` add after `testCatalogLogsNothingForAFastInit()`:

```swift
        testCatalogGivesEachPluginItsOwnSettingsAndDataFolder()
```

Add under `// MARK: - Catalog` (the file has `MapTabSource(types:)`, which resolves by entry name):

```swift
    private static func testCatalogGivesEachPluginItsOwnSettingsAndDataFolder() {
        let settings = PluginSettings(values: ["backgroundScans": .bool(false)])
        let config = PluginConfig(plugins: [
            PluginEntry(name: "A.bundle", path: nil, isEnabled: true, settings: settings),
            PluginEntry(name: "B.bundle", path: nil, isEnabled: true),
        ])
        let source = MapTabSource(types: ["A.bundle": HostKeepingTab.self, "B.bundle": OtherHostKeepingTab.self])
        let tabs = TabCatalog.build(config: config, source: source, host: makeHost(), dataRoot: URL(fileURLWithPath: "/data"))
        let a = tabs[0].plugin as? HostKeepingTab
        let b = tabs[1].plugin as? OtherHostKeepingTab
        expect(a?.host.settings == settings, "the first plugin sees its entry's settings")
        expect(a?.host.dataDirectory.path == "/data/keeper", "and a folder named by its identifier, got \(String(describing: a?.host.dataDirectory.path))")
        expect(b?.host.settings == .empty, "the second plugin, whose entry has none, sees empty settings")
        expect(b?.host.dataDirectory.path == "/data/other-keeper", "and its own folder, got \(String(describing: b?.host.dataDirectory.path))")
    }
```

At the bottom of `SystemBarLoaderTests.swift`, next to `OtherFakeTab`, add:

```swift
/// A plugin that keeps the HostServices it was given, so a test can see what the catalog built for it.
final class HostKeepingTab: TabPlugin {
    static let identifier = "keeper"
    let title = "Keeper"
    let systemImage = "questionmark"
    let accent = Color.white
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []
    let host: HostServices

    init(host: HostServices) { self.host = host }
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("keeper")) }
}

final class OtherHostKeepingTab: TabPlugin {
    static let identifier = "other-keeper"
    let title = "Other Keeper"
    let systemImage = "questionmark"
    let accent = Color.white
    let refreshInterval: TimeInterval = 5
    let sharedFeeds: Set<SharedFeed> = []
    let host: HostServices

    init(host: HostServices) { self.host = host }
    func collect() {}
    @MainActor func makeView() -> AnyView { AnyView(Text("other keeper")) }
}
```

In `TestFakes.swift`, replace `makeHost` with:

```swift
/// A HostServices with empty feeds, a silent log, a runner that succeeds with no output unless
/// a test passes its own, empty settings, and a data folder under the temporary directory, so
/// no test ever writes into the real Application Support folder.
@MainActor
func makeHost(
    processes: Feed<ProcessSummary> = Feed(initial: ProcessSummary()),
    fastStats: Feed<FastStatsSnapshot> = Feed(initial: FastStatsSnapshot()),
    runner: @escaping CommandRunner = { _, _, _, _ in
        CommandOutput(output: "", error: "", status: 0, didTimeout: false)
    },
    log: @escaping @Sendable (String) -> Void = { _ in },
    settings: PluginSettings = .empty,
    dataDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-data")
) -> HostServices {
    HostServices(
        homeDirectory: "/tmp/systembar-tests",
        processes: processes,
        fastStats: fastStats,
        runner: runner,
        log: log,
        settings: settings,
        dataDirectory: dataDirectory
    )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile errors for `settings`, `dataDirectory`, `forPlugin`, `PluginDataRoot`, `dataRoot`.

- [ ] **Step 3: Extend `HostServices`**

In `Sources/Kit/HostServices.swift`, add two stored properties after `fastStats`:

```swift
    /// The `settings` object from this plugin's entry in plugins.json, or `.empty`. The keys
    /// are the plugin's own; see `PluginSettings`.
    public let settings: PluginSettings
    /// A folder for this plugin alone, `~/Library/Application Support/SystemBar/Plugins/<id>/`
    /// in the app. It may not exist yet: create it (with intermediate directories) before
    /// writing. A plugin that saves anything between launches saves it here and nowhere else,
    /// so a test can point the whole app at a temporary root with SYSTEMBAR_PLUGIN_DATA_ROOT.
    public let dataDirectory: URL
```

Replace the initializer with these two:

```swift
    /// Anyone may build one; the tests do. By convention only the app does, and the rule that
    /// subprocesses never go through a shell is upheld by the runner's shape: an explicit
    /// executable path and an argument array, nothing to interpolate.
    public init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void,
        settings: PluginSettings,
        dataDirectory: URL
    ) {
        self.homeDirectory = homeDirectory
        self.processes = processes
        self.fastStats = fastStats
        self.runner = runner
        self.logger = log
        self.settings = settings
        self.dataDirectory = dataDirectory
    }

    /// The original initializer, kept so plugin tests written against it still compile: empty
    /// settings, and a data folder under the temporary directory that nothing reads back.
    public convenience init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            homeDirectory: homeDirectory,
            processes: processes,
            fastStats: fastStats,
            runner: runner,
            log: log,
            settings: .empty,
            dataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SystemBar-plugin-data-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        )
    }

    /// The host's side: this host's feeds, runner and log, with one plugin's settings and its
    /// own folder under `dataRoot`. Package-only: the catalog builds one per loaded plugin.
    package func forPlugin(identifier: String, settings: PluginSettings, dataRoot: URL) -> HostServices {
        HostServices(
            homeDirectory: homeDirectory,
            processes: processes,
            fastStats: fastStats,
            runner: runner,
            log: logger,
            settings: settings,
            dataDirectory: dataRoot.appendingPathComponent(identifier, isDirectory: true)
        )
    }
```

Note `HostServices` is a `final class`; a `convenience init` on a final class is allowed and delegates with `self.init`.

- [ ] **Step 4: Add `PluginDataRoot`**

Create `Sources/Host/PluginDataRoot.swift`:

```swift
import Foundation

/// Where plugins keep their own files: one folder per plugin identifier under this root.
/// `SYSTEMBAR_PLUGIN_DATA_ROOT` moves the root, so tests and scripts never write into the real
/// Application Support folder.
enum PluginDataRoot {
    static let environmentOverride = "SYSTEMBAR_PLUGIN_DATA_ROOT"
    static let relativePath = "SystemBar/Plugins"

    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        if let override = environment[environmentOverride], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(relativePath, isDirectory: true)
    }
}
```

- [ ] **Step 5: Build a host per plugin in the catalog and loader**

In `Sources/Host/TabCatalog.swift`, change `build` to:

```swift
    /// Every enabled entry, in order, as a loaded tab or a failure. Nothing here stops on error.
    /// Each plugin is constructed with a host of its own: the shared feeds and runner, plus its
    /// entry's settings and a folder named by its identifier under `dataRoot`.
    @MainActor static func build(
        config: PluginConfig,
        source: TabSource,
        host: HostServices,
        dataRoot: URL = PluginDataRoot.standard()
    ) -> [LoadedTab] {
        var tabs: [LoadedTab] = []
        // Identifier to the location of the entry that first claimed it, so a later duplicate
        // can name which earlier entry it clashes with.
        var loadedIDs: [String: String] = [:]
        for entry in config.plugins where entry.isEnabled {
            let tab = makeTab(for: entry, source: source, host: host, dataRoot: dataRoot, alreadyLoaded: loadedIDs)
            tabs.append(tab)
            if let plugin = tab.plugin {
                loadedIDs[type(of: plugin).identifier] = entry.location
            }
        }
        return tabs
    }
```

Change `makeTab`'s signature and its last line:

```swift
    @MainActor private static func makeTab(
        for entry: PluginEntry,
        source: TabSource,
        host: HostServices,
        dataRoot: URL,
        alreadyLoaded: [String: String]
    ) -> LoadedTab {
        // ... unchanged body up to the duplicate check, then:
        let pluginHost = host.forPlugin(identifier: id, settings: entry.settings, dataRoot: dataRoot)
        return .loaded(location: entry.location, plugin: timedInit(of: type, host: pluginHost))
    }
```

In `Sources/Host/TabLoader.swift`:

```swift
    @MainActor static func load(store: PluginConfigStore, source: TabSource, host: HostServices, dataRoot: URL = PluginDataRoot.standard()) -> [LoadedTab] {
        switch store.loadOrCreate(default: .defaults(named: DefaultPlugins.names)) {
        case .success(let config):
            return TabCatalog.build(config: config, source: source, host: host, dataRoot: dataRoot)
        case .failure(let error):
            return [.failed(location: store.fileURL.path, reason: error.description)]
        }
    }
```

In `Sources/Host/App.swift`, the `HostServices(...)` call keeps its five arguments (the shared host has no settings and no folder of its own), and the loader call becomes:

```swift
        let loaded = TabLoader.load(store: store, source: source, host: host, dataRoot: PluginDataRoot.standard())
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`, boundary, fresh-file and name checks pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Kit/HostServices.swift Sources/Host/PluginDataRoot.swift Sources/Host/TabCatalog.swift Sources/Host/TabLoader.swift Sources/Host/App.swift TestFakes.swift SystemBarConfigTests.swift SystemBarLoaderTests.swift
git commit -m "Give each plugin its settings and a data folder through its own HostServices

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 8: Hand the ids and hash to the CPU pane**

Tell session `swift-ui-system-monitor-59` (SendMessage) the bead id of ifd.3 and, once Adam has merged to main, the commit hash. Record `bd dep add swift-ui-system-monitor-ewy.3 <ifd.3 id>`.

---

### Task 4: Disk drops purgeable; free is the headline (ifd.4)

**Files:**
- Modify: `Plugins/Disk/Sources/DiskModels.swift` (DiskVolume)
- Modify: `Plugins/Disk/Sources/DiskCollector.swift` (collectDiskVolumes)
- Modify: `Plugins/Disk/Sources/DiskPanel.swift` (headline, pills, bar, legend)
- Test: `Plugins/Disk/Tests/DiskTests.swift`

- [ ] **Step 1: Change the failing tests**

In `DiskTests.swift`, replace `testDiskVolumeMath` with:

```swift
    private static func testDiskVolumeMath() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 150, isRoot: true)
        expect(volume.used == 850, "used is capacity minus free: purgeable space is still on the disk, so it counts as used")
        expect(volume.freeRatio == 0.15, "the free ratio drives the headline colour")

        // A volume reporting more free than capacity must not underflow the unsigned used value.
        let overreported = DiskVolume(name: "Odd", path: "/odd", total: 100, free: 200, isRoot: false)
        expect(overreported.used == 0, "used clamps to zero rather than underflowing")
    }
```

In `testSnapshotAppliesAReadingAndEachHogUpdate`, change the first line to:

```swift
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 150, isRoot: true)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `extra argument 'purgeable'` / `missing argument`.

- [ ] **Step 3: Change the model**

In `DiskModels.swift`, replace `DiskVolume` with:

```swift
struct DiskVolume: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    /// Plain free space, what `df` calls available. Space macOS could purge is not counted:
    /// it is still on the disk, and the map on this tab is of what is on the disk.
    let free: UInt64
    let isRoot: Bool

    var used: UInt64 {
        total > free ? total - free : 0
    }

    var freeRatio: Double {
        Double(free) / Double(max(total, 1))
    }
}
```

- [ ] **Step 4: Change the collector**

In `DiskCollector.collectDiskVolumes`, remove `.volumeAvailableCapacityForImportantUsageKey` from `keys`, and replace the body of the `compactMap` closure from `let free = ...` to the `return DiskVolume(...)` with:

```swift
            let free = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))

            return DiskVolume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: free,
                isRoot: url.path == "/"
            )
```

- [ ] **Step 5: Change the panel**

In `DiskPanel.swift`: in the pills `HStack`, delete the `StatPill(label: "Purgeable", ...)` line. Replace `headlineText` and `headlineColor`:

```swift
    private var headlineText: String {
        guard let boot = plugin.snapshot.boot else { return "Reading volumes" }
        return "\(byteString(boot.free)) Free"
    }

    private var headlineColor: Color {
        guard let boot = plugin.snapshot.boot else { return .secondary }
        if boot.freeRatio > 0.20 { return Palette.good }
        if boot.freeRatio > 0.10 { return Palette.caution }
        return Palette.critical
    }
```

In the Other Volumes `EvidenceRow`, change `value: byteString(volume.importantAvailable)` to `value: "\(byteString(volume.free)) free"`. Replace `capacityRows(for:)`:

```swift
/// The two capacity buckets. CapacityLegend shows both even when one is zero, while CapacityBar
/// (which can't draw a zero-width segment meaningfully) filters those out itself.
private func capacityRows(for volume: DiskVolume) -> [BarSegment] {
    [
        BarSegment(label: "Used", value: volume.used, color: Palette.blue),
        BarSegment(label: "Free", value: volume.free, color: Palette.good)
    ]
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`.

- [ ] **Step 7: Commit**

```bash
git add Plugins/Disk
git commit -m "Disk: drop the purgeable bucket; free space is the headline and used is the rest

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `DiskLedger` value type and retention (ifd.5)

**Files:**
- Create: `Plugins/Disk/Sources/DiskLedger.swift`
- Modify: `Plugins/Disk/Sources/DiskModels.swift` (DiskSampling gains the new constants)
- Create: `Plugins/Disk/Tests/DiskLedgerTests.swift`
- Modify: `SystemBarPerformanceTests.swift` (register `DiskLedgerTests.runAll()`)

- [ ] **Step 1: Write the failing tests**

Create `Plugins/Disk/Tests/DiskLedgerTests.swift`:

```swift
import Foundation
import SystemBarKit

/// The Disk tab's ledger: a value type of dated size samples, and the pure functions over it.
@MainActor
enum DiskLedgerTests {
    static func runAll() {
        testAppendingReturnsANewLedgerAndLeavesTheOldOne()
        testLatestIsTheNewestSamplePerPath()
        testSampleAtOrBeforeFindsTheNewestOldEnoughSample()
        testDueRuleUsesThePlansNewestSample()
        testCompactionKeepsEverythingRecentOnePerDayAfterAndNothingOld()
    }

    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    static func sample(_ path: String, _ bytes: UInt64, ago: TimeInterval, plan: DiskPlanKind = .overview) -> DiskSample {
        DiskSample(path: path, bytes: bytes, measuredAt: now.addingTimeInterval(-ago), plan: plan)
    }

    private static func testAppendingReturnsANewLedgerAndLeavesTheOldOne() {
        let empty = DiskLedger()
        let one = empty.appending([sample("/a", 1, ago: 0)])
        expect(empty.samples.isEmpty && one.samples.count == 1, "appending makes a new ledger; the old value is untouched")
        expect(one.version == DiskLedger.currentVersion, "a new ledger carries the current version")
    }

    private static func testLatestIsTheNewestSamplePerPath() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 2 * day),
            sample("/a", 5, ago: 0),
            sample("/b", 7, ago: day),
        ])
        expect(ledger.latest.map { "\($0.path)=\($0.bytes)" } == ["/a=5", "/b=7"], "latest keeps one sample per path, the newest, sorted by path, got \(ledger.latest)")
    }

    private static func testSampleAtOrBeforeFindsTheNewestOldEnoughSample() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 3 * day),
            sample("/a", 2, ago: 2 * day),
            sample("/a", 3, ago: 0),
        ])
        expect(ledger.sample(of: "/a", atOrBefore: now.addingTimeInterval(-day))?.bytes == 2, "the newest sample taken on or before the cut-off, not the newest overall")
        expect(ledger.sample(of: "/a", atOrBefore: now.addingTimeInterval(-4 * day)) == nil, "nothing that old is nil, never a guess")
        expect(ledger.sample(of: "/zzz", atOrBefore: now) == nil, "an unknown path is nil")
    }

    private static func testDueRuleUsesThePlansNewestSample() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 2 * 3600, plan: .overview),
            sample("/b", 1, ago: 7 * 3600, plan: .developer),
        ])
        expect(!ledger.isDue(.overview, cadence: 3 * 3600, now: now), "an overview two hours old is not due on a three-hour cadence")
        expect(ledger.isDue(.developer, cadence: 6 * 3600, now: now), "a developer scan seven hours old is due on a six-hour cadence")
        expect(ledger.isDue(.simulators, cadence: 6 * 3600, now: now), "a plan that never ran is due")
        expect(ledger.newestMeasurement(of: .simulators) == nil, "and has no newest measurement")
    }

    private static func testCompactionKeepsEverythingRecentOnePerDayAfterAndNothingOld() {
        let ledger = DiskLedger().appending([
            sample("/a", 1, ago: 31 * day),            // too old: dropped
            sample("/a", 2, ago: 10 * day + 3600),     // day 90: older of two that day
            sample("/a", 3, ago: 10 * day),            // day 90: kept
            sample("/b", 4, ago: 10 * day),            // day 90, other path: kept
            sample("/a", 5, ago: day + 3600),          // within two days: kept
            sample("/a", 6, ago: 3600),                // within two days: kept
        ])
        let compacted = ledger.compacted(now: now, full: 2 * day, daily: 30 * day)
        expect(compacted.samples.map(\.bytes) == [3, 4, 5, 6], "two days of everything, then one per path per day, nothing past 30 days, in time order, got \(compacted.samples.map(\.bytes))")
        expect(ledger.samples.count == 6, "compaction returns a new ledger and leaves the old one alone")
    }
}
```

In `SystemBarPerformanceTests.main()`, after `MainActor.assumeIsolated { DiskTests.runAll() }` add:

```swift
        MainActor.assumeIsolated { DiskLedgerTests.runAll() }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `cannot find 'DiskLedger' in scope`.

- [ ] **Step 3: Add the constants**

In `DiskModels.swift`, replace the `DiskSampling` enum with:

```swift
/// How often the Disk tab samples, and how long its scans may run. The README's interval table
/// quotes these, so change them together.
enum DiskSampling {
    /// Volumes and `tmutil` while the tab shows.
    static let refreshInterval: TimeInterval = 30
    /// The host's `collect()` while the tab is hidden: a due check, and the scans it starts.
    static let backgroundInterval: TimeInterval = 900
    /// One `du` per row. Generous, because `~/Library` alone takes a minute warm and far longer
    /// cold; bounded, so one pathological tree cannot hold a plan open.
    static let rowTimeout: TimeInterval = 300
    /// Each plan's whole-run ceiling, well under every cadence so plans never overlap.
    static let planBudget: TimeInterval = 900
    static let overviewCadence: TimeInterval = 3 * 3600
    static let developerCadence: TimeInterval = 6 * 3600
    static let simulatorsCadence: TimeInterval = 6 * 3600
    /// Every sample is kept this long, so same-day comparisons work.
    static let fullRetention: TimeInterval = 2 * 86_400
    /// After that, one sample per path per day up to this age; nothing older.
    static let dailyRetention: TimeInterval = 30 * 86_400
}
```

- [ ] **Step 4: Write the ledger**

Create `Plugins/Disk/Sources/DiskLedger.swift`:

```swift
import Foundation

/// Which scan plan measured a sample. Also the key for "when did this plan last run".
enum DiskPlanKind: String, Codable, CaseIterable, Sendable {
    case overview, developer, simulators

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .developer: return "Developer"
        case .simulators: return "Simulators"
        }
    }
}

/// What `simctl` knows about one simulator device, carried on its sample so a row can say
/// which device it is and when it last booted.
struct SimulatorInfo: Codable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let lastBootedAt: Date?
}

/// One measurement of one folder. `bytes` of zero means the folder was gone or empty when the
/// plan looked; the movers list shows a path that went from something to zero as freed.
struct DiskSample: Codable, Equatable, Sendable {
    let path: String
    let bytes: UInt64
    let measuredAt: Date
    let plan: DiskPlanKind
    let simulator: SimulatorInfo?

    init(path: String, bytes: UInt64, measuredAt: Date, plan: DiskPlanKind, simulator: SimulatorInfo? = nil) {
        self.path = path
        self.bytes = bytes
        self.measuredAt = measuredAt
        self.plan = plan
        self.simulator = simulator
    }
}

/// Every sample the Disk tab has kept, as a value: applying samples or compacting returns a new
/// ledger. The derived views (newest per path, a sample from a day ago, which plan is due) are
/// pure functions, so they are tested with hand-built samples and fixed dates.
struct DiskLedger: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = DiskLedger.currentVersion
    var samples: [DiskSample] = []

    func appending(_ new: [DiskSample]) -> DiskLedger {
        DiskLedger(version: version, samples: samples + new)
    }

    /// The newest sample of each path, sorted by path.
    var latest: [DiskSample] {
        var byPath: [String: DiskSample] = [:]
        for sample in samples {
            if let current = byPath[sample.path], current.measuredAt >= sample.measuredAt { continue }
            byPath[sample.path] = sample
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    /// The newest sample of `path` taken at or before `date`, or nil: a comparison with nothing
    /// to compare against says so rather than inventing a zero.
    func sample(of path: String, atOrBefore date: Date) -> DiskSample? {
        samples
            .filter { $0.path == path && $0.measuredAt <= date }
            .max { $0.measuredAt < $1.measuredAt }
    }

    func newestMeasurement(of plan: DiskPlanKind) -> Date? {
        samples.filter { $0.plan == plan }.map(\.measuredAt).max()
    }

    /// A plan is due when it has never run or its newest sample is older than its cadence.
    func isDue(_ plan: DiskPlanKind, cadence: TimeInterval, now: Date) -> Bool {
        guard let newest = newestMeasurement(of: plan) else { return true }
        return now.timeIntervalSince(newest) >= cadence
    }

    /// Retention: every sample younger than `full`; one per path per day (UTC day number, so
    /// the result never depends on the machine's calendar) between `full` and `daily`; nothing
    /// older than `daily`. Returned in time order, then path order, so saves are stable.
    func compacted(now: Date, full: TimeInterval = DiskSampling.fullRetention, daily: TimeInterval = DiskSampling.dailyRetention) -> DiskLedger {
        let fullCutoff = now.addingTimeInterval(-full)
        let dailyCutoff = now.addingTimeInterval(-daily)
        var recent: [DiskSample] = []
        var lastOfDay: [String: DiskSample] = [:]
        for sample in samples {
            if sample.measuredAt < dailyCutoff { continue }
            if sample.measuredAt >= fullCutoff {
                recent.append(sample)
                continue
            }
            let dayNumber = Int((sample.measuredAt.timeIntervalSince1970 / 86_400).rounded(.down))
            let key = "\(sample.path)|\(dayNumber)"
            if let kept = lastOfDay[key], kept.measuredAt >= sample.measuredAt { continue }
            lastOfDay[key] = sample
        }
        let kept = (Array(lastOfDay.values) + recent).sorted {
            $0.measuredAt != $1.measuredAt ? $0.measuredAt < $1.measuredAt : $0.path < $1.path
        }
        return DiskLedger(version: version, samples: kept)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`.

- [ ] **Step 6: Commit**

```bash
git add Plugins/Disk/Sources/DiskLedger.swift Plugins/Disk/Sources/DiskModels.swift Plugins/Disk/Tests/DiskLedgerTests.swift SystemBarPerformanceTests.swift
git commit -m "Disk: a ledger of dated folder sizes, with retention and the due rule

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: rows, remainders, the simulator group, movers and the distribution (ifd.6)

**Files:**
- Create: `Plugins/Disk/Sources/DiskRows.swift`
- Create: `Plugins/Disk/Tests/DiskRowsTests.swift`
- Modify: `SystemBarPerformanceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Plugins/Disk/Tests/DiskRowsTests.swift`:

```swift
import Foundation
import SwiftUI
import SystemBarKit

/// From ledger to panel: the deepest-level rows, parent remainders, the simulator group, movers
/// over a window, and the left column's distribution segments.
@MainActor
enum DiskRowsTests {
    static func runAll() {
        testRowsShowTheDeepestMeasuredLevelAndAParentsRemainder()
        testRowsFoldSimulatorDevicesIntoOneGroupDatedByTheOldest()
        testBiggestRanksBySizeAndHidesEmptyRows()
        testMoversRankByAbsoluteChangeAndNameNewAndFreed()
        testMoversSayNothingForARowWithNoEarlierSample()
        testDistributionIsTopRowsThenEverythingElseThenFree()
        testDisplayPathShortensHome()
    }

    static let home = "/Users/ada"
    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    static func sample(_ path: String, _ bytes: UInt64, ago: TimeInterval = 0, plan: DiskPlanKind = .overview, simulator: SimulatorInfo? = nil) -> DiskSample {
        DiskSample(path: "\(home)/\(path)", bytes: bytes, measuredAt: now.addingTimeInterval(-ago), plan: plan, simulator: simulator)
    }

    private static func testRowsShowTheDeepestMeasuredLevelAndAParentsRemainder() {
        let ledger = DiskLedger().appending([
            sample("Library", 100),
            sample("Library/Developer", 60),
            sample("Library/Caches", 10),
            sample("Library/Developer/Xcode/DerivedData", 25),
            sample("proj", 40),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        expect(byName["DerivedData"]?.bytes == 25 && byName["DerivedData"]?.kind == .folder, "a folder with no measured descendant is a plain row")
        expect(byName["proj"]?.bytes == 40, "so is a top-level folder")
        expect(byName["Developer (rest)"]?.bytes == 35 && byName["Developer (rest)"]?.kind == .remainder, "a parent shows only what its measured children do not explain: 60 - 25, got \(String(describing: byName["Developer (rest)"]))")
        expect(byName["Library (rest)"]?.bytes == 30, "Library's direct measured children are Developer and Caches, not DerivedData: 100 - 60 - 10, got \(String(describing: byName["Library (rest)"]))")
        expect(byName["Library"] == nil && byName["Developer"] == nil, "a parent never appears whole beside its children")
        expect(rows.count == 5, "one row per measured path, got \(rows.map(\.name))")
    }

    private static func testRowsFoldSimulatorDevicesIntoOneGroupDatedByTheOldest() {
        let a = SimulatorInfo(udid: "A", name: "iPhone 17", runtime: "iOS 26.5", lastBootedAt: now)
        let b = SimulatorInfo(udid: "B", name: "iPad", runtime: "iOS 26.5", lastBootedAt: nil)
        let ledger = DiskLedger().appending([
            sample("Library/Developer", 100),
            sample("Library/Developer/CoreSimulator/Devices/A", 30, ago: 3600, plan: .simulators, simulator: a),
            sample("Library/Developer/CoreSimulator/Devices/B", 20, plan: .simulators, simulator: b),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let group = rows.first { $0.kind == .simulatorGroup }
        expect(group?.name == "Simulators · 2 devices" && group?.bytes == 50, "devices fold into one group row with their count and total, got \(String(describing: group))")
        expect(group?.path == "\(home)/Library/Developer/CoreSimulator/Devices", "the group sits at the Devices folder")
        expect(group?.measuredAt == now.addingTimeInterval(-3600), "the group is as old as its oldest device, never flattered")
        expect(rows.first { $0.name == "Developer (rest)" }?.bytes == 50, "the group counts as Developer's measured child: 100 - 50")
        let devices = DiskRows.simulatorRows(from: ledger)
        expect(devices.map(\.name) == ["iPhone 17 · iOS 26.5", "iPad · iOS 26.5"], "device rows are named by simctl and sorted by size, got \(devices.map(\.name))")
        expect(devices.first?.simulator?.lastBootedAt == now && devices.first?.kind == .simulator, "and carry the simulator info")
    }

    private static func testBiggestRanksBySizeAndHidesEmptyRows() {
        let rows = [
            DiskRow(name: "small", path: "/s", bytes: 1, measuredAt: now, kind: .folder, simulator: nil),
            DiskRow(name: "gone", path: "/g", bytes: 0, measuredAt: now, kind: .folder, simulator: nil),
            DiskRow(name: "big", path: "/b", bytes: 9, measuredAt: now, kind: .folder, simulator: nil),
        ]
        expect(DiskRows.biggest(rows).map(\.name) == ["big", "small"], "biggest first, zero-byte rows left out, got \(DiskRows.biggest(rows).map(\.name))")
        expect(DiskRows.biggest(rows, limit: 1).map(\.name) == ["big"], "the limit cuts the tail")
    }

    private static func testMoversRankByAbsoluteChangeAndNameNewAndFreed() {
        let ledger = DiskLedger().appending([
            sample("grew", 10, ago: 2 * day), sample("grew", 40),
            sample("shrank", 50, ago: 2 * day), sample("shrank", 45),
            sample("freed", 20, ago: 2 * day), sample("freed", 0),
            sample("fresh", 7, ago: 3600),
            sample("same", 5, ago: 2 * day), sample("same", 5),
        ])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.map(\.row.name) == ["grew", "freed", "fresh", "shrank"], "ranked by the size of the change; unchanged rows are absent, got \(movers.map(\.row.name))")
        expect(movers[0].change == .grew(30) && movers[1].change == .freed(20), "a growth and a path that went to zero")
        expect(movers[2].change == .new && movers[3].change == .shrank(5), "a path first seen inside the window is new; a shrink is a shrink")
    }

    private static func testMoversSayNothingForARowWithNoEarlierSample() {
        let ledger = DiskLedger().appending([sample("old", 7, ago: 3 * day)])
        let rows = DiskRows.rows(from: ledger, homeDirectory: home)
        let movers = DiskRows.movers(rows: rows, ledger: ledger, window: day, now: now)
        expect(movers.isEmpty, "a row measured once, before the window, has no change to report and is not called new, got \(movers)")
    }

    private static func testDistributionIsTopRowsThenEverythingElseThenFree() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 200, isRoot: true)
        let biggest = [
            DiskRow(name: "Simulators · 3 devices", path: "/sims", bytes: 300, measuredAt: now, kind: .simulatorGroup, simulator: nil),
            DiskRow(name: "proj", path: "/Users/ada/proj", bytes: 100, measuredAt: now, kind: .folder, simulator: nil),
            DiskRow(name: "proj", path: "/opt/proj", bytes: 50, measuredAt: now, kind: .folder, simulator: nil),
        ]
        let segments = DiskRows.distribution(biggest: biggest, volume: volume, homeDirectory: home, limit: 2)
        expect(segments.map(\.label) == ["Simulators · 3 devices", "proj", "Everything else", "Free"], "the top rows, then the rest of used, then free, got \(segments.map(\.label))")
        expect(segments.map(\.value) == [300, 100, 400, 200], "everything else is used minus the shown rows: 800 - 400, got \(segments.map(\.value))")
        let all = DiskRows.distribution(biggest: biggest, volume: volume, homeDirectory: home, limit: 3)
        expect(all.map(\.label) == ["Simulators · 3 devices", "proj", "proj · /opt/proj", "Everything else", "Free"], "a repeated name gets its path, because a legend needs distinct labels, got \(all.map(\.label))")
    }

    private static func testDisplayPathShortensHome() {
        expect(DiskRows.displayPath("\(home)/proj", homeDirectory: home) == "~/proj", "paths under home read as ~/...")
        expect(DiskRows.displayPath(home, homeDirectory: home) == "~", "home itself is ~")
        expect(DiskRows.displayPath("/opt", homeDirectory: home) == "/opt", "others are as they are")
    }
}
```

Register in `SystemBarPerformanceTests.main()` after the ledger tests:

```swift
        MainActor.assumeIsolated { DiskRowsTests.runAll() }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `cannot find 'DiskRows' in scope`.

- [ ] **Step 3: Write the rows**

Create `Plugins/Disk/Sources/DiskRows.swift`:

```swift
import Foundation
import SwiftUI
import SystemBarKit

enum DiskRowKind: Equatable {
    /// A measured folder with no measured descendant.
    case folder
    /// The part of a measured folder its measured children do not explain.
    case remainder
    /// Every simulator device, as one row.
    case simulatorGroup
    /// One simulator device.
    case simulator
}

/// One line of the right-hand list, or one slice of the left-hand distribution.
struct DiskRow: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: UInt64
    let measuredAt: Date
    let kind: DiskRowKind
    let simulator: SimulatorInfo?
}

/// A row and how it changed over the chosen window.
struct DiskMover: Identifiable, Equatable {
    enum Change: Equatable {
        case grew(UInt64)
        case shrank(UInt64)
        /// First seen inside the window.
        case new
        /// Went from this many bytes to zero.
        case freed(UInt64)
    }

    var id: String { row.path }
    let row: DiskRow
    let change: Change

    /// What the movers list ranks by.
    var magnitude: UInt64 {
        switch change {
        case .grew(let bytes), .shrank(let bytes), .freed(let bytes): return bytes
        case .new: return row.bytes
        }
    }
}

/// Pure functions from the ledger to what the panel shows. Nothing here reads the disk.
enum DiskRows {
    static let listLimit = 25
    static let distributionLimit = 6

    /// Every latest sample as a row at the deepest measured level: a folder whose measured
    /// children exist appears only as its remainder, and simulator devices fold into one group,
    /// so no byte is shown twice. Library holds Developer, which holds CoreSimulator: showing all
    /// three whole would bill the same space three times.
    static func rows(from ledger: DiskLedger, homeDirectory: String) -> [DiskRow] {
        let latest = ledger.latest
        let devices = latest.filter { $0.simulator != nil }
        let folders = latest.filter { $0.simulator == nil }

        var rows: [DiskRow] = []
        var bytesByPath: [String: UInt64] = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0.bytes) })
        if let group = simulatorGroup(devices) {
            rows.append(group)
            bytesByPath[group.path] = group.bytes
        }
        let measuredPaths = Array(bytesByPath.keys)

        for sample in folders {
            let children = directChildren(of: sample.path, among: measuredPaths)
            if children.isEmpty {
                rows.append(DiskRow(name: displayName(sample.path, homeDirectory: homeDirectory), path: sample.path, bytes: sample.bytes, measuredAt: sample.measuredAt, kind: .folder, simulator: nil))
                continue
            }
            let explained = children.reduce(UInt64(0)) { $0 &+ (bytesByPath[$1] ?? 0) }
            let rest = sample.bytes > explained ? sample.bytes - explained : 0
            rows.append(DiskRow(name: "\(displayName(sample.path, homeDirectory: homeDirectory)) (rest)", path: sample.path, bytes: rest, measuredAt: sample.measuredAt, kind: .remainder, simulator: nil))
        }
        return rows
    }

    /// One row for every simulator device, as old as the oldest device measurement, so the age
    /// shown is never newer than the data behind it.
    private static func simulatorGroup(_ devices: [DiskSample]) -> DiskRow? {
        guard let first = devices.first, let oldest = devices.map(\.measuredAt).min() else { return nil }
        let count = devices.count
        return DiskRow(
            name: "Simulators · \(count) device\(count == 1 ? "" : "s")",
            path: (first.path as NSString).deletingLastPathComponent,
            bytes: devices.reduce(UInt64(0)) { $0 &+ $1.bytes },
            measuredAt: oldest,
            kind: .simulatorGroup,
            simulator: nil
        )
    }

    /// One row per device, biggest first, for the expanded simulator group.
    static func simulatorRows(from ledger: DiskLedger) -> [DiskRow] {
        ledger.latest
            .compactMap { sample -> DiskRow? in
                guard let info = sample.simulator else { return nil }
                return DiskRow(name: "\(info.name) · \(info.runtime)", path: sample.path, bytes: sample.bytes, measuredAt: sample.measuredAt, kind: .simulator, simulator: info)
            }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// The measured paths under `parent` with no other measured path between them and it.
    static func directChildren(of parent: String, among paths: [String]) -> [String] {
        let prefix = parent + "/"
        let under = paths.filter { $0.hasPrefix(prefix) }
        return under.filter { child in
            !under.contains { other in other != child && child.hasPrefix(other + "/") }
        }
    }

    static func biggest(_ rows: [DiskRow], limit: Int = listLimit) -> [DiskRow] {
        Array(rows.filter { $0.bytes > 0 }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }.prefix(limit))
    }

    /// Each row against its own newest sample from at or before `window` ago. A row with no such
    /// sample is new when it was first measured inside the window, and silent otherwise: a
    /// folder measured once, before the window, has nothing to be compared with.
    static func movers(rows: [DiskRow], ledger: DiskLedger, window: TimeInterval, now: Date, limit: Int = listLimit) -> [DiskMover] {
        let since = now.addingTimeInterval(-window)
        let movers = rows.compactMap { row -> DiskMover? in
            guard row.kind != .remainder else { return nil }
            guard let earlier = earlierBytes(of: row, ledger: ledger, atOrBefore: since) else {
                return row.measuredAt > since && row.bytes > 0 ? DiskMover(row: row, change: .new) : nil
            }
            if row.bytes == 0, earlier > 0 { return DiskMover(row: row, change: .freed(earlier)) }
            if row.bytes > earlier { return DiskMover(row: row, change: .grew(row.bytes - earlier)) }
            if row.bytes < earlier { return DiskMover(row: row, change: .shrank(earlier - row.bytes)) }
            return nil
        }
        return Array(movers.sorted { $0.magnitude != $1.magnitude ? $0.magnitude > $1.magnitude : $0.row.path < $1.row.path }.prefix(limit))
    }

    /// A folder's earlier size is its own earlier sample; the simulator group's is the sum of
    /// its devices' earlier samples, nil when none of them has one.
    private static func earlierBytes(of row: DiskRow, ledger: DiskLedger, atOrBefore since: Date) -> UInt64? {
        guard row.kind == .simulatorGroup else {
            return ledger.sample(of: row.path, atOrBefore: since)?.bytes
        }
        let devicePaths = Set(ledger.latest.filter { $0.simulator != nil }.map(\.path))
        let earlier = devicePaths.compactMap { ledger.sample(of: $0, atOrBefore: since)?.bytes }
        return earlier.isEmpty ? nil : earlier.reduce(0, &+)
    }

    /// The left column's second bar: the biggest rows, then the rest of what is used, then free,
    /// all slices of the volume's capacity. Labels must be distinct for the legend, so a repeated
    /// name carries its path.
    static func distribution(biggest: [DiskRow], volume: DiskVolume, homeDirectory: String, limit: Int = distributionLimit) -> [BarSegment] {
        let colors = [Palette.cyan, Palette.blue, Palette.purple, Palette.tangerine, Palette.caution, Palette.warning]
        let top = Array(biggest.prefix(limit))
        let shown = top.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let rest = volume.used > shown ? volume.used - shown : 0
        var seen = Set<String>()
        let slices = top.enumerated().map { index, row -> BarSegment in
            let label = seen.insert(row.name).inserted ? row.name : "\(row.name) · \(displayPath(row.path, homeDirectory: homeDirectory))"
            return BarSegment(label: label, value: row.bytes, color: colors[index % colors.count])
        }
        return slices + [
            BarSegment(label: "Everything else", value: rest, color: Color.white.opacity(0.35)),
            BarSegment(label: "Free", value: volume.free, color: Palette.good),
        ]
    }

    static func displayName(_ path: String, homeDirectory: String) -> String {
        path == homeDirectory ? "~" : (path as NSString).lastPathComponent
    }

    static func displayPath(_ path: String, homeDirectory: String) -> String {
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") { return "~" + path.dropFirst(homeDirectory.count) }
        return path
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`. If `testRowsShowTheDeepestMeasuredLevelAndAParentsRemainder` fails on `Library (rest)`, check `directChildren`: DerivedData is under Developer, so it must not count as Library's direct child.

- [ ] **Step 5: Commit**

```bash
git add Plugins/Disk/Sources/DiskRows.swift Plugins/Disk/Tests/DiskRowsTests.swift SystemBarPerformanceTests.swift
git commit -m "Disk: derive ranked rows, remainders, the simulator group, movers and the distribution from the ledger

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `DiskLedgerStore` (ifd.7)

**Files:**
- Create: `Plugins/Disk/Sources/DiskLedgerStore.swift`
- Create: `Plugins/Disk/Tests/DiskStoreTests.swift`
- Modify: `SystemBarPerformanceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Plugins/Disk/Tests/DiskStoreTests.swift`:

```swift
import Foundation
import SystemBarKit

/// The ledger's file: round trip, a missing file, a broken file moved aside, and the folder
/// created on first save. Every test writes inside a temporary folder it removes.
@MainActor
enum DiskStoreTests {
    static func runAll() {
        testStandardStoreLivesInThePluginsDataFolder()
        testMissingFileIsFresh()
        testSaveCreatesTheFolderAndLoadReadsBackEqual()
        testBrokenFileIsMovedAsideAndReported()
        testWrongVersionIsMovedAside()
    }

    private static func testStandardStoreLivesInThePluginsDataFolder() {
        let store = DiskLedgerStore.standard(dataDirectory: URL(fileURLWithPath: "/data/disk"))
        expect(store.fileURL.path == "/data/disk/disk-ledger.json", "the ledger is one file in the plugin's own folder, got \(store.fileURL.path)")
    }

    private static func testMissingFileIsFresh() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("none/disk-ledger.json"))
        expect(store.load() == .fresh, "no file means a fresh start, not an error")
    }

    private static func testSaveCreatesTheFolderAndLoadReadsBackEqual() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk/disk-ledger.json"))
        let info = SimulatorInfo(udid: "A", name: "iPhone", runtime: "iOS 26.5", lastBootedAt: Date(timeIntervalSince1970: 2_000))
        let ledger = DiskLedger().appending([
            DiskSample(path: "/Users/ada/proj", bytes: 42, measuredAt: Date(timeIntervalSince1970: 1_000), plan: .overview),
            DiskSample(path: "/Users/ada/Library/Developer/CoreSimulator/Devices/A", bytes: 7, measuredAt: Date(timeIntervalSince1970: 1_500), plan: .simulators, simulator: info),
        ])
        do {
            try store.save(ledger)
        } catch {
            expect(false, "save creates the folder and writes: \(error)")
        }
        expect(store.load() == .loaded(ledger), "what was saved loads back equal (dates are whole seconds, which ISO 8601 keeps), got \(store.load())")
    }

    private static func testBrokenFileIsMovedAsideAndReported() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk-ledger.json"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: store.fileURL)
        guard case let .movedAside(to, reason) = store.load() else {
            expect(false, "a file that will not parse is moved aside, got \(store.load())")
            return
        }
        expect(to == store.fileURL.path + ".broken", "it is renamed with a .broken suffix, got \(to)")
        expect(!reason.isEmpty, "and the reason is kept for the status line")
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path) && FileManager.default.fileExists(atPath: to), "the broken file is out of the way and still there to look at")
        expect(store.load() == .fresh, "so the next load starts fresh")
    }

    private static func testWrongVersionIsMovedAside() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore(fileURL: directory.appendingPathComponent("disk-ledger.json"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(#"{ "version": 99, "samples": [] }"#.utf8).write(to: store.fileURL)
        guard case let .movedAside(_, reason) = store.load() else {
            expect(false, "a ledger from a version this code does not know is moved aside, got \(store.load())")
            return
        }
        expect(reason.contains("99"), "the reason names the version, got \(reason)")
    }
}
```

Register in `SystemBarPerformanceTests.main()` after the rows tests:

```swift
        MainActor.assumeIsolated { DiskStoreTests.runAll() }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `cannot find 'DiskLedgerStore' in scope`.

- [ ] **Step 3: Write the store**

Create `Plugins/Disk/Sources/DiskLedgerStore.swift`:

```swift
import Foundation

/// The ledger's one file, in the plugin's data folder. Writes are atomic (Foundation writes a
/// temporary file and renames it into place), so a crash mid-write never leaves half a file.
struct DiskLedgerStore {
    static let fileName = "disk-ledger.json"

    let fileURL: URL

    static func standard(dataDirectory: URL) -> DiskLedgerStore {
        DiskLedgerStore(fileURL: dataDirectory.appendingPathComponent(fileName))
    }

    enum LoadOutcome: Equatable {
        /// No file yet.
        case fresh
        case loaded(DiskLedger)
        /// The file could not be used and was renamed with a `.broken` suffix; `to` is where it
        /// went, `reason` why. The caller starts fresh and says so.
        case movedAside(to: String, reason: String)
    }

    func load() -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .fresh
        } catch {
            return moveAside(reason: error.localizedDescription)
        }
        let ledger: DiskLedger
        do {
            ledger = try Self.decoder.decode(DiskLedger.self, from: data)
        } catch {
            return moveAside(reason: "not a ledger: \(error.localizedDescription)")
        }
        guard ledger.version == DiskLedger.currentVersion else {
            return moveAside(reason: "version \(ledger.version), but this build reads version \(DiskLedger.currentVersion)")
        }
        return .loaded(ledger)
    }

    private func moveAside(reason: String) -> LoadOutcome {
        let aside = fileURL.appendingPathExtension("broken")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            return .movedAside(to: aside.path, reason: "\(reason); and it could not be moved aside: \(error.localizedDescription)")
        }
        return .movedAside(to: aside.path, reason: reason)
    }

    /// Creates the plugin's folder on first use, then writes atomically.
    func save(_ ledger: DiskLedger) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(ledger).write(to: fileURL, options: .atomic)
    }

    /// Whole-second ISO 8601 dates and sorted keys, so the file diffs sanely and reads by eye.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`.

- [ ] **Step 5: Commit**

```bash
git add Plugins/Disk/Sources/DiskLedgerStore.swift Plugins/Disk/Tests/DiskStoreTests.swift SystemBarPerformanceTests.swift
git commit -m "Disk: save the ledger as one JSON file, atomically, and move a broken one aside

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: scan plans, targets, vanished paths, and the simctl catalog (ifd.8)

**Files:**
- Create: `Plugins/Disk/Sources/DiskScanPlans.swift`
- Create: `Plugins/Disk/Sources/SimulatorCatalog.swift`
- Create: `Plugins/Disk/Tests/DiskScanTests.swift`
- Modify: `SystemBarPerformanceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Plugins/Disk/Tests/DiskScanTests.swift`:

```swift
import Foundation
import SystemBarKit

/// What a plan measures and in what order, which known paths have vanished, the simctl catalog,
/// and (from Task 9) the measure loop itself.
@MainActor
enum DiskScanTests {
    static func runAll() {
        testPlansResolveRootsAgainstHomeAndKeepTheirCadences()
        testTargetsAreEveryRootsChildrenBiggestKnownFirstWithoutRepeats()
        testSimulatorTargetsCarryTheCatalogOrFallBackToTheUdid()
        testVanishedPathsBecomeZeroSamplesForTheirPlanOnly()
        testSimulatorCatalogParsesSimctlAndPrettifiesTheRuntime()
    }

    static let home = "/Users/ada"
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    /// A fake folder listing: children per parent, absolute paths. Anything unlisted is empty.
    static func lister(_ tree: [String: [String]]) -> (String) -> [String] {
        { parent in (tree[parent] ?? []).map { "\(parent)/\($0)" } }
    }

    private static func testPlansResolveRootsAgainstHomeAndKeepTheirCadences() {
        let overview = DiskScanPlan.plan(.overview)
        expect(overview.resolvedRoots(homeDirectory: home) == [home, "\(home)/Library", "/Applications", "/opt", "/Library"], "an empty root is home, a relative one is under home, an absolute one is itself, got \(overview.resolvedRoots(homeDirectory: home))")
        expect(overview.cadence == DiskSampling.overviewCadence && DiskScanPlan.plan(.developer).cadence == DiskSampling.developerCadence && DiskScanPlan.plan(.simulators).cadence == DiskSampling.simulatorsCadence, "each plan carries its own cadence")
        expect(DiskScanPlan.all.map(\.kind) == [.overview, .developer, .simulators], "plans run in this order when several are due")
        expect(DiskScanPlan.plan(.developer).resolvedRoots(homeDirectory: home).contains("\(home)/Library/Application Support"), "the developer plan reaches into Application Support, because this is a developer's tool")
        expect(DiskScanPlan.plan(.simulators).resolvedRoots(homeDirectory: home) == ["\(home)/Library/Developer/CoreSimulator/Devices"], "the simulator plan measures each device folder")
    }

    private static func testTargetsAreEveryRootsChildrenBiggestKnownFirstWithoutRepeats() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 1, roots: ["", "Library", "/opt"])
        let tree = [
            home: ["Library", "proj", ".cache"],
            "\(home)/Library": ["Developer", "Caches"],
            "/opt": ["homebrew"],
        ]
        let previous = DiskLedger().appending([
            DiskSample(path: "\(home)/proj", bytes: 50, measuredAt: now, plan: .overview),
            DiskSample(path: "\(home)/Library/Developer", bytes: 900, measuredAt: now, plan: .overview),
        ])
        let targets = DiskScanTargets.targets(for: plan, homeDirectory: home, previous: previous, listChildren: lister(tree), catalog: [:])
        expect(targets.map(\.path) == ["\(home)/Library/Developer", "\(home)/proj", "/opt/homebrew", "\(home)/.cache", "\(home)/Library", "\(home)/Library/Caches"],
               "known-biggest first so a spent budget cuts the smallest, then unknown paths by name, got \(targets.map(\.path))")
        expect(targets.allSatisfy { $0.simulator == nil }, "folder targets carry no simulator info")
    }

    private static func testSimulatorTargetsCarryTheCatalogOrFallBackToTheUdid() {
        let plan = DiskScanPlan.plan(.simulators)
        let devices = "\(home)/Library/Developer/CoreSimulator/Devices"
        let known = SimulatorInfo(udid: "AAA", name: "iPhone 17", runtime: "iOS 26.5", lastBootedAt: now)
        let targets = DiskScanTargets.targets(for: plan, homeDirectory: home, previous: DiskLedger(), listChildren: lister([devices: ["AAA", "BBB"]]), catalog: ["AAA": known])
        expect(targets.map(\.path) == ["\(devices)/AAA", "\(devices)/BBB"], "each device folder is a target, got \(targets.map(\.path))")
        expect(targets[0].simulator == known, "a device simctl knows carries its name, runtime and last boot")
        expect(targets[1].simulator == SimulatorInfo(udid: "BBB", name: "BBB", runtime: "unknown runtime", lastBootedAt: nil), "one it does not know is still measured, named by its folder, got \(String(describing: targets[1].simulator))")
    }

    private static func testVanishedPathsBecomeZeroSamplesForTheirPlanOnly() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 1, roots: [""])
        let previous = DiskLedger().appending([
            DiskSample(path: "\(home)/gone", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/stays", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/already-zero", bytes: 0, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/Library/Developer", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/other-plan", bytes: 10, measuredAt: now.addingTimeInterval(-3600), plan: .developer),
        ])
        let targets = [DiskScanTarget(path: "\(home)/stays", simulator: nil)]
        let vanished = DiskScanTargets.vanished(plan: plan, homeDirectory: home, previous: previous, targets: targets, now: now)
        expect(vanished.map(\.path) == ["\(home)/gone"], "only a path this plan measured, directly under one of its roots, that had bytes and is no longer listed, got \(vanished.map(\.path))")
        expect(vanished.first?.bytes == 0 && vanished.first?.measuredAt == now && vanished.first?.plan == .overview, "it is recorded as zero bytes now, so movers can show it as freed")
    }

    private static func testSimulatorCatalogParsesSimctlAndPrettifiesTheRuntime() {
        let json = """
        { "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              { "udid": "AAA", "name": "iPhone 17", "lastBootedAt": "2026-09-18T07:41:44Z", "state": "Shutdown", "dataPath": "/x/AAA/data" },
              { "udid": "BBB", "name": "iPad", "state": "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": []
        } }
        """
        let catalog = SimulatorCatalog.parse(json)
        expect(catalog.count == 2, "one entry per device across runtimes, got \(catalog.keys.sorted())")
        expect(catalog["AAA"]?.name == "iPhone 17" && catalog["AAA"]?.runtime == "iOS 26.5", "the runtime identifier reads as a product and version, got \(String(describing: catalog["AAA"]))")
        expect(catalog["AAA"]?.lastBootedAt == Date(timeIntervalSince1970: 1_789_717_304), "the last boot parses as a date")
        expect(catalog["BBB"]?.lastBootedAt == nil, "a device that never booted has none")
        expect(SimulatorCatalog.parse("not json").isEmpty && SimulatorCatalog.parse("").isEmpty, "unparseable output is an empty catalog, never a crash")
        expect(SimulatorCatalog.runtimeLabel("com.apple.CoreSimulator.SimRuntime.xrOS-3-1") == "xrOS 3.1" && SimulatorCatalog.runtimeLabel("odd") == "odd", "labels: product, space, dotted version; anything else as written")
    }
}
```

Register in `SystemBarPerformanceTests.main()` after the store tests:

```swift
        MainActor.assumeIsolated { DiskScanTests.runAll() }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `cannot find 'DiskScanPlan' in scope`.

- [ ] **Step 3: Write the plans and targets**

Create `Plugins/Disk/Sources/DiskScanPlans.swift`:

```swift
import Foundation

/// One tier of the scan: which folders, how often, and for how long. Each root's immediate
/// subfolders are measured, one `du` each; the root itself is not, because its parent's plan
/// already measured it as a child.
struct DiskScanPlan: Equatable {
    let kind: DiskPlanKind
    let cadence: TimeInterval
    let budget: TimeInterval
    /// "" is home, a relative path is under home, a path starting with "/" is itself.
    let roots: [String]

    /// In the order they run when several are due: the cheap wide sweep first.
    static let all: [DiskScanPlan] = [
        DiskScanPlan(kind: .overview, cadence: DiskSampling.overviewCadence, budget: DiskSampling.planBudget,
                     roots: ["", "Library", "/Applications", "/opt", "/Library"]),
        DiskScanPlan(kind: .developer, cadence: DiskSampling.developerCadence, budget: DiskSampling.planBudget,
                     roots: ["Library/Application Support", "Library/Containers", "Library/Group Containers",
                             "Library/Developer/Xcode", ".cache", ".ollama", ".android", "proj"]),
        DiskScanPlan(kind: .simulators, cadence: DiskSampling.simulatorsCadence, budget: DiskSampling.planBudget,
                     roots: ["Library/Developer/CoreSimulator/Devices"]),
    ]

    static func plan(_ kind: DiskPlanKind) -> DiskScanPlan {
        all.first { $0.kind == kind }!
    }

    func resolvedRoots(homeDirectory: String) -> [String] {
        roots.map { root in
            if root.isEmpty { return homeDirectory }
            if root.hasPrefix("/") { return root }
            return "\(homeDirectory)/\(root)"
        }
    }
}

/// One folder a plan will measure.
struct DiskScanTarget: Equatable {
    let path: String
    let simulator: SimulatorInfo?
}

/// Pure: which folders a plan measures, in which order, and which earlier ones are gone.
enum DiskScanTargets {
    /// Every subfolder of every root, each once, biggest-known-first so a spent budget cuts the
    /// smallest, then never-measured folders by name. Simulator targets carry what the catalog
    /// knows, or their folder name when it knows nothing.
    static func targets(
        for plan: DiskScanPlan,
        homeDirectory: String,
        previous: DiskLedger,
        listChildren: (String) -> [String],
        catalog: [String: SimulatorInfo]
    ) -> [DiskScanTarget] {
        let known = Dictionary(uniqueKeysWithValues: previous.latest.map { ($0.path, $0.bytes) })
        var seen = Set<String>()
        let paths = plan.resolvedRoots(homeDirectory: homeDirectory)
            .flatMap(listChildren)
            .filter { seen.insert($0).inserted }
            .sorted { a, b in
                let (sizeA, sizeB) = (known[a] ?? 0, known[b] ?? 0)
                return sizeA != sizeB ? sizeA > sizeB : a < b
            }
        return paths.map { path in
            guard plan.kind == .simulators else { return DiskScanTarget(path: path, simulator: nil) }
            let udid = (path as NSString).lastPathComponent
            let info = catalog[udid] ?? SimulatorInfo(udid: udid, name: udid, runtime: "unknown runtime", lastBootedAt: nil)
            return DiskScanTarget(path: path, simulator: info)
        }
    }

    /// Paths this plan measured before, directly under one of its roots, that had bytes and are
    /// not among today's targets: recorded as zero now, so the movers list can show them freed.
    static func vanished(plan: DiskScanPlan, homeDirectory: String, previous: DiskLedger, targets: [DiskScanTarget], now: Date) -> [DiskSample] {
        let roots = Set(plan.resolvedRoots(homeDirectory: homeDirectory))
        let present = Set(targets.map(\.path))
        return previous.latest
            .filter { sample in
                sample.plan == plan.kind
                    && sample.bytes > 0
                    && !present.contains(sample.path)
                    && roots.contains((sample.path as NSString).deletingLastPathComponent)
            }
            .map { DiskSample(path: $0.path, bytes: 0, measuredAt: now, plan: plan.kind, simulator: $0.simulator) }
    }
}
```

- [ ] **Step 4: Write the simctl catalog**

Create `Plugins/Disk/Sources/SimulatorCatalog.swift`:

```swift
import Foundation

/// What `xcrun simctl list devices -j` says about each device, keyed by udid. Runtimes come as
/// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` and read better as `iOS 26.5`.
enum SimulatorCatalog {
    static let command = "/usr/bin/xcrun"
    static let arguments = ["simctl", "list", "devices", "-j"]
    private static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime."
    private static let dates = ISO8601DateFormatter()

    static func parse(_ output: String) -> [String: SimulatorInfo] {
        guard let data = output.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [:] }
        var catalog: [String: SimulatorInfo] = [:]
        for (runtime, list) in devices {
            for device in list {
                guard let udid = device["udid"] as? String else { continue }
                catalog[udid] = SimulatorInfo(
                    udid: udid,
                    name: device["name"] as? String ?? udid,
                    runtime: runtimeLabel(runtime),
                    lastBootedAt: (device["lastBootedAt"] as? String).flatMap(dates.date(from:))
                )
            }
        }
        return catalog
    }

    static func runtimeLabel(_ identifier: String) -> String {
        let short = identifier.hasPrefix(runtimePrefix) ? String(identifier.dropFirst(runtimePrefix.count)) : identifier
        let parts = short.split(separator: "-")
        guard parts.count >= 2 else { return short }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`.

- [ ] **Step 6: Commit**

```bash
git add Plugins/Disk/Sources/DiskScanPlans.swift Plugins/Disk/Sources/SimulatorCatalog.swift Plugins/Disk/Tests/DiskScanTests.swift SystemBarPerformanceTests.swift
git commit -m "Disk: three scan plans, their targets biggest-known-first, vanished paths, and the simctl catalog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `DiskScanner` measure loop and outcome (ifd.9)

**Files:**
- Create: `Plugins/Disk/Sources/DiskScanner.swift`
- Modify: `Plugins/Disk/Tests/DiskScanTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `DiskScanTests.runAll()`:

```swift
        testMeasureRecordsEachFinishedRowAndCountsTheRest()
        testMeasureStopsAtTheBudgetAndCountsWhatItSkipped()
        testScannerRunsDuAndSimctlThroughTheHost()
        testOutcomeStatusNamesEveryWayARowCanBeMissing()
```

Add the tests:

```swift
    static func duFinished(_ path: String, kilobytes: UInt64) -> CommandOutput {
        CommandOutput(output: "\(kilobytes)\t\(path)\n", error: "", status: 0, didTimeout: false)
    }

    private static func testMeasureRecordsEachFinishedRowAndCountsTheRest() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 100, roots: [""])
        let targets = ["/a", "/slow", "/denied", "/b"].map { DiskScanTarget(path: $0, simulator: nil) }
        var rows: [DiskSample] = []
        let outcome = DiskScanner.measure(targets: targets, plan: plan, now: { now }, elapsed: { 0 }, measure: { path in
            switch path {
            case "/a": return duFinished("/a", kilobytes: 2)
            case "/b": return duFinished("/b", kilobytes: 3)
            case "/slow": return CommandOutput(output: "", error: "", status: 15, didTimeout: true)
            default: return CommandOutput(output: "", error: "du: /denied: Operation not permitted", status: 1, didTimeout: false)
            }
        }, onRow: { rows.append($0) })
        expect(rows.map { "\($0.path)=\($0.bytes)" } == ["/a=2048", "/b=3072"], "each finished du becomes a sample in bytes, as it finishes, got \(rows)")
        expect(rows.allSatisfy { $0.measuredAt == now && $0.plan == .overview }, "stamped now, for this plan")
        expect(outcome == DiskScanOutcome(measured: 2, timedOut: 1, unreadable: 1, unmeasured: 0), "the outcome counts every way a row can be missing, got \(outcome)")
    }

    private static func testMeasureStopsAtTheBudgetAndCountsWhatItSkipped() {
        let plan = DiskScanPlan(kind: .overview, cadence: 1, budget: 10, roots: [""])
        let targets = ["/a", "/b", "/c"].map { DiskScanTarget(path: $0, simulator: nil) }
        var clock: TimeInterval = 0
        var rows: [DiskSample] = []
        let outcome = DiskScanner.measure(targets: targets, plan: plan, now: { now }, elapsed: { clock }, measure: { path in
            clock += 6
            return duFinished(path, kilobytes: 1)
        }, onRow: { rows.append($0) })
        expect(rows.map(\.path) == ["/a", "/b"], "the budget is checked before each du: the first two fit, the third is skipped, got \(rows.map(\.path))")
        expect(outcome.unmeasured == 1 && outcome.measured == 2, "and the skipped one is counted, got \(outcome)")
    }

    private static func testScannerRunsDuAndSimctlThroughTheHost() {
        let recorder = LogRecorder()
        let devices = "/tmp/systembar-tests/Library/Developer/CoreSimulator/Devices"
        let simctl = #"{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [ { "udid": "AAA", "name": "iPhone 17" } ] } }"#
        let host = makeHost(runner: recordingRunner(recorder, answers: [
            "/usr/bin/xcrun simctl list devices -j": simctl,
            "/usr/bin/du -s -k -x \(devices)/AAA": "5\t\(devices)/AAA\n",
        ]))
        let scanner = DiskScanner(host: host, listChildren: lister([devices: ["AAA"]]))
        var rows: [DiskSample] = []
        let outcome = scanner.run(plan: .plan(.simulators), previous: DiskLedger(), onRow: { rows.append($0) })
        expect(recorder.messages == ["/usr/bin/xcrun simctl list devices -j", "/usr/bin/du -s -k -x \(devices)/AAA"], "simctl once, then one du per device, all by explicit path through the host, got \(recorder.messages)")
        expect(rows.count == 1 && rows.first?.bytes == 5 * 1024 && rows.first?.simulator?.name == "iPhone 17", "the device row carries simctl's name, got \(rows)")
        expect(outcome.measured == 1, "and counts as measured")
    }

    private static func testOutcomeStatusNamesEveryWayARowCanBeMissing() {
        expect(DiskScanOutcome(measured: 1, timedOut: 0, unreadable: 0, unmeasured: 0).status == "Measured 1 path", "singular")
        expect(DiskScanOutcome(measured: 3, timedOut: 1, unreadable: 2, unmeasured: 4).status == "Measured 3 paths, 1 too slow to finish, 2 unreadable (needs Full Disk Access?), 4 not measured, scan budget spent", "each nonzero count gets a clause, got \(DiskScanOutcome(measured: 3, timedOut: 1, unreadable: 2, unmeasured: 4).status)")
        expect(DiskScanOutcome().status == "Measured 0 paths", "zero measured is said plainly")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `cannot find 'DiskScanner' in scope`.

- [ ] **Step 3: Write the scanner**

Create `Plugins/Disk/Sources/DiskScanner.swift`:

```swift
import Foundation
import SystemBarKit

/// How one plan's run went. Every way a row can be missing is counted, so a partial scan never
/// reads as a complete one and a slow tree is never mistaken for a permission problem.
struct DiskScanOutcome: Equatable {
    var measured = 0
    var timedOut = 0
    var unreadable = 0
    var unmeasured = 0

    var status: String {
        var parts = ["Measured \(measured) path\(measured == 1 ? "" : "s")"]
        if timedOut > 0 { parts.append("\(timedOut) too slow to finish") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable (needs Full Disk Access?)") }
        if unmeasured > 0 { parts.append("\(unmeasured) not measured, scan budget spent") }
        return parts.joined(separator: ", ")
    }
}

/// Runs one plan: lists the targets, records vanished paths, then one `du` per target until the
/// budget is spent, handing each finished row to `onRow` as it lands. Per-folder processes are
/// deliberate: a single `du` over everything outruns any timeout and, writing to a pipe, loses
/// every total when killed; per-path processes flush on exit, so a slow or unreadable tree costs
/// only its own row. Called from the plugin's scan queue only.
final class DiskScanner: @unchecked Sendable {
    private let host: HostServices
    private let listChildren: (String) -> [String]

    init(host: HostServices, listChildren: @escaping (String) -> [String] = DiskScanner.subfolders) {
        self.host = host
        self.listChildren = listChildren
    }

    /// The immediate subfolders of `directory`, hidden ones included, symlinks excluded (a link
    /// into another tree would bill that tree here too). An unreadable or missing directory lists
    /// nothing; its parent's row still carries its size.
    static func subfolders(of directory: String) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return entry.path
        }
    }

    func run(plan: DiskScanPlan, previous: DiskLedger, onRow: (DiskSample) -> Void) -> DiskScanOutcome {
        let start = Date()
        let catalog = plan.kind == .simulators
            ? SimulatorCatalog.parse(host.run(path: SimulatorCatalog.command, arguments: SimulatorCatalog.arguments).output)
            : [:]
        let targets = DiskScanTargets.targets(for: plan, homeDirectory: host.homeDirectory, previous: previous, listChildren: listChildren, catalog: catalog)
        DiskScanTargets.vanished(plan: plan, homeDirectory: host.homeDirectory, previous: previous, targets: targets, now: Date()).forEach(onRow)
        let host = self.host
        return Self.measure(
            targets: targets,
            plan: plan,
            now: { Date() },
            elapsed: { Date().timeIntervalSince(start) },
            measure: { path in
                // -x keeps du on one filesystem; -k normalises to KiB across macOS versions.
                host.run(path: "/usr/bin/du", arguments: ["-s", "-k", "-x", path], timeout: DiskSampling.rowTimeout)
            },
            onRow: onRow
        )
    }

    /// The loop, with its clock and its `du` injected so a test can run it in no time.
    static func measure(
        targets: [DiskScanTarget],
        plan: DiskScanPlan,
        now: () -> Date,
        elapsed: () -> TimeInterval,
        measure: (String) -> CommandOutput,
        onRow: (DiskSample) -> Void
    ) -> DiskScanOutcome {
        var outcome = DiskScanOutcome()
        for target in targets {
            guard elapsed() < plan.budget else {
                outcome.unmeasured += 1
                continue
            }
            let result = measure(target.path)
            // `du -s` prints one "<kilobytes>\t<path>" line once the walk finishes; anything else
            // means this tree has no answer, which says nothing about the other trees.
            guard let bytes = parseDiskUsage(result.output).first?.bytes else {
                if result.didTimeout { outcome.timedOut += 1 } else { outcome.unreadable += 1 }
                continue
            }
            outcome.measured += 1
            onRow(DiskSample(path: target.path, bytes: bytes, measuredAt: now(), plan: plan.kind, simulator: target.simulator))
        }
        return outcome
    }

    /// `du -s -k` emits "<kilobytes>\t<path>" per measured path.
    static func parseDiskUsage(_ output: String) -> [(path: String, bytes: UInt64)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let kilobytes = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return (path, kilobytes &* 1024)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`. (`DiskCollector.parseDiskUsage` still exists until Task 10; the two do not clash because they live on different types.)

- [ ] **Step 5: Commit**

```bash
git add Plugins/Disk/Sources/DiskScanner.swift Plugins/Disk/Tests/DiskScanTests.swift
git commit -m "Disk: run a scan plan one du per folder within its budget, and say what was not measured

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: plugin wiring (ifd.10)

Depends on ewy.1 (`backgroundInterval` in `TabPlugin`). The plugin compiles without it, because `backgroundInterval` is then just a stored property the host ignores, so this task can be done before ewy.1 lands and gains its effect when it does.

**Files:**
- Modify: `Plugins/Disk/Sources/DiskModels.swift` (DiskSnapshot; delete DiskHog, DiskHogCandidate, DiskHogUpdate and the old `applying` extension)
- Modify: `Plugins/Disk/Sources/DiskCollector.swift` (volumes and snapshots only)
- Modify: `Plugins/Disk/Sources/DiskPlugin.swift`
- Modify: `Plugins/Disk/Sources/DiskPanel.swift` (only enough to compile; Task 11 rewrites it)
- Rewrite: `Plugins/Disk/Tests/DiskTests.swift`

- [ ] **Step 1: Rewrite the tests**

Replace `Plugins/Disk/Tests/DiskTests.swift` entirely:

```swift
import Foundation
import SystemBarKit

/// The Disk tab: volume math, the plugin's settings, and the plugin end to end through a fake
/// host with a temporary data folder. Main-actor because a plugin is constructed on the main
/// thread, by contract.
@MainActor
enum DiskTests {
    static func runAll() {
        testDiskVolumeMath()
        testLocalSnapshotParsing()
        testSnapshotCountRunsTmutilThroughTheHost()
        testSnapshotAppliesAReadingAndALedger()
        testSamplingIntervalsKeepScansRare()
        testBackgroundScansSettingDefaultsOnAndReportsAWrongType()
        testPluginDeclaresABackgroundIntervalUnlessTurnedOff()
        testCollectRunsDuePlansOnceAndSavesTheLedger()
        testPluginStartsFromASavedLedgerAndReportsABrokenOne()
        testPluginIdentityMatchesTheOldTab()
    }

    static let home = "/tmp/systembar-tests"
    static let now = Date(timeIntervalSince1970: 100 * 86_400)

    private static func testDiskVolumeMath() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 150, isRoot: true)
        expect(volume.used == 850, "used is capacity minus free: purgeable space is still on the disk, so it counts as used")
        expect(volume.freeRatio == 0.15, "the free ratio drives the headline colour")

        // A volume reporting more free than capacity must not underflow the unsigned used value.
        let overreported = DiskVolume(name: "Odd", path: "/odd", total: 100, free: 200, isRoot: false)
        expect(overreported.used == 0, "used clamps to zero rather than underflowing")
    }

    private static func testLocalSnapshotParsing() {
        let sample = """
        Snapshots for volume group containing disk /:
        com.apple.os.update-38264256808F4A6EF35A2D2DE2F5838AC3E1B0F65
        com.apple.TimeMachine.2026-07-17-084500.local
        """
        expect(DiskCollector.parseLocalSnapshotCount(sample) == 2, "snapshot parser should count entries and drop the header")
        expect(DiskCollector.parseLocalSnapshotCount("") == 0, "snapshot parser should tolerate empty output")
    }

    private static func testSnapshotCountRunsTmutilThroughTheHost() {
        let recorder = LogRecorder()
        let answers = ["/usr/bin/tmutil listlocalsnapshots /": "Snapshots for disk /:\ncom.apple.TimeMachine.1.local\ncom.apple.os.update-2\n"]
        let collector = DiskCollector(host: makeHost(runner: recordingRunner(recorder, answers: answers)))
        expect(collector.collectLocalSnapshotCount() == 2, "both Time Machine and OS-update snapshots count")
        expect(recorder.messages == ["/usr/bin/tmutil listlocalsnapshots /"], "tmutil runs through the host by explicit path, got \(recorder.messages)")

        let failing = DiskCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.collectLocalSnapshotCount() == 0, "a tmutil that fails counts no snapshots rather than guessing")
    }

    private static func testSnapshotAppliesAReadingAndALedger() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 150, isRoot: true)
        let read = DiskSnapshot().applying(DiskVolumeReading(volumes: [volume], localSnapshotCount: 3, sampledAt: now))
        expect(read.boot?.path == "/" && read.localSnapshotCount == 3, "a volume reading fills the volumes and the snapshot count")
        expect(read.status == "Disk sample OK" && read.health == .ok && read.lastUpdated == now, "a reading with volumes is healthy and dated, got \(read.status)")

        let empty = DiskSnapshot().applying(DiskVolumeReading(volumes: [], localSnapshotCount: 0, sampledAt: now))
        expect(empty.status == "No readable volumes found" && empty.health == .degraded, "no readable volume says so and is degraded, got \(empty.status)")

        let ledger = DiskLedger().appending([
            DiskSample(path: "\(home)/proj", bytes: 10, measuredAt: now.addingTimeInterval(-2 * 86_400), plan: .overview),
            DiskSample(path: "\(home)/proj", bytes: 40, measuredAt: now.addingTimeInterval(-3600), plan: .overview),
            DiskSample(path: "\(home)/Library", bytes: 90, measuredAt: now.addingTimeInterval(-7200), plan: .overview),
        ])
        let mapped = read.applying(ledger: ledger, homeDirectory: home, now: now)
        expect(mapped.biggest.map(\.name) == ["Library", "proj"], "the ledger becomes ranked rows, got \(mapped.biggest.map(\.name))")
        expect(mapped.movers24h.map(\.row.name) == ["proj"] && mapped.movers24h.first?.change == .grew(30), "and movers over a day, got \(mapped.movers24h)")
        expect(mapped.movers7d.first?.change == .grew(30), "and over a week")
        expect(mapped.planAges[.overview] == now.addingTimeInterval(-3600) && mapped.planAges[.developer] == nil, "each plan's newest sample is its age; a plan that never ran has none")
        expect(mapped.volumes.count == 1 && mapped.localSnapshotCount == 3, "applying a ledger leaves the volume reading alone")

        let scanning = mapped.scanning(true, status: "Measuring overview folders")
        expect(scanning.isScanning && scanning.scanStatus == "Measuring overview folders", "the scan state is its own, got \(scanning.scanStatus)")
        expect(scanning.biggest == mapped.biggest, "and leaves the rows alone")
    }

    private static func testSamplingIntervalsKeepScansRare() {
        expect(DiskSampling.refreshInterval == 30, "volumes every 30 s while showing")
        expect(DiskSampling.backgroundInterval == 900 && DiskSampling.backgroundInterval >= 5 && DiskSampling.backgroundInterval <= 86_400, "a 15-minute due check while hidden, inside the scheduler's clamp")
        for plan in DiskScanPlan.all {
            expect(plan.cadence >= 3 * 3600, "\(plan.kind) runs at most every three hours, got \(plan.cadence)")
            expect(plan.budget < plan.cadence && plan.budget > DiskSampling.rowTimeout, "\(plan.kind)'s budget fits inside its cadence and outlasts one row's timeout")
        }
    }

    private static func testBackgroundScansSettingDefaultsOnAndReportsAWrongType() {
        let on = DiskPlugin.backgroundScansSetting(.empty)
        expect(on.isEnabled && on.problem == nil, "no setting means background scans run")
        let off = DiskPlugin.backgroundScansSetting(PluginSettings(values: ["backgroundScans": .bool(false)]))
        expect(!off.isEnabled && off.problem == nil, "false turns them off")
        let wrong = DiskPlugin.backgroundScansSetting(PluginSettings(values: ["backgroundScans": .string("no")]))
        expect(wrong.isEnabled && wrong.problem == "settings: \"backgroundScans\" must be true or false; background scans stay on", "a wrong type keeps the default and says so, got \(String(describing: wrong.problem))")
    }

    private static func testPluginDeclaresABackgroundIntervalUnlessTurnedOff() {
        let on = DiskPlugin(host: makeHost(dataDirectory: temporaryDirectory()))
        expect(on.backgroundInterval == DiskSampling.backgroundInterval, "by default the host should call collect() every 15 minutes while the tab is hidden")
        let off = DiskPlugin(host: makeHost(settings: PluginSettings(values: ["backgroundScans": .bool(false)]), dataDirectory: temporaryDirectory()))
        expect(off.backgroundInterval == nil, "turned off, the plugin asks for nothing while hidden")
        let wrong = DiskPlugin(host: makeHost(settings: PluginSettings(values: ["backgroundScans": .number(1)]), dataDirectory: temporaryDirectory()))
        expect(wrong.snapshot.settingsProblem?.contains("backgroundScans") == true, "a bad value is on the snapshot for the panel to show")
    }

    /// A plugin over a fake tree: home has two folders, one plan measures them.
    private static func makePlugin(dataDirectory: URL, recorder: LogRecorder, extraAnswers: [String: String] = [:]) -> DiskPlugin {
        var answers = [
            "/usr/bin/tmutil listlocalsnapshots /": "Snapshots for disk /:\ncom.apple.TimeMachine.1.local\n",
            "/usr/bin/du -s -k -x \(home)/big": "100\t\(home)/big\n",
            "/usr/bin/du -s -k -x \(home)/small": "1\t\(home)/small\n",
        ]
        answers.merge(extraAnswers) { _, new in new }
        let plan = DiskScanPlan(kind: .overview, cadence: 3600, budget: 60, roots: [""])
        return DiskPlugin(
            host: makeHost(runner: recordingRunner(recorder, answers: answers), dataDirectory: dataDirectory),
            plans: [plan],
            now: { Date() },
            listChildren: { parent in parent == home ? ["\(home)/big", "\(home)/small"] : [] }
        )
    }

    private static func testCollectRunsDuePlansOnceAndSavesTheLedger() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LogRecorder()
        let plugin = makePlugin(dataDirectory: directory, recorder: recorder)
        let duCount: () -> Int = { recorder.messages.filter { $0.hasPrefix("/usr/bin/du ") }.count }

        plugin.collect()
        waitUntil(5) { plugin.snapshot.biggest.count == 2 && !plugin.snapshot.isScanning && plugin.snapshot.lastUpdated != nil }
        expect(plugin.snapshot.boot != nil && plugin.snapshot.localSnapshotCount == 1, "collect reads the volumes and the snapshot count")
        expect(plugin.snapshot.biggest.map(\.name) == ["big", "small"], "a fresh plugin's first collect finds the plan due, measures, and publishes rows, got \(plugin.snapshot.biggest.map(\.name))")
        expect(plugin.snapshot.biggest.first?.bytes == 100 * 1024, "in bytes")
        expect(plugin.snapshot.scanStatus == "Overview: Measured 2 paths", "the footer says what the scan did, got \(plugin.snapshot.scanStatus)")
        expect(duCount() == 2, "one du per folder, got \(recorder.messages)")
        expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disk-ledger.json").path), "the ledger is saved in the plugin's data folder")
        expect(recorder.messages.allSatisfy { $0.hasPrefix("/usr/bin/tmutil ") || $0.hasPrefix("/usr/bin/du -s -k -x ") }, "every command goes through the host by explicit path, got \(recorder.messages)")

        plugin.collect()
        waitUntil(2) { plugin.snapshot.localSnapshotCount == 1 }
        spinRunLoop(for: 0.2)
        expect(duCount() == 2, "a second collect finds nothing due and runs no du, got \(duCount())")

        plugin.requestScan(force: true)
        waitUntil(5) { duCount() == 4 }
        expect(duCount() == 4, "the rescan button forces every plan, got \(duCount())")
    }

    private static func testPluginStartsFromASavedLedgerAndReportsABrokenOne() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskLedgerStore.standard(dataDirectory: directory)
        try? store.save(DiskLedger().appending([DiskSample(path: "\(home)/saved", bytes: 7 * 1024, measuredAt: Date(), plan: .overview)]))
        let recorder = LogRecorder()
        let plugin = makePlugin(dataDirectory: directory, recorder: recorder)
        plugin.collect()
        waitUntil(5) { plugin.snapshot.biggest.contains { $0.name == "saved" } }
        expect(plugin.snapshot.biggest.contains { $0.name == "saved" }, "the saved ledger shows before any scan, got \(plugin.snapshot.biggest.map(\.name))")
        expect(recorder.messages.filter { $0.hasPrefix("/usr/bin/du ") }.isEmpty, "and a plan measured a moment ago is not due, got \(recorder.messages)")

        let brokenDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: brokenDirectory) }
        try? Data("{".utf8).write(to: brokenDirectory.appendingPathComponent(DiskLedgerStore.fileName))
        let fresh = makePlugin(dataDirectory: brokenDirectory, recorder: LogRecorder())
        fresh.collect()
        waitUntil(5) { fresh.snapshot.ledgerNote != nil }
        expect(fresh.snapshot.ledgerNote?.contains(".broken") == true, "a ledger that will not parse is moved aside and the panel is told, got \(String(describing: fresh.snapshot.ledgerNote))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = DiskPlugin(host: makeHost(dataDirectory: temporaryDirectory()))
        expect(DiskPlugin.identifier == "disk" && plugin.title == "Disk" && plugin.systemImage == "internaldrive", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.cyan, "and its accent")
        expect(plugin.refreshInterval == 30 && plugin.sharedFeeds.isEmpty, "and its interval, and it needs no shared feed")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile errors in DiskTests (`backgroundScansSetting`, `applying(ledger:...)`, `requestScan`, the four-argument init).

- [ ] **Step 3: Replace the snapshot and delete the hog models**

In `DiskModels.swift`, delete `DiskHog`, `DiskHogCandidate`, `DiskHogUpdate`, and the whole `extension DiskSnapshot` at the bottom. Replace `DiskSnapshot` with:

```swift
/// Everything the panel draws. Volume fields come from each 30-second reading; the row fields
/// are derived from the ledger whenever it changes; the scan fields say what is running now.
struct DiskSnapshot {
    var volumes: [DiskVolume] = []
    var localSnapshotCount = 0
    var status = "Waiting for disk sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?

    /// Every measured path at its deepest level, from `DiskRows.rows`.
    var rows: [DiskRow] = []
    var biggest: [DiskRow] = []
    var movers24h: [DiskMover] = []
    var movers7d: [DiskMover] = []
    var simulators: [DiskRow] = []
    /// When each plan last measured anything; absent for a plan that never ran.
    var planAges: [DiskPlanKind: Date] = [:]

    var isScanning = false
    var scanStatus = "No scan yet"
    /// Something the person should know about the ledger file, such as it being moved aside.
    var ledgerNote: String?
    /// A settings value the plugin could not use, worded for the footer.
    var settingsProblem: String?

    var boot: DiskVolume? {
        volumes.first(where: \.isRoot)
    }

    var otherVolumes: [DiskVolume] {
        volumes.filter { !$0.isRoot }
    }

    /// A copy with a volume reading applied; everything else is left alone.
    func applying(_ reading: DiskVolumeReading) -> DiskSnapshot {
        var next = self
        next.volumes = reading.volumes
        next.localSnapshotCount = reading.localSnapshotCount
        next.status = reading.status
        next.health = reading.health
        next.lastUpdated = reading.sampledAt
        return next
    }

    /// A copy with the rows derived from `ledger`; the volume and scan fields are left alone.
    func applying(ledger: DiskLedger, homeDirectory: String, now: Date) -> DiskSnapshot {
        var next = self
        let rows = DiskRows.rows(from: ledger, homeDirectory: homeDirectory)
        next.rows = rows
        next.biggest = DiskRows.biggest(rows)
        next.movers24h = DiskRows.movers(rows: rows, ledger: ledger, window: 86_400, now: now)
        next.movers7d = DiskRows.movers(rows: rows, ledger: ledger, window: 7 * 86_400, now: now)
        next.simulators = DiskRows.simulatorRows(from: ledger)
        next.planAges = Dictionary(uniqueKeysWithValues: DiskPlanKind.allCases.compactMap { kind in
            ledger.newestMeasurement(of: kind).map { (kind, $0) }
        })
        return next
    }

    func scanning(_ isScanning: Bool, status: String) -> DiskSnapshot {
        var next = self
        next.isScanning = isScanning
        next.scanStatus = status
        return next
    }

    func noting(_ note: String) -> DiskSnapshot {
        var next = self
        next.ledgerNote = note
        return next
    }
}
```

Keep `DiskVolume`, `DiskSampling` and `DiskVolumeReading` as they are.

- [ ] **Step 4: Trim the collector**

Replace `Plugins/Disk/Sources/DiskCollector.swift` entirely:

```swift
import Foundation
import SystemBarKit

/// The Disk tab's cheap 30-second reading: the mounted volumes and the local snapshot count.
/// Runs on the plugin's queue. The folder scans live in `DiskScanner`.
final class DiskCollector: @unchecked Sendable {
    private let host: HostServices

    init(host: HostServices) {
        self.host = host
    }

    func readVolumes() -> DiskVolumeReading {
        DiskVolumeReading(volumes: Self.collectDiskVolumes(), localSnapshotCount: collectLocalSnapshotCount(), sampledAt: Date())
    }

    static func collectDiskVolumes() -> [DiskVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey
        ]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let rootURL = URL(fileURLWithPath: "/")
        let candidates = mounted.contains(where: { $0.path == "/" }) ? mounted : [rootURL] + mounted

        return candidates.compactMap { url -> DiskVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.volumeIsBrowsable != false else { return nil }
            guard let total = values.volumeTotalCapacity, total > 0 else { return nil }

            let free = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))

            return DiskVolume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: free,
                isRoot: url.path == "/"
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.total > rhs.total
        }
    }

    func collectLocalSnapshotCount() -> Int {
        let result = host.run(path: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
        guard result.status == 0 else { return 0 }
        return Self.parseLocalSnapshotCount(result.output)
    }

    /// Output is a header line followed by one identifier per snapshot. Both Time Machine and
    /// OS-update snapshots hold real space, so every entry counts, not just the TM ones.
    static func parseLocalSnapshotCount(_ output: String) -> Int {
        output
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("com.apple.") }
            .count
    }
}
```

- [ ] **Step 5: Rewrite the plugin**

Replace `Plugins/Disk/Sources/DiskPlugin.swift` entirely:

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Disk tab as a bundle. The host calls `collect()` every 30 s while the tab shows and, unless
/// settings turn it off, every 15 minutes while it is hidden. Each call reads the volumes on the
/// plugin's queue, then asks the scan queue to run whichever plans are due. The scan queue is the
/// plugin's own and serial: it alone touches the ledger, a plan can run for minutes without
/// holding up a volume read, and the panel's rescan button queues a forced run behind whatever
/// is going. Everything publishes on main, and the panel observes `snapshot`.
@objc(SystemBarDiskPlugin)
public final class DiskPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "disk"
    public let title = "Disk"
    public let systemImage = "internaldrive"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = DiskSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = []
    /// 15 minutes, or nil when `backgroundScans` is false in this tab's settings: the host then
    /// never calls `collect()` while the tab is hidden, and scans run only on the button and
    /// while the tab shows.
    public let backgroundInterval: TimeInterval?

    static let backgroundScansKey = "backgroundScans"

    @Published private(set) var snapshot = DiskSnapshot()

    private let host: HostServices
    private let collector: DiskCollector
    private let scanner: DiskScanner
    private let store: DiskLedgerStore
    private let plans: [DiskScanPlan]
    private let now: () -> Date
    private let scanQueue = DispatchQueue(label: "systembar.disk.scan", qos: .utility)
    /// Touched only on `scanQueue`.
    private var ledger = DiskLedger()
    private var isLedgerLoaded = false

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, plans: DiskScanPlan.all, now: { Date() }, listChildren: DiskScanner.subfolders)
    }

    /// The plans, clock and folder listing are parameters so a test can run a tiny plan over a
    /// fake tree in no time; the app uses `init(host:)`.
    @MainActor init(host: HostServices, plans: [DiskScanPlan], now: @escaping () -> Date, listChildren: @escaping (String) -> [String]) {
        self.host = host
        collector = DiskCollector(host: host)
        scanner = DiskScanner(host: host, listChildren: listChildren)
        store = DiskLedgerStore.standard(dataDirectory: host.dataDirectory)
        self.plans = plans
        self.now = now
        let setting = Self.backgroundScansSetting(host.settings)
        backgroundInterval = setting.isEnabled ? DiskSampling.backgroundInterval : nil
        var initial = DiskSnapshot()
        initial.settingsProblem = setting.problem
        snapshot = initial
        super.init()
    }

    /// `backgroundScans`: absent or true means on; false means off; anything else keeps the
    /// default and is reported, because a misspelt value must never silently do nothing.
    static func backgroundScansSetting(_ settings: PluginSettings) -> (isEnabled: Bool, problem: String?) {
        if let flag = settings.bool(forKey: backgroundScansKey) { return (flag, nil) }
        if settings[backgroundScansKey] != nil {
            return (true, "settings: \"\(backgroundScansKey)\" must be true or false; background scans stay on")
        }
        return (true, nil)
    }

    public func collect() {
        let reading = collector.readVolumes()
        publish { $0.applying(reading) }
        requestScan(force: false)
    }

    /// The panel's rescan button passes `force: true`; every collect asks without forcing. Runs
    /// behind any scan already going, which then finds nothing due unless forced.
    func requestScan(force: Bool) {
        scanQueue.async { [self] in
            loadLedgerIfNeeded()
            runDuePlans(force: force)
        }
    }

    // MARK: - Scan queue

    private func loadLedgerIfNeeded() {
        guard !isLedgerLoaded else { return }
        isLedgerLoaded = true
        switch store.load() {
        case .fresh:
            break
        case .loaded(let saved):
            ledger = saved
        case let .movedAside(to, reason):
            host.log("SystemBar Disk: the saved ledger could not be read (\(reason)); moved to \(to)")
            publish { $0.noting("Saved sizes could not be read (\(reason)); the file was moved to \(to) and a fresh one started") }
        }
        publishLedger()
    }

    private func runDuePlans(force: Bool) {
        let due = plans.filter { force || ledger.isDue($0.kind, cadence: $0.cadence, now: now()) }
        guard !due.isEmpty else { return }
        for plan in due {
            publish { $0.scanning(true, status: "Measuring \(plan.kind.title.lowercased()) folders") }
            var fresh: [DiskSample] = []
            let outcome = scanner.run(plan: plan, previous: ledger) { sample in
                // Each tree lands in the list as it finishes rather than after the last one.
                fresh.append(sample)
                let preview = ledger.appending(fresh)
                publish { $0.applying(ledger: preview, homeDirectory: host.homeDirectory, now: now()) }
            }
            ledger = ledger.appending(fresh).compacted(now: now())
            save()
            publish { $0.scanning(false, status: "\(plan.kind.title): \(outcome.status)") }
            publishLedger()
        }
    }

    private func save() {
        do {
            try store.save(ledger)
        } catch {
            host.log("SystemBar Disk: could not save the ledger to \(store.fileURL.path): \(error.localizedDescription)")
            publish { $0.noting("Sizes could not be saved to \(store.fileURL.path): \(error.localizedDescription)") }
        }
    }

    private func publishLedger() {
        let ledger = self.ledger
        publish { $0.applying(ledger: ledger, homeDirectory: host.homeDirectory, now: now()) }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(DiskPanel(plugin: self))
    }

    /// Readings arrive on the plugin's queue and on the scan queue; the panel observes from main.
    private func publish(_ change: @escaping (DiskSnapshot) -> DiskSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = change(self.snapshot)
        }
    }
}
```

- [ ] **Step 6: Make the panel compile**

In `DiskPanel.swift`, so the build passes until Task 11 rewrites the file: delete the `StatPill(label: "Cleanup", ...)` line; replace the right column's `ScrollView { LazyVStack { ForEach(plugin.snapshot.hogs) ... } }` with `ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(plugin.snapshot.biggest) { row in EvidenceRow(label: row.name, value: byteString(row.bytes), detail: row.path) } } }`; delete the `DiskHogRow` struct; change `hogFooterText` to return `plugin.snapshot.scanStatus`; change `plugin.scanHogs(force: true)` to `plugin.requestScan(force: true)` and `plugin.snapshot.isScanningHogs` (both uses) to `plugin.snapshot.isScanning`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`, and the name check still passes (none of the deleted names were on its list).

- [ ] **Step 8: Commit**

```bash
git add Plugins/Disk
git commit -m "Disk: the plugin keeps a ledger, runs due scan plans on its own queue, and honours backgroundScans

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: panel rewrite (ifd.11)

**Files:**
- Rewrite: `Plugins/Disk/Sources/DiskPanel.swift`
- Create: `Plugins/Disk/Sources/DiskRowViews.swift`

There are no pixel tests; the row models are tested in Task 6. This task is verified by building and by opening the app.

- [ ] **Step 1: Write the panel**

Replace `Plugins/Disk/Sources/DiskPanel.swift` entirely:

```swift
import AppKit
import Foundation
import SwiftUI
import SystemBarKit

enum DiskListMode: String, CaseIterable, Identifiable {
    case biggest = "Biggest"
    case movers = "Movers"
    var id: String { rawValue }
}

enum DiskMoverWindow: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    var id: String { rawValue }
}

struct DiskPanel: View {
    @ObservedObject var plugin: DiskPlugin
    @State private var mode = DiskListMode.biggest
    @State private var window = DiskMoverWindow.day
    @State private var showsSimulators = false

    private var snapshot: DiskSnapshot { plugin.snapshot }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .padding(18)
                .frame(width: 430)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider().background(Color.white.opacity(0.08))

            rightColumn
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Left: capacity and distribution

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headlineText)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(headlineColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 10) {
                StatPill(label: "Snapshots", value: "\(snapshot.localSnapshotCount)")
                if let boot = snapshot.boot {
                    StatPill(label: "Used", value: byteString(boot.used))
                    StatPill(label: "Capacity", value: byteString(boot.total))
                }
            }

            if let boot = snapshot.boot {
                SegmentedBar(segments: capacityRows(for: boot).filter { $0.value > 0 }, total: boot.total)
                    .frame(height: 34)
                SegmentedLegend(rows: capacityRows(for: boot))

                SectionTitle("Where the space is")
                let distribution = DiskRows.distribution(biggest: snapshot.biggest, volume: boot, homeDirectory: plugin.homeDirectory)
                SegmentedBar(segments: distribution.filter { $0.value > 0 }, total: boot.total)
                    .frame(height: 20)
                SegmentedLegend(rows: distribution)
            }

            if !snapshot.otherVolumes.isEmpty {
                SectionTitle("Other Volumes")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.otherVolumes) { volume in
                            EvidenceRow(
                                label: volume.name,
                                value: "\(byteString(volume.free)) free",
                                detail: "\(byteString(volume.used)) used of \(byteString(volume.total))"
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text(snapshot.status)
                .font(.caption)
                .foregroundStyle(snapshot.health == .ok ? .secondary : Palette.warning)
        }
    }

    private var headlineText: String {
        guard let boot = snapshot.boot else { return "Reading volumes" }
        return "\(byteString(boot.free)) Free"
    }

    private var headlineColor: Color {
        guard let boot = snapshot.boot else { return .secondary }
        if boot.freeRatio > 0.20 { return Palette.good }
        if boot.freeRatio > 0.10 { return Palette.caution }
        return Palette.critical
    }

    // MARK: - Right: biggest and movers

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle("Where it goes")
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(DiskListMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                if mode == .movers {
                    Picker("Window", selection: $window) {
                        ForEach(DiskMoverWindow.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                }
            }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        switch mode {
                        case .biggest:
                            biggestRows(now: context.date)
                        case .movers:
                            moverRows(now: context.date)
                        }
                    }
                }
            }

            footer
        }
    }

    @ViewBuilder
    private func biggestRows(now: Date) -> some View {
        let rows = snapshot.biggest
        let top = rows.first?.bytes ?? 1
        if rows.isEmpty {
            Text(snapshot.isScanning ? "Measuring…" : "No folders measured yet. Press rescan, or wait for the first background scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            DiskRowView(row: row, fraction: Double(row.bytes) / Double(max(top, 1)), change: nil, now: now, homeDirectory: plugin.homeDirectory)
                .onTapGesture { if row.kind == .simulatorGroup { showsSimulators.toggle() } }
            if row.kind == .simulatorGroup, showsSimulators {
                ForEach(snapshot.simulators) { device in
                    DiskRowView(row: device, fraction: Double(device.bytes) / Double(max(row.bytes, 1)), change: nil, now: now, homeDirectory: plugin.homeDirectory)
                        .padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder
    private func moverRows(now: Date) -> some View {
        let movers = window == .day ? snapshot.movers24h : snapshot.movers7d
        let top = movers.first?.magnitude ?? 1
        if movers.isEmpty {
            Text("Nothing changed in the last \(window.rawValue), or there is no earlier scan to compare with yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(movers) { mover in
            DiskRowView(row: mover.row, fraction: Double(mover.magnitude) / Double(max(top, 1)), change: mover.change, now: now, homeDirectory: plugin.homeDirectory)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(footerText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(snapshot.settingsProblem == nil && snapshot.ledgerNote == nil ? .secondary : Palette.warning)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Spacer()
            Button {
                plugin.requestScan(force: true)
            } label: {
                if snapshot.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(snapshot.isScanning)
            .help("Measure every folder again now")
        }
    }

    /// Problems first, then what is running, then each plan's age.
    private func footerText(now: Date) -> String {
        if let problem = snapshot.settingsProblem { return problem }
        if let note = snapshot.ledgerNote { return note }
        if snapshot.isScanning { return snapshot.scanStatus }
        let ages = DiskPlanKind.allCases.map { kind -> String in
            guard let date = snapshot.planAges[kind] else { return "\(kind.title) never" }
            return "\(kind.title) \(relativeTimeString(date, now: now)) ago"
        }
        return ages.joined(separator: " · ")
    }
}

/// The two capacity buckets. The legend shows both even when one is zero; the bar filters those
/// out itself, since it cannot draw a zero-width segment meaningfully.
private func capacityRows(for volume: DiskVolume) -> [BarSegment] {
    [
        BarSegment(label: "Used", value: volume.used, color: Palette.blue),
        BarSegment(label: "Free", value: volume.free, color: Palette.good)
    ]
}
```

The panel reads `plugin.homeDirectory`; add to `DiskPlugin`, after `backgroundInterval`:

```swift
    /// For the panel, which shortens paths under home to `~/...`.
    var homeDirectory: String { host.homeDirectory }
```

- [ ] **Step 2: Write the row view**

Create `Plugins/Disk/Sources/DiskRowViews.swift`:

```swift
import Foundation
import SwiftUI
import SystemBarKit

/// One row of the right-hand list: name and size (or signed change), a bar relative to the top
/// row, the shortened path, and the age of the measurement. A simulator device adds its last boot.
struct DiskRowView: View {
    let row: DiskRow
    let fraction: Double
    let change: DiskMover.Change?
    let now: Date
    let homeDirectory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if row.kind == .simulatorGroup {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(valueColor)
            }
            ProgressBar(value: fraction, color: barColor)
                .frame(height: 4)
            HStack {
                Text(detailText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("measured \(relativeTimeString(row.measuredAt, now: now)) ago")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var valueText: String {
        switch change {
        case .grew(let bytes)?: return "+\(byteString(bytes)) → \(byteString(row.bytes))"
        case .shrank(let bytes)?: return "−\(byteString(bytes)) → \(byteString(row.bytes))"
        case .freed(let bytes)?: return "freed \(byteString(bytes))"
        case .new?: return "new \(byteString(row.bytes))"
        case nil: return byteString(row.bytes)
        }
    }

    private var valueColor: Color {
        switch change {
        case .grew?, .new?: return Palette.warning
        case .shrank?, .freed?: return Palette.good
        case nil: return Palette.foreground
        }
    }

    private var barColor: Color {
        switch change {
        case .grew?, .new?: return Palette.warning
        case .shrank?, .freed?: return Palette.good
        case nil: return Palette.cyan
        }
    }

    private var detailText: String {
        let path = DiskRows.displayPath(row.path, homeDirectory: homeDirectory)
        guard let simulator = row.simulator else { return path }
        guard let booted = simulator.lastBootedAt else { return "never booted · \(path)" }
        return "last booted \(relativeTimeString(booted, now: now)) ago · \(path)"
    }
}
```

- [ ] **Step 3: Build and run the tests**

Run: `./test.sh 2>&1 | tail -5`
Expected: `SystemBarPerformanceTests passed`.

- [ ] **Step 4: Look at it**

Run: `open SystemBar.app`, open the popover, choose Disk. Check: the headline reads free space; the left column has two bars and two legends; the right list is empty with the "no folders measured yet" line until the first scan, then fills as rows finish; the Movers mode shows the empty-state line on a fresh ledger; the footer shows the three plan ages; the rescan button spins while a scan runs. Quit the app when done (`osascript -e 'quit app "SystemBar"'`).

- [ ] **Step 5: Commit**

```bash
git add Plugins/Disk
git commit -m "Disk: show where the space is on the left, and the biggest folders and movers on the right

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: README, CLAUDE.md, plugin spec, memory (ifd.12)

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/one-page/systembar-tab-plugins.md` (decision log)
- Modify: `test.sh` (only if ewy.1 has landed; see Step 4)

The CPU pane (ewy.1) owns the sentence "Every command below starts only while the window is open", the feeds table's closing line, and the per-tab table's new "While hidden" column. Touch only the lines named here.

- [ ] **Step 1: README**

In the tabs table, replace the Disk row with:

```markdown
| **Disk** | Free and used space per volume, Time Machine local snapshots, a map of which folders hold the space, and what grew or shrank over the last day or week, measured by scans that run in the background and saved between launches, every number stamped with its age |
```

In "Choosing tabs", after the paragraph beginning `A "path" entry points at a bundle anywhere on disk`, add:

```markdown
An entry may carry a `"settings"` object for its plugin. The app checks only that it is an object; the keys are the plugin's own, and a plugin reports a value it cannot use in its own panel rather than refusing to load. The Disk tab reads one key: `"backgroundScans": false` stops its folder scans from running while the window is closed.

```json
{ "plugins": [
  { "name": "Disk.bundle", "settings": { "backgroundScans": false } }
] }
```
```

In the subprocess table, replace the `/usr/bin/du` row and add an `xcrun` row after it:

```markdown
| `/usr/bin/du` | Folder sizes for the Disk tab's map: one level under home, `~/Library`, `/Applications`, `/opt` and `/Library` every 3 hours; under the developer folders (`~/Library/Application Support`, `Containers`, `Group Containers`, `Developer/Xcode`, `~/.cache`, `~/.ollama`, `~/.android`, `~/proj`) and each simulator device every 6 hours | One `du` per folder, on those cadences while the Mac is awake, or all at once on the Disk tab's rescan button |
| `/usr/bin/xcrun` | `simctl list devices -j`, to name each simulator device folder and say when it last booted | Once per simulator scan, every 6 hours |
```

Replace the bullet beginning `**The disk scan reads directory sizes only.**` with:

```markdown
- **The disk scan reads folder sizes only, and remembers them.** It runs three plans: an overview of the top-level folders every 3 hours, the developer folders every 6 hours, and each iOS simulator device every 6 hours, each folder by its own `du` with a 5-minute cap and each plan capped at 15 minutes, so one huge or unreadable tree costs only its own row. It reads sizes, never file contents, and never deletes anything; the tab has no cleanup hints, only a map of where the space is and what changed. Sizes are saved in `~/Library/Application Support/SystemBar/Plugins/disk/disk-ledger.json`, every sample for two days and then one a day for thirty, so the popover shows the last scan at once with the age of every number, and the Movers list compares today with a day or a week ago. The plans run while the window is closed: the host calls the Disk tab every 15 minutes while it is hidden, waits two minutes after the Mac wakes, and the tab runs whatever is due. `"backgroundScans": false` in the tab's settings stops that; the rescan button still works. Because `~/Library/Containers` and `~/Library/Group Containers` are on the list, macOS may ask for Files and Folders permission the first time, and a folder it refuses counts as unreadable in the status line rather than as empty.
```

In the per-tab sampling table, replace the Disk row with (if ewy.1 has added a "While hidden" column, put "a due check every 15 min" in that cell instead of in the second):

```markdown
| Disk | Volumes and `tmutil` every 30s while showing; a due check every 15 min while hidden, which runs the overview scan every 3 h and the developer and simulator scans every 6 h | `DiskSampling` in `Plugins/Disk/Sources/DiskModels.swift` |
```

In "Writing a plugin", after the paragraph beginning `A plugin's `refreshInterval` is clamped`, add:

```markdown
A plugin gets two more things from `HostServices`. `settings` is its entry's `"settings"` object from `plugins.json`, as a `PluginSettings` with typed accessors (`bool(forKey:)`, `number(forKey:)`, `string(forKey:)`); a present key of the wrong type reads as nil from those and non-nil from the subscript, so the plugin can tell the person. `dataDirectory` is a folder of its own, `~/Library/Application Support/SystemBar/Plugins/<identifier>/`, which may not exist until the plugin creates it; anything a plugin saves between launches goes there and nowhere else. `SYSTEMBAR_PLUGIN_DATA_ROOT=/some/folder` moves the root for every plugin, which is how tests and scripts keep the real folder untouched.
```

- [ ] **Step 2: CLAUDE.md**

In "Architecture Overview", after the sentence ending `and keeps an error tab in the place of an entry that fails.`, add:

```markdown
Each plugin is constructed with a `HostServices` of its own (`HostServices.forPlugin`): the shared feeds and runner, plus its entry's `settings` and a `dataDirectory` under `~/Library/Application Support/SystemBar/Plugins/<id>/` (root overridable with `SYSTEMBAR_PLUGIN_DATA_ROOT`). A plugin that saves anything saves it there; the Disk tab's size ledger is the first.
```

In "Conventions & Patterns", in the sentence `Tests must never touch the real ~/Library/Application Support/SystemBar/`, append after `the tests build their own path inside a temporary folder`:

```markdown
, and `makeHost` in `TestFakes.swift` gives every plugin under test a `dataDirectory` under the temporary directory
```

- [ ] **Step 3: Plugin spec decision log**

Append to the Decision Log of `docs/one-page/systembar-tab-plugins.md`:

```markdown
- 2026-10-10 — Per-plugin `settings` (passed through plugins.json untouched, checked only to be an object) and `HostServices.dataDirectory` (one folder per identifier under Application Support/SystemBar/Plugins, root overridable) join the SDK; the catalog builds one `HostServices` per plugin. Spec: systembar-ifd. — Adam.
```

- [ ] **Step 4: test.sh, only once ewy.1 has landed**

If `grep -n 'background every' Sources/Host/PluginListReport.swift` finds the marker, change the Disk line of `expected_fresh` in `test.sh` to `ok disk Disk Disk.bundle background every 900s` (exact format from the CPU pane's report code). If it finds nothing, leave `test.sh` alone and note it in the handoff.

- [ ] **Step 5: Run everything**

Run: `./test.sh 2>&1 | tail -5`
Expected: all four lines pass. Then `grep -n 'purgeable\|Reclaimable\|reclaimable\|hog' README.md CLAUDE.md Plugins/Disk -r` should print nothing.

- [ ] **Step 6: Commit, remember, close**

```bash
git add README.md CLAUDE.md docs/one-page/systembar-tab-plugins.md test.sh
git commit -m "Document the Disk tab's scan plans and ledger, plugin settings, and the per-plugin data folder

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
bd remember "SystemBar Disk epic ifd (2026-10-10): the Disk tab is a space map plus movers over a saved ledger (Plugins/disk/disk-ledger.json), not a cleanup list; the background contract is the CPU epic's backgroundInterval, with a 2-minute wake settle agreed between the two panes; plugins get settings and a dataDirectory through a per-plugin HostServices."
bd close <ifd.12 id>
```

Then report to Adam: changed files, test output, and that merging to main is the remaining step, with the commit range.

---

## Self-review notes

- **Spec coverage.** D1 (map, no hints): Tasks 10, 11, 12. D2 (cadences, wake settle, no unlock): Task 5 constants, Task 10 due rule, settle owned by ewy.1. D3 (tiered roots, per-device simulators, budgets, biggest-first): Task 8. D4 (ledger, retention, atomic store, `.broken`): Tasks 5, 7, 10. D5 (panel, purgeable removed, remainders, limits): Tasks 4, 6, 11. D6 (settings, data folder; background adopts ewy): Tasks 1, 2, 3, 10. D7 (README): Task 12. Measurement contract: `du -s -k -x`, `simctl`, `tmutil`, ages on every row, movers nil-not-zero: Tasks 6, 9, 10, 11. Expected outcomes are checked by hand in Task 11 Step 4 on the author's Mac.
- **Type consistency.** `DiskSample(path:bytes:measuredAt:plan:simulator:)`, `DiskLedger.appending/latest/sample(of:atOrBefore:)/newestMeasurement(of:)/isDue(_:cadence:now:)/compacted(now:full:daily:)`, `DiskRow(name:path:bytes:measuredAt:kind:simulator:)`, `DiskRows.rows(from:homeDirectory:)/simulatorRows(from:)/biggest(_:limit:)/movers(rows:ledger:window:now:limit:)/distribution(biggest:volume:homeDirectory:limit:)/displayPath(_:homeDirectory:)`, `DiskScanPlan(kind:cadence:budget:roots:)`, `DiskScanTargets.targets(for:homeDirectory:previous:listChildren:catalog:)/vanished(plan:homeDirectory:previous:targets:now:)`, `DiskScanner(host:listChildren:)/run(plan:previous:onRow:)/measure(targets:plan:now:elapsed:measure:onRow:)`, `DiskScanOutcome(measured:timedOut:unreadable:unmeasured:)`, `DiskLedgerStore(fileURL:)/standard(dataDirectory:)/load()/save(_:)`, `DiskPlugin(host:plans:now:listChildren:)/requestScan(force:)/backgroundScansSetting(_:)`, `DiskSnapshot.applying(_:)/applying(ledger:homeDirectory:now:)/scanning(_:status:)/noting(_:)` are used with the same shapes throughout.
- **Known seams.** `TabCatalog.build` and `TabLoader.load` default `dataRoot` to the real Application Support path; nothing is created there unless a plugin writes, and every plugin under test gets a temporary folder through `makeHost`. `DiskPlugin.backgroundInterval` is a stored property that becomes a protocol witness when ewy.1 lands; until then the host ignores it.
