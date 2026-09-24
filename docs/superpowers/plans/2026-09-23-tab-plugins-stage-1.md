# Tab Plugins, Stage 1: Config and Tab Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tab bar is driven by `~/Library/Application Support/SystemBar/plugins.json`: tabs appear in list order, can be disabled, and a bad entry shows as an error tab, while the six tabs still compile into the app and register through the `TabPlugin` contract.

**Architecture:** A new `Sources/Kit/` directory holds the plugin contract (`TabPlugin`, `SharedFeed`, `HostServices`) and the subprocess runner; `Sources/Host/` holds the config file model, its parser and store, the catalog that turns entries into loaded tabs or failures, six thin adapters that wrap today's `UnifiedMonitor`-backed panels, and a relauncher. `RootView` iterates the loaded tabs instead of switching over `MonitorMode`. Everything still builds into one binary with the unchanged `build.sh`; the dylib, bundles and loader are Stage 2 (see `docs/one-page/systembar-tab-plugins.md`).

**Tech Stack:** Swift 5, SwiftUI, Foundation `JSONSerialization`, `swiftc` via `build.sh`, in-process test binary via `test.sh` (`expect` helper in `TestSupport.swift`).

**Spec:** `docs/one-page/systembar-tab-plugins.md`. Stages 2 and 3 get their own plans when this one lands.

---

## File map

Created:
- `Sources/Kit/TabPlugin.swift` — the `TabPlugin` protocol and `SharedFeed`
- `Sources/Kit/HostServices.swift` — what the host hands each plugin
- `Sources/Kit/ProcessRunner.swift` — moved from `Sources/UnifiedMonitor+ProcessRunner.swift`, gains `environment`
- `Sources/Host/PluginConfig.swift` — `PluginEntry`, `PluginConfig`, `PluginConfigError`
- `Sources/Host/PluginConfigParser.swift` — JSON in and out, strict about keys
- `Sources/Host/PluginConfigStore.swift` — where the file lives, first write, read
- `Sources/Host/TabCatalog.swift` — `LoadedTab`, `TabSource`, `TabLoadError`, `TabCatalog`
- `Sources/Host/PluginListReport.swift` — the `--list-plugins` lines
- `Sources/Host/BuiltinTabs.swift` — `MonitorBackedTab`, `BuiltinTabSource`, six adapters
- `Sources/Host/Relauncher.swift` — the Relaunch button's logic
- `Sources/Views/ConfigStatusViews.swift` — `ErrorTabView`, `NoTabsView`
- `SystemBarPluginTests.swift` — every test in this plan

Modified:
- `Sources/UnifiedMonitor+ProcessRunner.swift` — becomes a forwarder to `ProcessRunner.run`
- `Sources/UnifiedMonitor.swift` — gains `static let shared`
- `Sources/Views/RootView.swift` — rewritten around `[LoadedTab]`
- `Sources/App.swift` — reads the config, handles `--list-plugins`
- `SystemBarPerformanceTests.swift` — calls `SystemBarPluginTests.runAll()`
- `test.sh` — compiles the new test file
- `README.md`, `AGENTS.md`, `CLAUDE.md` — describe `plugins.json` and the new directories

One deliberate behaviour change: the tab that opens is the first listed one. Today it is Memory regardless of position; after this it is whatever `plugins.json` lists first, which for a fresh file is Power. Reordering the file is the fix if you want Memory back.

---

### Task 1: The plugin contract

**Files:**
- Create: `Sources/Kit/TabPlugin.swift`
- Create: `Sources/Kit/HostServices.swift`
- Create: `SystemBarPluginTests.swift`
- Modify: `SystemBarPerformanceTests.swift:5-42`
- Modify: `test.sh`

- [ ] **Step 1: Register the new test file**

In `test.sh`, add the new file after `SystemBarCapacityTests.swift`:

```zsh
  TestSupport.swift \
  SystemBarCapacityTests.swift \
  SystemBarPluginTests.swift \
  SystemBarPerformanceTests.swift
```

In `SystemBarPerformanceTests.swift`, add one line before `print("SystemBarPerformanceTests passed")`:

```swift
        SystemBarCapacityTests.runAll()
        SystemBarPluginTests.runAll()
        print("SystemBarPerformanceTests passed")
```

- [ ] **Step 2: Write the failing tests**

Create `SystemBarPluginTests.swift`:

```swift
import Foundation
import SwiftUI

/// Tests for the plugin model: the contract a tab conforms to, the config file that lists tabs,
/// and the catalog that turns that file into loaded tabs or visible failures.
struct SystemBarPluginTests {
    static func runAll() {
        testPluginIsConstructedThroughItsMetatype()
        testHostServicesForwardsToTheRunner()
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
        expect(true, "visibilityChanged has a default implementation, so a plugin need not write one")
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
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile errors naming `TabPlugin`, `HostServices` and `CommandRunner` as undefined.

- [ ] **Step 4: Write the contract**

Create `Sources/Kit/TabPlugin.swift`:

```swift
import Foundation
import SwiftUI

/// A shared sampler the host runs on a plugin's behalf while that plugin's tab is showing.
/// Declaring one is what starts it; nothing starts by being read.
public enum SharedFeed: Hashable {
    /// The 10-second `ps` summary: top processes by CPU and by memory, and counts.
    case processes
    /// The 1-second CPU and network counters and their histories.
    case fastStats
}

/// One tab. The host creates a plugin once at launch, calls `collect()` on the plugin's own
/// queue only while its tab is on screen, and embeds `makeView()` in the window.
public protocol TabPlugin: AnyObject {
    /// Stable, unique, lowercase. Two loaded plugins sharing one is an error the host shows.
    static var identifier: String { get }
    var title: String { get }
    var systemImage: String { get }
    var accent: Color { get }
    /// How often the host calls `collect()` while this tab is showing.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must run while this tab is showing.
    var sharedFeeds: Set<SharedFeed> { get }

    init(host: HostServices)
    /// Runs on this plugin's own queue, never concurrently with itself, only while visible.
    func collect()
    /// Main thread, when the tab is switched to or away from.
    func visibilityChanged(isVisible: Bool)
    /// Main thread. The panel observes the plugin's own model objects.
    func makeView() -> AnyView
}

public extension TabPlugin {
    func visibilityChanged(isVisible: Bool) {}
}
```

Create `Sources/Kit/HostServices.swift`:

```swift
import Foundation

/// Runs one executable with an argument array and returns what it printed. Never a shell.
public typealias CommandRunner = (
    _ path: String, _ arguments: [String], _ environment: [String: String]?, _ timeout: TimeInterval
) -> CommandOutput

/// What the host hands every plugin at construction. A plugin keeps it for its lifetime.
public final class HostServices {
    public let homeDirectory: String
    private let runner: CommandRunner
    private let logger: (String) -> Void

    public init(homeDirectory: String, runner: @escaping CommandRunner, log: @escaping (String) -> Void) {
        self.homeDirectory = homeDirectory
        self.runner = runner
        self.logger = log
    }

    /// The only way built-in plugins run a subprocess: explicit path, argument array, no shell.
    /// `environment` exists because an app started by launchd has almost no PATH; a plugin that
    /// runs a `#!/usr/bin/env node` script has to say where node is.
    public func run(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 15
    ) -> CommandOutput {
        runner(path, arguments, environment, timeout)
    }

    public func log(_ message: String) {
        logger(message)
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/Kit/TabPlugin.swift Sources/Kit/HostServices.swift SystemBarPluginTests.swift SystemBarPerformanceTests.swift test.sh
git commit -m "$(cat <<'MSG'
Add the TabPlugin contract every tab will conform to

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: Move the subprocess runner into the Kit and let it set the environment

**Files:**
- Create: `Sources/Kit/ProcessRunner.swift` (via `git mv` from `Sources/UnifiedMonitor+ProcessRunner.swift`)
- Create: `Sources/UnifiedMonitor+ProcessRunner.swift` (new, short forwarder)
- Modify: `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()` in `SystemBarPluginTests.swift`:

```swift
        testRunnerPassesAnExplicitEnvironment()
        testRunnerInheritsTheEnvironmentByDefault()
```

Add the tests under a new `// MARK: - Runner` section:

```swift
    // MARK: - Runner

    private static func testRunnerPassesAnExplicitEnvironment() {
        let output = ProcessRunner.run(path: "/usr/bin/env", arguments: [], environment: ["SYSTEMBAR_TEST": "yes"])
        expect(output.status == 0, "env should exit cleanly")
        expect(output.output.trimmingCharacters(in: .whitespacesAndNewlines) == "SYSTEMBAR_TEST=yes",
               "an explicit environment replaces the inherited one entirely, got: \(output.output)")
    }

    private static func testRunnerInheritsTheEnvironmentByDefault() {
        let output = ProcessRunner.run(path: "/usr/bin/env", arguments: [])
        expect(output.output.contains("HOME="), "with no environment given, the child inherits this process's")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `ProcessRunner` undefined.

- [ ] **Step 3: Move the file and rename its owner**

```bash
git mv Sources/UnifiedMonitor+ProcessRunner.swift Sources/Kit/ProcessRunner.swift
```

Edit `Sources/Kit/ProcessRunner.swift`. Replace the first lines through the `process.arguments = arguments` line so the file starts:

```swift
import Darwin
import Foundation

/// Launches one executable with an argument array and captures what it printed. Never a shell:
/// this app reads process and network state, so interpolation would be a real hazard.
public enum ProcessRunner {
    public static func run(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 15
    ) -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
```

The rest of the function body is unchanged. Then make the two remaining declarations in the file public: `private static func attachDrain` stays private, and `struct CommandOutput` becomes:

```swift
public struct CommandOutput {
    public let output: String
    public let error: String
    public let status: Int32
    /// True only when the wall-clock timeout killed the child. A killed child's stdio
    /// buffer dies with it, so callers must read an empty `output` as "no answer yet",
    /// not as "the command answered nothing".
    public let didTimeout: Bool

    public init(output: String, error: String, status: Int32, didTimeout: Bool) {
        self.output = output
        self.error = error
        self.status = status
        self.didTimeout = didTimeout
    }
}
```

`PipeBuffer` stays `private final class` as it is. Remove the `import AppKit` and `import SwiftUI` lines at the top; the runner needs neither.

- [ ] **Step 4: Keep the sixteen existing call sites working**

Create a new `Sources/UnifiedMonitor+ProcessRunner.swift`:

```swift
import Foundation

extension UnifiedMonitor {
    /// The collectors still call this. It is a forwarder until each collector moves into its
    /// plugin and calls `HostServices.run` instead; it goes when the last one does.
    static func runProcess(path: String, arguments: [String], timeout: TimeInterval = 15) -> CommandOutput {
        ProcessRunner.run(path: path, arguments: arguments, timeout: timeout)
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`. The two existing runner tests (`testRunProcessDrainsLargeStderrConcurrently`, `testRunProcessTimesOutHungCommand`) still pass through the forwarder.

- [ ] **Step 6: Commit**

```bash
git add Sources/Kit/ProcessRunner.swift Sources/UnifiedMonitor+ProcessRunner.swift SystemBarPluginTests.swift
git commit -m "$(cat <<'MSG'
Move the subprocess runner into the Kit and let callers set the environment

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: The config file model and a strict parser

**Files:**
- Create: `Sources/Host/PluginConfig.swift`
- Create: `Sources/Host/PluginConfigParser.swift`
- Modify: `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()`:

```swift
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
```

Add the tests under `// MARK: - Config parsing`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile errors, `PluginConfig`, `PluginEntry`, `PluginConfigError`, `PluginConfigParser` undefined.

- [ ] **Step 3: Write the model**

Create `Sources/Host/PluginConfig.swift`:

```swift
import Foundation

/// One line of plugins.json. Exactly one of `name` (a bundle shipped inside the app) or `path`
/// (a bundle anywhere on disk) is set; the parser refuses anything else.
struct PluginEntry: Equatable {
    let name: String?
    let path: String?
    let isEnabled: Bool

    /// What the config called this entry, for error messages and the --list-plugins report.
    var location: String { name ?? path ?? "" }
}

/// The whole file. Tab order is list order.
struct PluginConfig: Equatable {
    let plugins: [PluginEntry]

    /// The file the app writes when there is none: every built-in, enabled, in the given order.
    static func builtins(named names: [String]) -> PluginConfig {
        PluginConfig(plugins: names.map { PluginEntry(name: $0, path: nil, isEnabled: true) })
    }
}

/// Everything that can go wrong between the file and a `PluginConfig`. Each case says where,
/// as "the top level" or "plugins[3]", because the window shows this text.
enum PluginConfigError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case unwritable(String)
    case malformedJSON(String)
    case notAnObject(where: String)
    case unknownKey(String, where: String)
    case wrongType(key: String, expected: String, where: String)
    case entryNeedsNameOrPath(where: String)
    case entryHasBoth(where: String)

    var description: String {
        switch self {
        case .unreadable(let detail):
            return "could not read plugins.json: \(detail)"
        case .unwritable(let detail):
            return "could not write plugins.json: \(detail)"
        case .malformedJSON(let detail):
            return "plugins.json is not valid JSON: \(detail)"
        case .notAnObject(let place):
            return "\(place) must be an object"
        case let .unknownKey(key, place):
            return "\(place) has an unknown key \"\(key)\""
        case let .wrongType(key, expected, place):
            return "\(place): \"\(key)\" must be \(expected)"
        case .entryNeedsNameOrPath(let place):
            return "\(place) needs a \"name\" or a \"path\""
        case .entryHasBoth(let place):
            return "\(place) has both \"name\" and \"path\"; use one"
        }
    }
}
```

- [ ] **Step 4: Write the parser**

Create `Sources/Host/PluginConfigParser.swift`:

```swift
import Foundation

/// Reads and writes plugins.json. Uses JSONSerialization rather than Codable because the file
/// is hand-edited: an unknown key or a wrong type must be an error that names its place, and
/// Codable ignores unknown keys silently.
enum PluginConfigParser {
    private static let topLevelKeys: Set<String> = ["plugins"]
    private static let entryKeys: Set<String> = ["name", "path", "enabled"]

    static func parse(_ data: Data) -> Result<PluginConfig, PluginConfigError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return .failure(.malformedJSON(detail))
        }
        guard let root = object as? [String: Any] else {
            return .failure(.notAnObject(where: "the top level"))
        }
        if let unknown = root.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            return .failure(.unknownKey(unknown, where: "the top level"))
        }
        guard let rawEntries = root["plugins"] as? [Any] else {
            return .failure(.wrongType(key: "plugins", expected: "a list", where: "the top level"))
        }
        let empty = Result<PluginConfig, PluginConfigError>.success(PluginConfig(plugins: []))
        return rawEntries.enumerated().reduce(into: empty) { result, indexed in
            guard case .success(let soFar) = result else { return }
            switch parseEntry(indexed.element, where: "plugins[\(indexed.offset)]") {
            case .success(let entry):
                result = .success(PluginConfig(plugins: soFar.plugins + [entry]))
            case .failure(let error):
                result = .failure(error)
            }
        }
    }

    private static func parseEntry(_ raw: Any, where place: String) -> Result<PluginEntry, PluginConfigError> {
        guard let object = raw as? [String: Any] else {
            return .failure(.notAnObject(where: place))
        }
        if let unknown = object.keys.sorted().first(where: { !entryKeys.contains($0) }) {
            return .failure(.unknownKey(unknown, where: place))
        }
        let name = object["name"]
        let path = object["path"]
        if name != nil, path != nil {
            return .failure(.entryHasBoth(where: place))
        }
        if name == nil, path == nil {
            return .failure(.entryNeedsNameOrPath(where: place))
        }
        if let name, !(name is String) {
            return .failure(.wrongType(key: "name", expected: "a string", where: place))
        }
        if let path, !(path is String) {
            return .failure(.wrongType(key: "path", expected: "a string", where: place))
        }
        return parseEnabled(object["enabled"], where: place).map { isEnabled in
            PluginEntry(name: name as? String, path: path as? String, isEnabled: isEnabled)
        }
    }

    private static func parseEnabled(_ raw: Any?, where place: String) -> Result<Bool, PluginConfigError> {
        guard let raw else { return .success(true) }
        guard isBoolean(raw), let value = raw as? Bool else {
            return .failure(.wrongType(key: "enabled", expected: "true or false", where: place))
        }
        return .success(value)
    }

    /// JSONSerialization hands back NSNumber for both `1` and `true`; only the latter is a boolean.
    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func encode(_ config: PluginConfig) throws -> Data {
        let entries = config.plugins.map(object(for:))
        return try JSONSerialization.data(withJSONObject: ["plugins": entries], options: [.prettyPrinted, .sortedKeys])
    }

    /// `enabled` is written only when false, since true is the default a reader assumes.
    private static func object(for entry: PluginEntry) -> [String: Any] {
        let location: [String: Any]
        if let name = entry.name {
            location = ["name": name]
        } else if let path = entry.path {
            location = ["path": path]
        } else {
            location = [:]
        }
        return entry.isEnabled ? location : location.merging(["enabled": false]) { current, _ in current }
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/Host/PluginConfig.swift Sources/Host/PluginConfigParser.swift SystemBarPluginTests.swift
git commit -m "$(cat <<'MSG'
Parse plugins.json strictly, naming the place of every mistake

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: Where the file lives, and writing it on first launch

**Files:**
- Create: `Sources/Host/PluginConfigStore.swift`
- Modify: `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()`:

```swift
        testStoreUsesApplicationSupportByDefault()
        testStoreHonoursTheEnvironmentOverride()
        testStoreWritesTheDefaultWhenTheFileIsMissing()
        testStoreReadsAnExistingFileInsteadOfTheDefault()
        testStoreReportsAnUnreadableFile()
        testStoreReportsAnUnwritableLocation()
```

Add the tests under `// MARK: - Config store`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `PluginConfigStore` undefined.

- [ ] **Step 3: Write the store**

Create `Sources/Host/PluginConfigStore.swift`:

```swift
import Foundation

/// Where plugins.json lives, and how it is first written and then read.
struct PluginConfigStore {
    static let environmentOverride = "SYSTEMBAR_PLUGINS_FILE"
    static let relativePath = "SystemBar/plugins.json"

    let fileURL: URL

    /// `~/Library/Application Support/SystemBar/plugins.json`, unless SYSTEMBAR_PLUGINS_FILE
    /// points somewhere else. The override exists so tests and scripts can run the app against a
    /// file of their own without touching the real one.
    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> PluginConfigStore {
        if let override = environment[environmentOverride], !override.isEmpty {
            return PluginConfigStore(fileURL: URL(fileURLWithPath: override))
        }
        return PluginConfigStore(fileURL: applicationSupport.appendingPathComponent(relativePath))
    }

    /// Reads the file, or writes the given default and returns it when there is no file yet.
    func loadOrCreate(default config: PluginConfig) -> Result<PluginConfig, PluginConfigError> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            do {
                try write(config)
            } catch {
                return .failure(.unwritable(error.localizedDescription))
            }
            return .success(config)
        }
        return load()
    }

    func load() -> Result<PluginConfig, PluginConfigError> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        return PluginConfigParser.parse(data)
    }

    func write(_ config: PluginConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PluginConfigParser.encode(config).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/Host/PluginConfigStore.swift SystemBarPluginTests.swift
git commit -m "$(cat <<'MSG'
Write a default plugins.json on first launch and read it after

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: The catalog that turns entries into tabs or visible failures

**Files:**
- Create: `Sources/Host/TabCatalog.swift`
- Create: `Sources/Host/PluginListReport.swift`
- Modify: `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()`:

```swift
        testCatalogKeepsOrderAndSkipsDisabledEntries()
        testCatalogShowsAFailedEntryInItsPlace()
        testCatalogRefusesADuplicateIdentifier()
        testCatalogCarriesOnAfterAFailure()
        testListReportPrintsOneLinePerEntry()
```

Add a second fake tab and a source after `FakeTab` at the bottom of the file:

```swift
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
    func makeView() -> AnyView { AnyView(Text("other")) }
}

/// A source that knows a fixed set of names, standing in for built-ins and, later, bundles.
struct MapTabSource: TabSource {
    let types: [String: TabPlugin.Type]

    func makeTab(for entry: PluginEntry, host: HostServices) throws -> TabPlugin {
        guard let name = entry.name, let type = types[name] else {
            throw TabLoadError(description: "no tab for \(entry.location)")
        }
        return type.init(host: host)
    }
}
```

Add the tests under `// MARK: - Catalog`:

```swift
    // MARK: - Catalog

    private static let fakeSource = MapTabSource(types: ["fake": FakeTab.self, "other": OtherFakeTab.self])

    private static func entry(_ name: String, enabled: Bool = true) -> PluginEntry {
        PluginEntry(name: name, path: nil, isEnabled: enabled)
    }

    private static func testCatalogKeepsOrderAndSkipsDisabledEntries() {
        let config = PluginConfig(plugins: [entry("other"), entry("fake", enabled: false), entry("fake")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(tabs.count == 2, "a disabled entry produces no tab at all, got \(tabs.count)")
        expect(tabs.map(\.title) == ["Other", "Fake"], "tabs come out in file order, got \(tabs.map(\.title))")
    }

    private static func testCatalogShowsAFailedEntryInItsPlace() {
        let config = PluginConfig(plugins: [entry("fake"), entry("nope")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        guard tabs.count == 2, case let .failed(location, reason) = tabs[1] else {
            expect(false, "an entry the source cannot load is a failed tab at its own position, got \(tabs)")
            return
        }
        expect(location == "nope" && reason == "no tab for nope", "the failure names the entry and repeats the source's reason")
        expect(tabs[1].title == "Error" && tabs[1].plugin == nil, "a failed tab is titled Error and has no plugin")
    }

    private static func testCatalogRefusesADuplicateIdentifier() {
        let config = PluginConfig(plugins: [entry("fake"), entry("fake")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        guard tabs.count == 2, case .loaded = tabs[0], case let .failed(_, reason) = tabs[1] else {
            expect(false, "the first of two plugins with one id loads and the second fails, got \(tabs)")
            return
        }
        expect(reason.contains("\"fake\""), "the duplicate failure names the clashing id, got: \(reason)")
    }

    private static func testCatalogCarriesOnAfterAFailure() {
        let config = PluginConfig(plugins: [entry("nope"), entry("other")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(tabs.map(\.title) == ["Error", "Other"], "a failure earlier in the list does not stop later entries, got \(tabs.map(\.title))")
    }

    private static func testListReportPrintsOneLinePerEntry() {
        let config = PluginConfig(plugins: [entry("fake"), entry("nope")])
        let tabs = TabCatalog.build(config: config, source: fakeSource, host: makeHost())
        expect(PluginListReport.lines(for: tabs) == ["ok fake Fake fake", "error nope: no tab for nope"],
               "--list-plugins prints ok/error lines in order, got \(PluginListReport.lines(for: tabs))")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile errors, `TabCatalog`, `TabSource`, `TabLoadError`, `LoadedTab`, `PluginListReport` undefined.

- [ ] **Step 3: Write the catalog**

Create `Sources/Host/TabCatalog.swift`:

```swift
import Foundation

/// The outcome of one enabled config entry. A failure keeps its place in the tab order so the
/// window can show it where the tab would have been.
enum LoadedTab {
    case loaded(location: String, plugin: TabPlugin)
    case failed(location: String, reason: String)

    var title: String {
        switch self {
        case .loaded(_, let plugin): return plugin.title
        case .failed: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .loaded(_, let plugin): return plugin.systemImage
        case .failed: return "exclamationmark.triangle"
        }
    }

    var plugin: TabPlugin? {
        if case .loaded(_, let plugin) = self { return plugin }
        return nil
    }
}

/// A reason a person can act on, thrown by a `TabSource`.
struct TabLoadError: Error, CustomStringConvertible {
    let description: String
}

/// Turns one config entry into a plugin, or throws. Stage 1 has one source, the built-ins;
/// Stage 2 adds the one that loads bundles.
protocol TabSource {
    func makeTab(for entry: PluginEntry, host: HostServices) throws -> TabPlugin
}

enum TabCatalog {
    /// Every enabled entry, in order, as a loaded tab or a failure. Nothing here stops on error.
    static func build(config: PluginConfig, source: TabSource, host: HostServices) -> [LoadedTab] {
        config.plugins
            .filter(\.isEnabled)
            .reduce(into: (tabs: [LoadedTab](), ids: Set<String>())) { state, entry in
                let tab = makeTab(for: entry, source: source, host: host, alreadyLoaded: state.ids)
                state.tabs.append(tab)
                if let plugin = tab.plugin {
                    state.ids.insert(type(of: plugin).identifier)
                }
            }
            .tabs
    }

    private static func makeTab(
        for entry: PluginEntry,
        source: TabSource,
        host: HostServices,
        alreadyLoaded: Set<String>
    ) -> LoadedTab {
        let plugin: TabPlugin
        do {
            plugin = try source.makeTab(for: entry, host: host)
        } catch {
            return .failed(location: entry.location, reason: "\(error)")
        }
        let id = type(of: plugin).identifier
        if alreadyLoaded.contains(id) {
            return .failed(location: entry.location, reason: "another loaded plugin already has the id \"\(id)\"")
        }
        return .loaded(location: entry.location, plugin: plugin)
    }
}
```

Create `Sources/Host/PluginListReport.swift`:

```swift
import Foundation

/// What `SystemBar --list-plugins` prints: the loader's outcome, one line per enabled entry,
/// so the real loading path can be checked from a script.
enum PluginListReport {
    static func lines(for tabs: [LoadedTab]) -> [String] {
        tabs.map { tab in
            switch tab {
            case let .loaded(location, plugin):
                return "ok \(type(of: plugin).identifier) \(plugin.title) \(location)"
            case let .failed(location, reason):
                return "error \(location): \(reason)"
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/Host/TabCatalog.swift Sources/Host/PluginListReport.swift SystemBarPluginTests.swift
git commit -m "$(cat <<'MSG'
Build the tab list from plugins.json, keeping failures in their place

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: The six built-in tabs as plugins

**Files:**
- Create: `Sources/Host/BuiltinTabs.swift`
- Modify: `Sources/UnifiedMonitor.swift:73-75`
- Modify: `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()`:

```swift
        testEveryDefaultNameIsABuiltin()
        testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode()
        testBuiltinSourceNamesTheUnknownTab()
        testBuiltinSourceDoesNotTakePathsYet()
```

Add the tests under `// MARK: - Built-in tabs`:

```swift
    // MARK: - Built-in tabs

    private static func testEveryDefaultNameIsABuiltin() {
        let names = BuiltinTabSource.defaultNames
        expect(names.count == BuiltinTabSource.types.count, "the default file lists every built-in exactly once")
        expect(names.allSatisfy { BuiltinTabSource.types[$0] != nil }, "every default name resolves to a built-in type")
        expect(names.allSatisfy { $0.hasSuffix(".bundle") }, "names are the bundle names each tab will have once it is a real bundle")
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
                return
            }
            expect(backed.monitorMode.icon == plugin.systemImage, "\(plugin.title) keeps the icon its MonitorMode had")
            expect(backed.monitorMode.rawValue == plugin.title, "\(plugin.title) keeps the title its MonitorMode had")
        }
    }

    private static func testBuiltinSourceNamesTheUnknownTab() {
        let didThrow = (try? BuiltinTabSource().makeTab(for: entry("Weather.bundle"), host: makeHost())) == nil
        expect(didThrow, "an unknown name throws")
        do {
            _ = try BuiltinTabSource().makeTab(for: entry("Weather.bundle"), host: makeHost())
        } catch {
            expect("\(error)".contains("Weather.bundle") && "\(error)".contains("CPU.bundle"),
                   "the error names the bad name and lists the real ones, got: \(error)")
        }
    }

    private static func testBuiltinSourceDoesNotTakePathsYet() {
        let pathEntry = PluginEntry(name: nil, path: "/tmp/X.bundle", isEnabled: true)
        do {
            _ = try BuiltinTabSource().makeTab(for: pathEntry, host: makeHost())
            expect(false, "a path entry cannot load until bundles exist")
        } catch {
            expect("\(error)".contains("path"), "the error says path entries are not supported yet, got: \(error)")
        }
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile errors, `BuiltinTabSource` and `MonitorBackedTab` undefined.

- [ ] **Step 3: Give the monitor a shared instance**

In `Sources/UnifiedMonitor.swift`, directly above `init() {`, add:

```swift
    /// Stage 1 of the plugin conversion: the built-in tabs reach the one monitor through this
    /// until each owns its own collector. Deleted with the class.
    static let shared = UnifiedMonitor()

```

- [ ] **Step 4: Write the adapters**

Create `Sources/Host/BuiltinTabs.swift`:

```swift
import Foundation
import SwiftUI

/// Stage 1 of the plugin conversion: the six tabs still compile into the app and still read the
/// one `UnifiedMonitor`, but the window only knows them through `TabPlugin`. This protocol is
/// the seam that lets the monitor keep its own sampling rule (`MonitorSamplingPlan.jobs`) until
/// each tab moves out; it is deleted with `UnifiedMonitor`.
protocol MonitorBackedTab: TabPlugin {
    var monitorMode: MonitorMode { get }
}

struct BuiltinTabSource: TabSource {
    /// Keyed by the bundle name each tab will have once it is a real bundle, so a plugins.json
    /// written today is still right then.
    static let types: [String: TabPlugin.Type] = [
        "CPU.bundle": CPUTab.self,
        "Memory.bundle": MemoryTab.self,
        "Disk.bundle": DiskTab.self,
        "Network.bundle": NetworkTab.self,
        "Power.bundle": PowerTab.self,
        "Dev.bundle": DevTab.self,
    ]

    /// The order a fresh plugins.json lists them in: today's tab order.
    static let defaultNames = ["Power.bundle", "Dev.bundle", "Memory.bundle", "Disk.bundle", "Network.bundle", "CPU.bundle"]

    func makeTab(for entry: PluginEntry, host: HostServices) throws -> TabPlugin {
        guard let name = entry.name else {
            throw TabLoadError(description: "\"path\" entries are not supported yet; only the built-in tabs can be listed, by \"name\"")
        }
        guard let type = Self.types[name] else {
            let known = Self.types.keys.sorted().joined(separator: ", ")
            throw TabLoadError(description: "no built-in tab is named \"\(name)\"; the names are \(known)")
        }
        return type.init(host: host)
    }
}

// Each adapter's refreshInterval and sharedFeeds restate what MonitorSamplingPlan says about
// that tab today. Nothing reads them yet; the host scheduler that will arrives in Stage 2.

final class PowerTab: MonitorBackedTab {
    static let identifier = "power"
    let title = "Power"
    let systemImage = "bolt.heart"
    let accent = Palette.caution
    let refreshInterval = MonitorSamplingPlan.powerRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.processes]
    let monitorMode = MonitorMode.power
    private let monitor = UnifiedMonitor.shared

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(PowerPanel(monitor: monitor)) }
}

final class DevTab: MonitorBackedTab {
    static let identifier = "dev"
    let title = "Dev"
    let systemImage = "terminal"
    let accent = Palette.purple
    let refreshInterval = MonitorSamplingPlan.capacityRefreshInterval
    let sharedFeeds: Set<SharedFeed> = []
    let monitorMode = MonitorMode.developer
    private let monitor = UnifiedMonitor.shared

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(DeveloperPanel(monitor: monitor)) }
}

final class MemoryTab: MonitorBackedTab {
    static let identifier = "memory"
    let title = "Memory"
    let systemImage = "memorychip"
    let accent = Palette.good
    let refreshInterval = MonitorSamplingPlan.memoryRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.processes]
    let monitorMode = MonitorMode.memory
    private let monitor = UnifiedMonitor.shared

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(MemoryPanel(monitor: monitor)) }
}

final class DiskTab: MonitorBackedTab {
    static let identifier = "disk"
    let title = "Disk"
    let systemImage = "internaldrive"
    let accent = Palette.cyan
    let refreshInterval = MonitorSamplingPlan.diskRefreshInterval
    let sharedFeeds: Set<SharedFeed> = []
    let monitorMode = MonitorMode.disk
    private let monitor = UnifiedMonitor.shared

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(DiskPanel(monitor: monitor)) }
}

final class NetworkTab: MonitorBackedTab {
    static let identifier = "network"
    let title = "Network"
    let systemImage = "arrow.up.arrow.down"
    let accent = Palette.blue
    let refreshInterval = MonitorSamplingPlan.networkRefreshInterval
    let sharedFeeds: Set<SharedFeed> = []
    let monitorMode = MonitorMode.network
    private let monitor = UnifiedMonitor.shared

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(NetworkPanel(monitor: monitor)) }
}

final class CPUTab: MonitorBackedTab {
    static let identifier = "cpu"
    let title = "CPU"
    let systemImage = "cpu"
    let accent = Palette.warning
    let refreshInterval = MonitorSamplingPlan.processRefreshInterval
    let sharedFeeds: Set<SharedFeed> = [.processes]
    let monitorMode = MonitorMode.cpu
    private let monitor = UnifiedMonitor.shared

    init(host: HostServices) {}
    func collect() {}
    func makeView() -> AnyView { AnyView(CPUPanel(monitor: monitor)) }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/Host/BuiltinTabs.swift Sources/UnifiedMonitor.swift SystemBarPluginTests.swift
git commit -m "$(cat <<'MSG'
Register the six built-in tabs through the TabPlugin contract

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: Relaunch, and the two views for when there is no tab to show

**Files:**
- Create: `Sources/Host/Relauncher.swift`
- Create: `Sources/Views/ConfigStatusViews.swift`
- Modify: `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()`:

```swift
        testRelauncherBuildsLaunchctlArguments()
        testRelauncherReadsThePidFromLaunchctlPrint()
```

Add the tests under `// MARK: - Relaunch`:

```swift
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
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | tail -5`
Expected: compile error, `Relauncher` undefined.

- [ ] **Step 3: Write the relauncher**

Create `Sources/Host/Relauncher.swift`:

```swift
import AppKit
import Foundation

/// "Edit plugins.json and restart" needs a one-click restart. Under the LaunchAgent that
/// install.sh registers, launchd owns the process and KeepAlive would restart a quit copy
/// anyway, so asking launchd to kick it is the only restart that never leaves two copies
/// running. Anywhere else, start a second copy of this executable and quit.
enum Relauncher {
    static let launchAgentLabel = "com.ih8celery.systembar"

    static func launchctlProbeArguments(uid: uid_t, label: String) -> [String] {
        ["print", "gui/\(uid)/\(label)"]
    }

    static func launchctlKickstartArguments(uid: uid_t, label: String) -> [String] {
        ["kickstart", "-k", "gui/\(uid)/\(label)"]
    }

    /// `launchctl print` lists `pid = N` for a running service. Comparing it to our own pid is
    /// what tells a dev build started from a terminal apart from the installed agent, even when
    /// both exist: kicking the agent would restart the wrong one.
    static func pid(fromLaunchctlPrint output: String) -> Int32? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid = ") }
            .flatMap { Int32($0.dropFirst("pid = ".count)) }
    }

    static func relaunch(log: (String) -> Void) {
        let uid = getuid()
        let probe = ProcessRunner.run(path: "/bin/launchctl", arguments: launchctlProbeArguments(uid: uid, label: launchAgentLabel), timeout: 5)
        if probe.status == 0, pid(fromLaunchctlPrint: probe.output) == getpid() {
            // launchd kills this process as part of the kickstart, so nothing after this runs.
            _ = ProcessRunner.run(path: "/bin/launchctl", arguments: launchctlKickstartArguments(uid: uid, label: launchAgentLabel), timeout: 5)
            return
        }
        guard let executable = Bundle.main.executableURL else {
            log("relaunch: this process has no executable URL; quitting instead")
            NSApplication.shared.terminate(nil)
            return
        }
        let copy = Process()
        copy.executableURL = executable
        do {
            try copy.run()
        } catch {
            log("relaunch: could not start a second copy (\(error.localizedDescription)); staying up")
            return
        }
        NSApplication.shared.terminate(nil)
    }
}
```

- [ ] **Step 4: Write the two status views**

Create `Sources/Views/ConfigStatusViews.swift`:

```swift
import Foundation
import SwiftUI

/// Shown in place of a tab whose plugins.json entry could not be loaded. The point is that a
/// typo in the file is visible in the app, not in a log nobody opens.
struct ErrorTabView: View {
    let location: String
    let reason: String
    let configPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This tab could not be loaded")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.critical)
            EvidenceRow(label: "Entry", value: location, detail: reason)
            EvidenceRow(label: "Config", value: "plugins.json", detail: configPath)
            Text("Fix the entry, then press Relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shown when plugins.json lists nothing enabled.
struct NoTabsView: View {
    let configPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No tabs are enabled")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            EvidenceRow(label: "Config", value: "plugins.json", detail: configPath)
            Text("Add or enable an entry, then press Relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `./test.sh 2>&1 | tail -3`
Expected: `SystemBarPerformanceTests passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/Host/Relauncher.swift Sources/Views/ConfigStatusViews.swift SystemBarPluginTests.swift
git commit -m "$(cat <<'MSG'
Add a relauncher and the views for a missing or broken tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 8: Drive the window from the catalog

**Files:**
- Modify: `Sources/Views/RootView.swift` (whole file)
- Modify: `Sources/App.swift` (whole file)

No new unit test: this project does not unit-test views, and the loading path this wires up is covered by Tasks 3 to 6. The check is `--list-plugins` and opening the app, below.

- [ ] **Step 1: Rewrite RootView**

Replace the whole of `Sources/Views/RootView.swift` with:

```swift
import AppKit
import Foundation
import SwiftUI

struct RootView: View {
    @ObservedObject var monitor: UnifiedMonitor
    let tabs: [LoadedTab]
    let configPath: String
    /// An index, not an id: a failed tab has no id, and two failures may share a location.
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider().background(Color.white.opacity(0.08))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 680)
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .onAppear {
            present(index: selection, isVisible: true)
        }
        .onDisappear {
            present(index: selection, isVisible: false)
        }
        .onChange(of: selection) { previous, current in
            loadedPlugin(at: previous)?.visibilityChanged(isVisible: false)
            present(index: current, isVisible: true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedTab?.systemImage ?? "questionmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28)

            Picker("Tab", selection: $selection) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { offset, tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .help(tab.title)
                        .tag(offset)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .labelsHidden()

            Button {
                Relauncher.relaunch(log: { NSLog("%@", $0) })
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Relaunch SystemBar to apply plugins.json")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit SystemBar")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .loaded(_, let plugin)?:
            plugin.makeView()
        case let .failed(location, reason)?:
            ErrorTabView(location: location, reason: reason, configPath: configPath)
        case nil:
            NoTabsView(configPath: configPath)
        }
    }

    private var selectedTab: LoadedTab? {
        tabs.indices.contains(selection) ? tabs[selection] : nil
    }

    private var accent: Color {
        loadedPlugin(at: selection)?.accent ?? Palette.critical
    }

    private func loadedPlugin(at index: Int) -> TabPlugin? {
        tabs.indices.contains(index) ? tabs[index].plugin : nil
    }

    /// Tells the monitor which of its samplers the selected tab needs. Until every tab is a real
    /// plugin, that rule still lives in MonitorSamplingPlan, keyed by MonitorMode; an error tab
    /// or an empty list needs nothing, so the monitor is told the window is effectively hidden.
    private func present(index: Int, isVisible: Bool) {
        let plugin = loadedPlugin(at: index)
        plugin?.visibilityChanged(isVisible: isVisible)
        guard let backed = plugin as? MonitorBackedTab else {
            monitor.updatePresentation(isVisible: false, mode: .memory)
            return
        }
        monitor.updatePresentation(isVisible: isVisible, mode: backed.monitorMode)
    }
}
```

- [ ] **Step 2: Rewrite App.swift**

Replace the whole of `Sources/App.swift` with:

```swift
import AppKit
import Foundation
import SwiftUI

#if !TESTING
@main
struct SystemBarApp: App {
    private let tabs: [LoadedTab]
    private let configPath: String

    init() {
        let store = PluginConfigStore.standard()
        let loaded = Self.loadTabs(store: store)
        tabs = loaded
        configPath = store.fileURL.path

        // `SystemBar --list-plugins` is the loader as a command: it reports what the window
        // would show, then exits without one. test.sh will use it to check the real loader.
        if CommandLine.arguments.contains("--list-plugins") {
            print(PluginListReport.lines(for: loaded).joined(separator: "\n"))
            exit(0)
        }
    }

    private static func loadTabs(store: PluginConfigStore) -> [LoadedTab] {
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            runner: ProcessRunner.run,
            log: { NSLog("%@", $0) }
        )
        switch store.loadOrCreate(default: .builtins(named: BuiltinTabSource.defaultNames)) {
        case .success(let config):
            return TabCatalog.build(config: config, source: BuiltinTabSource(), host: host)
        case .failure(let error):
            return [.failed(location: store.fileURL.path, reason: error.description)]
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(monitor: UnifiedMonitor.shared, tabs: tabs, configPath: configPath)
                .onAppear {
                    UnifiedMonitor.shared.start()
                }
        } label: {
            Image(systemName: "percent")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
#endif
```

- [ ] **Step 3: Build and run the tests**

Run: `./build.sh 2>&1 | tail -3 && ./test.sh 2>&1 | tail -3`
Expected: `Built .../SystemBar.app` and `SystemBarPerformanceTests passed`. If `swiftc` complains that `MonitorMode.allCases` is unused, that is fine; the enum stays until Stage 3.

- [ ] **Step 4: Check the loader from the command line**

Run, against a temporary file so the real one is untouched:

```bash
export SYSTEMBAR_PLUGINS_FILE=/tmp/systembar-plugins-check.json
rm -f "$SYSTEMBAR_PLUGINS_FILE"
./SystemBar --list-plugins
```

Expected, six lines in this order, and the file now exists:

```
ok power Power Power.bundle
ok dev Dev Dev.bundle
ok memory Memory Memory.bundle
ok disk Disk Disk.bundle
ok network Network Network.bundle
ok cpu CPU CPU.bundle
```

Then break it on purpose:

```bash
cat > "$SYSTEMBAR_PLUGINS_FILE" <<'JSON'
{ "plugins": [
  { "name": "CPU.bundle" },
  { "name": "Weather.bundle" },
  { "name": "CPU.bundle" },
  { "name": "Memory.bundle", "enabled": false }
] }
JSON
./SystemBar --list-plugins
```

Expected:

```
ok cpu CPU CPU.bundle
error Weather.bundle: no built-in tab is named "Weather.bundle"; the names are CPU.bundle, Dev.bundle, Disk.bundle, Memory.bundle, Network.bundle, Power.bundle
error CPU.bundle: another loaded plugin already has the id "cpu"
```

- [ ] **Step 5: Look at it**

With the broken file still exported, run `./SystemBar.app/Contents/MacOS/SystemBar &` from the same shell (`open` would not pass `SYSTEMBAR_PLUGINS_FILE` through), click the menu bar icon, and check: three tabs, the second and third show the error view with the reason and the temp path, the first shows the CPU panel updating. Press Relaunch: the app quits and comes back. Then `unset SYSTEMBAR_PLUGINS_FILE`, quit the app, and confirm a plain `./SystemBar --list-plugins` writes `~/Library/Application Support/SystemBar/plugins.json` with the six built-ins.

- [ ] **Step 6: Commit**

```bash
git add Sources/Views/RootView.swift Sources/App.swift
git commit -m "$(cat <<'MSG'
Drive the tab bar from plugins.json

Tabs appear in the file's order, a disabled entry disappears, and an entry
that cannot load shows where it would have been, with the reason. A Relaunch
button next to Quit applies a changed file.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 9: Tell people about the file

**Files:**
- Modify: `README.md` (after the "The tabs" table, before "## Requirements")
- Modify: `AGENTS.md` and `CLAUDE.md` (the "Architecture Overview" paragraph; both files are identical and stay so)

- [ ] **Step 1: README section**

Insert after the tabs table and before `## Requirements`:

```markdown
## Choosing tabs

Which tabs appear, and in what order, comes from a file the app writes the first time it runs:

```
~/Library/Application Support/SystemBar/plugins.json
```

It lists the six tabs above. Reorder the entries to reorder the tabs, set `"enabled": false` on one to hide it, and press the Relaunch button in the popover header (or quit and reopen) to apply the change. The first tab listed is the one that opens.

```json
{ "plugins": [
  { "name": "Memory.bundle" },
  { "name": "CPU.bundle" },
  { "name": "Power.bundle", "enabled": false }
] }
```

An entry the app cannot load, say a misspelt name, still gets a tab, showing what went wrong and where the file is, so a typo is never silent. `SystemBar --list-plugins` prints the same outcome to the terminal and exits, and `SYSTEMBAR_PLUGINS_FILE=/some/other.json` points the app at a different file for the run.

Tabs built outside this repository are the next step; see `docs/one-page/systembar-tab-plugins.md`.
```

- [ ] **Step 2: Agent docs**

In both `AGENTS.md` and `CLAUDE.md`, replace the Architecture Overview paragraph with:

```markdown
SystemBar is a single-file-per-concern SwiftUI menu bar app. `Sources/UnifiedMonitor.swift` plus its `UnifiedMonitor+*.swift` extensions collect system stats (CPU, memory, disk, network, power, developer processes); `Sources/Views/` renders them as tabs behind one `MenuBarExtra` icon.

The tab bar is being converted to plugins (spec: `docs/one-page/systembar-tab-plugins.md`). `Sources/Kit/` holds the `TabPlugin` contract and `HostServices`; `Sources/Host/` reads `~/Library/Application Support/SystemBar/plugins.json` and builds the tab list; `Sources/Host/BuiltinTabs.swift` adapts the six existing panels to the contract until each owns its collector. `RootView` iterates that list and never names a tab.
```

- [ ] **Step 3: Run everything once more**

Run: `./build.sh 2>&1 | tail -1 && ./test.sh 2>&1 | tail -1`
Expected: `Built .../SystemBar.app` and `SystemBarPerformanceTests passed`

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md CLAUDE.md
git commit -m "$(cat <<'MSG'
Document plugins.json and the Kit and Host directories

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

## Done when

- `./test.sh` passes with every test in this plan present.
- `./SystemBar --list-plugins` against a fresh temp file prints the six `ok` lines; against the broken file prints one `ok` and two `error` lines.
- The popover shows tabs in file order, error tabs where entries failed, and Relaunch restarts the app.
- `git log` shows the nine commits above on top of the spec commit.
- The Stage 1 Beads issue is closed and the Stage 2 plan is written next, starting from the spec's Build Contract.
