# Tab Plugins Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The SDK becomes a real dylib with a stable interface, Power becomes the first tab that loads from a `.bundle` through the same loader a user's plugin would use, and a person can build a plugin from `Examples/HelloTab/` without editing the repository.

**Architecture:** `Sources/Kit/` is compiled once into `libSystemBarKit.dylib` with library evolution on, and its `.swiftinterface` ships inside the app so plugins can be built later against it. `Sources/Host/` is the app: it links the dylib, resolves each `plugins.json` entry to a class (a bundle in `Contents/PlugIns/`, a bundle at a path, or, until Stage 3, one of the five tabs still compiled in), constructs the plugin after the duplicate-id check, and runs each plugin's `collect()` on its own serial queue only while its tab is showing. `Plugins/Power/` is the first plugin directory; `build.sh` builds the Kit, the host, and every directory under `Plugins/`; `build-plugin.sh` is what a user runs. The processes feed (`HostServices.processes`) is fed by `UnifiedMonitor`'s existing sampler for now, and the monitor runs that sampler when any visible plugin declares `.processes`.

**Tech Stack:** Swift 6.3 toolchain in `-swift-version 5` mode, `-target arm64-apple-macos14`, `swiftc` only (no package manager), SwiftUI, Combine, Foundation `Bundle` loading.

**Decisions already made (issue 2ik.2, 2026-09-24):** `makeView` and `visibilityChanged` are `@MainActor`; `collect` runs on the plugin's queue; `HostServices` and its closures are `Sendable`; `HostServices.init` is public and the no-shell rule is a documented convention; minimum macOS is 14 (closes bug `eax`); `TabSource` resolves a type and the catalog constructs after the duplicate check; bundle errors are wrapped in `TabLoadError`; a plugin's rpath is `@executable_path/../Frameworks`, so a bundle anywhere on disk finds the running app's SDK.

---

## File structure after this stage

```
Sources/
  Kit/                      -> module SystemBarKit -> build/Frameworks/libSystemBarKit.dylib + build/SDK/
    TabPlugin.swift         protocol, SharedFeed (unchanged names, thread rules added)
    HostServices.swift      public init, Sendable, processes feed
    Feed.swift              NEW: latest value + publisher
    ProcessRunner.swift     unchanged
    SharedModels.swift      NEW: SampleHealth, ProcessSnapshot, ProcessCPUScale, FastStatsSnapshot, ProcessSummary, BoundedHistory (moved out of Models.swift, made public)
    Views/Palette.swift     moved, public
    Views/SharedComponents.swift  moved, public
    Views/SegmentedBar.swift      moved, public
    Views/ViewFormatting.swift    moved, public; gains thermalStateLabel
  Host/                     -> module SystemBar -> SystemBar.app/Contents/MacOS/SystemBar
    App.swift, UnifiedMonitor*.swift, Models.swift, Capacity/, Views/   (git mv from Sources/)
    PluginConfig*.swift, TabCatalog.swift, TabLoader.swift, BuiltinTabs.swift, Relauncher.swift, PluginListReport.swift  (already here)
    PluginPath.swift        NEW: name/path rules
    BundleTabSource.swift   NEW: Bundle loading behind a small protocol
    HostTabSource.swift     NEW: bundles first, compiled-in tabs second (deleted in Stage 3)
    PluginScheduler.swift   NEW: per-plugin queue and timer
Plugins/
  Power/Info.plist, Power/Sources/{PowerPlugin,PowerCollector,PowerModels,PowerPanel}.swift, Power/Tests/PowerTests.swift
Examples/
  HelloTab/Info.plist, HelloTab/Sources/HelloTab.swift
build.sh, build-plugin.sh, test.sh
```

Every task below leaves `./build.sh` and `./test.sh` green. Tests are written before the code they test.

---

## Task 1: Prove a plugin's published changes redraw the host window

The spec names this as the first thing Stage 2 must do. It is a throwaway spike in the scratch directory; nothing is committed. Its output is evidence recorded on the issue.

**Files:** none in the repository. Scratch: `$SCRATCH/redraw/{Kit,Plugin,Host,out}` where `$SCRATCH` is the session scratchpad directory.

- [ ] **Step 1: A Kit for the spike**

Copy the real Kit and make the initializer public (the decision for Stage 2):

```bash
mkdir -p "$SCRATCH/redraw/Kit" "$SCRATCH/redraw/Plugin" "$SCRATCH/redraw/Host" "$SCRATCH/redraw/out/App.app/Contents/"{MacOS,Frameworks,PlugIns/Ticker.bundle/Contents/MacOS}
cp Sources/Kit/*.swift "$SCRATCH/redraw/Kit/"
sed -i '' 's/^    init(homeDirectory: String, runner:/    public init(homeDirectory: String, runner:/' "$SCRATCH/redraw/Kit/HostServices.swift"
```

- [ ] **Step 2: A plugin that changes on its own**

`$SCRATCH/redraw/Plugin/Ticker.swift`:

```swift
import Foundation
import SwiftUI
import SystemBarKit

@objc(TickerPlugin)
public final class TickerPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "ticker"
    public let title = "Ticker"
    public let systemImage = "clock"
    public let accent = Color.orange
    public let refreshInterval: TimeInterval = 1
    public let sharedFeeds: Set<SharedFeed> = []

    @Published var ticks = 0
    private var timer: Timer?

    public init(host: HostServices) {
        super.init()
        // The plugin drives its own change here so the spike does not need the host scheduler.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.ticks += 1
        }
    }

    public func collect() {}
    public func makeView() -> AnyView { AnyView(TickerView(plugin: self)) }
}

struct TickerView: View {
    @ObservedObject var plugin: TickerPlugin
    var body: some View {
        Text("ticks \(plugin.ticks)")
            .font(.system(size: 48, weight: .bold, design: .monospaced))
            .frame(width: 400, height: 200)
    }
}
```

`$SCRATCH/redraw/out/App.app/Contents/PlugIns/Ticker.bundle/Contents/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ticker</string>
<key>CFBundleIdentifier</key><string>spike.ticker</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>NSPrincipalClass</key><string>TickerPlugin</string>
</dict></plist>
```

- [ ] **Step 3: A host that opens a window and prints its window number**

`$SCRATCH/redraw/Host/main.swift`:

```swift
import AppKit
import Foundation
import SwiftUI
import SystemBarKit

let url = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/Ticker.bundle")
guard let bundle = Bundle(url: url), bundle.load(),
      let cls = bundle.principalClass as? TabPlugin.Type else {
    print("could not load the plugin"); exit(1)
}
let host = HostServices(homeDirectory: NSHomeDirectory(), runner: ProcessRunner.run, log: { print($0) })
let plugin = cls.init(host: host)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = NSHostingView(rootView: plugin.makeView())
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("window \(window.windowNumber)")
fflush(stdout)
app.run()
```

`$SCRATCH/redraw/out/App.app/Contents/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>App</string>
<key>CFBundleIdentifier</key><string>spike.redraw</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
```

- [ ] **Step 4: Build all three exactly the way Task 4 will**

```bash
cd "$SCRATCH/redraw"
mkdir -p sdk
swiftc -emit-library -parse-as-library -module-name SystemBarKit \
  -enable-library-evolution -swift-version 5 -target arm64-apple-macos14 \
  -emit-module -emit-module-path sdk/SystemBarKit.swiftmodule \
  -emit-module-interface-path sdk/SystemBarKit.swiftinterface \
  -Xlinker -install_name -Xlinker @rpath/libSystemBarKit.dylib \
  -framework SwiftUI -framework AppKit \
  -o out/App.app/Contents/Frameworks/libSystemBarKit.dylib Kit/*.swift
swiftc -emit-library -parse-as-library -module-name Ticker -swift-version 5 -target arm64-apple-macos14 \
  -I sdk -L out/App.app/Contents/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit \
  -o out/App.app/Contents/PlugIns/Ticker.bundle/Contents/MacOS/Ticker Plugin/Ticker.swift
swiftc -module-name App -swift-version 5 -target arm64-apple-macos14 \
  -I sdk -L out/App.app/Contents/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit \
  -o out/App.app/Contents/MacOS/App Host/main.swift
```

Expected: three builds succeed; the interface file starts with `// swift-interface-format-version`.

- [ ] **Step 5: Run it and capture the window twice**

```bash
cd "$SCRATCH/redraw"
./out/App.app/Contents/MacOS/App > run.log 2>&1 &
sleep 2
win=$(awk '/^window /{print $2}' run.log)
screencapture -x -l "$win" first.png
sleep 1.5
screencapture -x -l "$win" second.png
md5 -q first.png second.png
kill %1
```

Expected: two different checksums, and reading `second.png` shows `ticks N` with N larger than in `first.png` (read both images). If the checksums match, the plugin's published change did not redraw the host, and the plan stops here: record the result on the issue and raise it before Task 2.

- [ ] **Step 6: Record**

Append to the issue notes: "Redraw spike: a plugin's @Published change redrew the host window at runtime (ticks went from A to B across 1.5 s; built with library evolution, -swift-version 5, macOS 14 target)." Delete the two PNGs.

---

## Task 2: Move files so Kit and Host are the only two source trees

Pure moves plus the two constants that block a clean split. No behaviour change; one module still.

**Files:**
- Move: `Sources/Views/{Palette,SharedComponents,SegmentedBar,ViewFormatting}.swift` -> `Sources/Kit/Views/`
- Move: `Sources/App.swift`, `Sources/UnifiedMonitor*.swift`, `Sources/Models.swift`, `Sources/Capacity/`, `Sources/Views/` (what is left) -> `Sources/Host/`
- Create: `Sources/Kit/SharedModels.swift`
- Modify: `Sources/Host/Models.swift` (the moved one), `Sources/Host/UnifiedMonitor+Power.swift`, `Sources/Host/UnifiedMonitor+Processes.swift`, `Sources/Host/UnifiedMonitor+Capacity.swift`, `Sources/Kit/Views/ViewFormatting.swift`

- [ ] **Step 1: Move**

```bash
mkdir -p Sources/Kit/Views Sources/Host/Views Sources/Host/Capacity
git mv Sources/Views/Palette.swift Sources/Views/SharedComponents.swift Sources/Views/SegmentedBar.swift Sources/Views/ViewFormatting.swift Sources/Kit/Views/
git mv Sources/App.swift Sources/Models.swift Sources/Host/
git mv Sources/UnifiedMonitor.swift Sources/UnifiedMonitor+*.swift Sources/Host/
git mv Sources/Capacity/*.swift Sources/Host/Capacity/
git mv Sources/Views/*.swift Sources/Host/Views/
rmdir Sources/Views Sources/Capacity
```

Expected: `ls Sources` prints `Host Kit`.

- [ ] **Step 2: Cut the shared models out of Models.swift**

Create `Sources/Kit/SharedModels.swift` and move these declarations into it from `Sources/Host/Models.swift`, verbatim, keeping their doc comments: `SampleHealth`, `ProcessSnapshot`, `ProcessCPUScale`, `FastStatsSnapshot`, `ProcessSummary`, `BoundedHistory`. Then, in the moved `ProcessSummary`, replace the two default limits and add the constants:

```swift
struct ProcessSummary {
    /// Every displayed row groups by process name; only the groups that land in that display
    /// need a per-PID rusage syscall, so the snapshot pass and this slice share these limits.
    static let memoryDisplayLimit = 18
    static let cpuDisplayLimit = 28

    var totalCount = 0
    var topMemory: [ProcessSnapshot] = []
    var topCPU: [ProcessSnapshot] = []
    var maxPhysical: UInt64 = 1

    init() {}

    init(rows: [ProcessSnapshot], limit: Int) {
        self.init(rows: rows, memoryLimit: limit, cpuLimit: limit)
    }

    init(
        rows: [ProcessSnapshot],
        memoryLimit: Int = ProcessSummary.memoryDisplayLimit,
        cpuLimit: Int = ProcessSummary.cpuDisplayLimit
    ) {
        totalCount = rows.count
        topMemory = Array(rows.sorted { $0.physical > $1.physical }.prefix(memoryLimit))
        topCPU = Array(rows.sorted { $0.cpu > $1.cpu }.prefix(cpuLimit))
        maxPhysical = max(rows.map(\.physical).max() ?? 1, 1)
    }
}
```

Delete `processMemoryDisplayLimit` and `processCPUDisplayLimit` (and their comment) from `Sources/Host/UnifiedMonitor+Power.swift`, and in `Sources/Host/UnifiedMonitor+Processes.swift` change the two defaults to `ProcessSummary.memoryDisplayLimit` and `ProcessSummary.cpuDisplayLimit`.

The file starts with `import Foundation` only; `SharedModels.swift` must not import AppKit or the host.

- [ ] **Step 3: Move thermalStateLabel to the Kit**

Cut `static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String` out of `Sources/Host/UnifiedMonitor+Capacity.swift` and add it to `Sources/Kit/Views/ViewFormatting.swift` as a free function with the same body:

```swift
/// The four coarse levels macOS reports, as words. No number exists without root.
func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
```

Replace the two callers: `Self.thermalStateLabel(` in `UnifiedMonitor+Capacity.swift` and `UnifiedMonitor+Power.swift` become `thermalStateLabel(`.

- [ ] **Step 4: Build and test**

Run `./build.sh` and `./test.sh` (both still glob `Sources`). Expected: `Built …/SystemBar.app` and `SystemBarPerformanceTests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Kit/SharedModels.swift
git commit -m "$(cat <<'MSG'
Sort every source file into Kit or Host before the SDK becomes a dylib

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- Sources
```

---

## Task 3: The Kit's public surface, thread rules, Sendable, and the Feed

Still one module, so `public` changes nothing yet; the compiler only checks that public signatures name public types.

**Files:**
- Create: `Sources/Kit/Feed.swift`
- Modify: `Sources/Kit/TabPlugin.swift`, `Sources/Kit/HostServices.swift`, `Sources/Kit/SharedModels.swift`, `Sources/Kit/Views/*.swift`, `Sources/Host/BuiltinTabs.swift`, `Sources/Host/App.swift`, `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()` in `SystemBarPluginTests.swift`, after the last test call:

```swift
        testFeedHoldsTheLatestValueAndPublishesTheNext()
        testHostServicesCanBeBuiltByAnyoneAndCarriesTheProcessesFeed()
```

Under a new `// MARK: - Feed` section:

```swift
    // MARK: - Feed

    private static func testFeedHoldsTheLatestValueAndPublishesTheNext() {
        let feed = Feed(initial: 1)
        var received: [Int] = []
        let subscription = feed.publisher.sink { received.append($0) }
        feed.send(2)
        feed.send(3)
        expect(feed.value == 3, "value is the latest reading, got \(feed.value)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(received == [2, 3], "the publisher delivers every reading after subscription, on main, got \(received)")
        subscription.cancel()
    }

    private static func testHostServicesCanBeBuiltByAnyoneAndCarriesTheProcessesFeed() {
        let feed = Feed(initial: ProcessSummary())
        let host = HostServices(homeDirectory: "/tmp", processes: feed, fastStats: Feed(initial: FastStatsSnapshot()), runner: ProcessRunner.run, log: { _ in })
        expect(host.processes.value.totalCount == 0, "the feed a host is built with is the one plugins read")
        expect(host.fastStats.value.cpuUsagePercent == 0, "the 1-second feed is there too, starting empty")
        feed.send(ProcessSummary(rows: [ProcessSnapshot(name: "x", count: 1, physical: 1, virtualSize: 1, cpu: 1)], limit: 1))
        expect(host.processes.value.totalCount == 1, "a reading sent to the feed is visible through the host")
    }
```

Change the existing `makeHost(runner:)` helper to build the new initializer:

```swift
    static func makeHost(runner: @escaping CommandRunner = ProcessRunner.run) -> HostServices {
        HostServices(
            homeDirectory: NSHomeDirectory(),
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: runner,
            log: { _ in }
        )
    }
```

Every existing call of `makeView()` in the test file must run on the main actor now. Wrap each one: `MainActor.assumeIsolated { plugin.makeView() }` (the test binary runs on the main thread, so this is a check, not a hop). The fakes `FakeTab` and `OtherFakeTab` mark their `makeView` and any `visibilityChanged` with `@MainActor`.

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile errors, `Feed` undefined and `HostServices` has no `processes:` argument.

- [ ] **Step 3: The Feed**

Create `Sources/Kit/Feed.swift`:

```swift
import Combine
import Foundation

/// A value the host samples on a plugin's behalf: the latest reading, plus a publisher for the
/// readings after it. Readings are delivered on the main thread. Reading `value` never starts
/// the sampler; listing the feed in `sharedFeeds` does.
public final class Feed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private let subject = PassthroughSubject<Value, Never>()

    public init(initial: Value) {
        current = initial
    }

    /// The latest reading. Safe to read from any thread, including a plugin's collect queue.
    public var value: Value {
        lock.withLock { current }
    }

    /// Every reading after now, on the main thread.
    public var publisher: AnyPublisher<Value, Never> {
        subject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// The host's side: record a reading and tell subscribers. Any thread.
    public func send(_ value: Value) {
        lock.withLock { current = value }
        subject.send(value)
    }
}
```

- [ ] **Step 4: Thread rules on the contract**

Replace the protocol and its extension in `Sources/Kit/TabPlugin.swift` (keep `SharedFeed` as it is, but add `public` is already there):

```swift
/// One tab. The host creates a plugin once at launch, calls `collect()` on the plugin's own
/// queue only while its tab is on screen, and embeds `makeView()` in the window.
///
/// Thread rules, fixed for every plugin built against this SDK: `collect()` runs on a queue the
/// host owns for this plugin, never concurrently with itself; `makeView()` and
/// `visibilityChanged(isVisible:)` run on the main thread; a plugin that publishes from
/// `collect()` hops to the main thread first, because the panel observes it from there.
public protocol TabPlugin: AnyObject {
    /// Stable, unique, lowercase. Two loaded plugins sharing one is an error the host shows.
    static var identifier: String { get }
    var title: String { get }
    var systemImage: String { get }
    var accent: Color { get }
    /// How often the host calls `collect()` while this tab is showing.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must run while this tab is showing. The set is not frozen: a host
    /// switching over it needs `@unknown default`.
    var sharedFeeds: Set<SharedFeed> { get }

    init(host: HostServices)
    /// This plugin's own queue, never concurrently with itself, only while visible.
    func collect()
    /// Main thread, when the tab is switched to or away from. Default: nothing.
    @MainActor func visibilityChanged(isVisible: Bool)
    /// Main thread. The panel observes the plugin's own model objects.
    @MainActor func makeView() -> AnyView
}

public extension TabPlugin {
    @MainActor func visibilityChanged(isVisible: Bool) {}
}
```

- [ ] **Step 5: HostServices**

Replace `Sources/Kit/HostServices.swift`:

```swift
import Foundation

/// Runs one executable with an argument array and returns what it printed. Never a shell.
public typealias CommandRunner = @Sendable (
    _ path: String, _ arguments: [String], _ environment: [String: String]?, _ timeout: TimeInterval
) -> CommandOutput

/// What the host hands every plugin at construction. A plugin keeps it for its lifetime and may
/// use it from any thread.
public final class HostServices: Sendable {
    public let homeDirectory: String
    /// The 10-second process summary: top by CPU, top by memory, counts. Sampled only while a
    /// visible plugin lists `.processes` in its `sharedFeeds`.
    public let processes: Feed<ProcessSummary>
    /// The 1-second sample: CPU percent and network rates with their short histories. Sampled
    /// whenever the window is open, so listing `.fastStats` only documents the dependency today.
    public let fastStats: Feed<FastStatsSnapshot>
    private let runner: CommandRunner
    private let logger: @Sendable (String) -> Void

    /// Anyone may build one; the tests do. By convention only the app does, and the rule that
    /// subprocesses never go through a shell is upheld by the runner's shape: an explicit
    /// executable path and an argument array, nothing to interpolate.
    public init(
        homeDirectory: String,
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        runner: @escaping CommandRunner,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.homeDirectory = homeDirectory
        self.processes = processes
        self.fastStats = fastStats
        self.runner = runner
        self.logger = log
    }

    /// The way a plugin runs a subprocess: explicit path, argument array, no shell.
    /// `environment` exists because an app started by launchd has almost no PATH; a plugin that
    /// runs a `#!/usr/bin/env node` script has to say where node is. A non-nil `environment`
    /// replaces the child's inherited environment entirely; it does not merge. To override one
    /// key, start from `ProcessInfo.processInfo.environment` and change that key.
    public func run(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = ProcessRunner.defaultTimeout
    ) -> CommandOutput {
        runner(path, arguments, environment, timeout)
    }

    public func log(_ message: String) {
        logger(message)
    }
}
```

- [ ] **Step 6: Public models and views**

In `Sources/Kit/SharedModels.swift`: every type becomes `public`, every stored property `public`, every static and method `public`, and add `Sendable` to `SampleHealth`, `ProcessSnapshot`, `FastStatsSnapshot`, `ProcessSummary`. Public memberwise inits are not synthesized, so add them explicitly, in declaration order:

```swift
public struct ProcessSnapshot: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int
    public let physical: UInt64
    public let virtualSize: UInt64
    public let cpu: Double

    public init(name: String, count: Int, physical: UInt64, virtualSize: UInt64, cpu: Double) {
        self.name = name
        self.count = count
        self.physical = physical
        self.virtualSize = virtualSize
        self.cpu = cpu
    }
}
```

`FastStatsSnapshot` gets `public init() {}`; `SampleHealth.init(isOK:)` becomes public; `ProcessSummary`'s three inits become public; `BoundedHistory.append` and both `ProcessCPUScale` functions become public.

In `Sources/Kit/Views/`: every `struct`, `enum` and free `func` becomes `public`, every `var body` becomes `public var body`, every `static let` in `Palette` becomes `public static let`, and every view gets an explicit public init that takes its stored properties in declaration order with the same labels the call sites already use, for example:

```swift
public struct EvidenceRow: View {
    let label: String
    let value: String
    let detail: String

    public init(label: String, value: String, detail: String) {
        self.label = label
        self.value = value
        self.detail = detail
    }
```

`SectionTitle` and `ChartUnitLabel` keep their unlabeled `init(_ text: String)`, made public. `BarSegment` gets `public init(label:value:color:)`. `Sparkline` and `DualSparkline` get inits with their four properties; check each call site in `Sources/Host/Views/` still compiles unchanged (they use the memberwise labels today).

- [ ] **Step 7: The host side of the new rules**

In `Sources/Host/BuiltinTabs.swift`, mark each adapter's `makeView()` `@MainActor`. In `Sources/Host/App.swift`, build the host with a feed and keep the feed for Task 6:

```swift
    private let processes = Feed(initial: ProcessSummary())
    private let fastStats = Feed(initial: FastStatsSnapshot())
```

```swift
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            processes: processes,
            fastStats: fastStats,
            runner: ProcessRunner.run,
            log: { NSLog("%@", $0) }
        )
```

(Both feeds are initialised at their declaration, so `init` may use them before assigning `tabs`.)

- [ ] **Step 8: Run the tests to see them pass**

Expected: `SystemBarPerformanceTests passed`, and `./build.sh` succeeds.

- [ ] **Step 9: Commit**

```bash
git add Sources/Kit/Feed.swift
git commit -m "$(cat <<'MSG'
Fix the SDK's thread rules and make its surface public before it becomes a dylib

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- Sources SystemBarPluginTests.swift
```

---

## Task 4: Build the Kit as a dylib; the host and the tests link it

**Files:**
- Modify: `build.sh`, `test.sh`, `Info.plist`, `.gitignore`, every file under `Sources/Host/` that uses a Kit type, `TestSupport.swift`, `SystemBarCapacityTests.swift`, `SystemBarPluginTests.swift`, `SystemBarPerformanceTests.swift`

- [ ] **Step 1: build.sh**

Replace `build.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

# One toolchain setting for every part, so the SDK's stable interface and the plugins built
# against it agree on the language mode and the oldest macOS they run on.
target=arm64-apple-macos14
swift_version=5
# `package` members (the host's side of a Feed) are visible to the app and the tests, never to a plugin.
package_name=SystemBar

rm -rf build SystemBar.app
mkdir -p build/Frameworks build/SDK

# 1. The SDK: one dylib with a stable interface, so a plugin built against it today still
#    loads after the app is rebuilt, as long as nothing it uses was removed.
swiftc \
  -emit-library -parse-as-library -module-name SystemBarKit \
  -enable-library-evolution -swift-version "$swift_version" -target "$target" \
  -package-name "$package_name" \
  -emit-module -emit-module-path build/SDK/SystemBarKit.swiftmodule \
  -emit-module-interface-path build/SDK/SystemBarKit.swiftinterface \
  -Xlinker -install_name -Xlinker @rpath/libSystemBarKit.dylib \
  -framework SwiftUI -framework AppKit \
  -o build/Frameworks/libSystemBarKit.dylib \
  $(find Sources/Kit -name '*.swift' | sort)

# 2. The app, linked against the SDK it will carry.
swiftc \
  -parse-as-library -module-name SystemBar \
  -swift-version "$swift_version" -target "$target" -package-name "$package_name" \
  -I build/SDK -L build/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit \
  -o build/SystemBar \
  $(find Sources/Host -name '*.swift' | sort)

# 3. The bundle layout. Plugins find the SDK through @executable_path/../Frameworks, and a
#    person building one points build-plugin.sh at this app to find Resources/SDK.
mkdir -p SystemBar.app/Contents/MacOS SystemBar.app/Contents/Frameworks \
         SystemBar.app/Contents/Resources/SDK SystemBar.app/Contents/PlugIns
cp -f Info.plist SystemBar.app/Contents/Info.plist
cp -f build/SystemBar SystemBar.app/Contents/MacOS/SystemBar
chmod 755 SystemBar.app/Contents/MacOS/SystemBar
cp -f build/Frameworks/libSystemBarKit.dylib SystemBar.app/Contents/Frameworks/
cp -f build/SDK/SystemBarKit.* SystemBar.app/Contents/Resources/SDK/

echo "Built $(pwd)/SystemBar.app"
```

The root `SystemBar` binary is no longer produced. Anything that ran `./SystemBar` now runs `./SystemBar.app/Contents/MacOS/SystemBar` (Task 9 updates the docs; Task 8 the test).

- [ ] **Step 2: test.sh**

Replace `test.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

# The tests link the same SDK dylib the app does, built by build.sh a moment ago. Everything
# else (host without its @main, each plugin's sources and tests, the test files) is one module.
./build.sh

swiftc \
  -D TESTING \
  -parse-as-library -module-name SystemBarTests \
  -swift-version 5 -target arm64-apple-macos14 -package-name SystemBar \
  -I build/SDK -L build/Frameworks -lSystemBarKit \
  -Xlinker -rpath -Xlinker "$(pwd)/build/Frameworks" \
  -framework SwiftUI -framework AppKit \
  -o /tmp/SystemBarPerformanceTests \
  $(find Sources/Host -name '*.swift' | sort) \
  TestSupport.swift \
  SystemBarCapacityTests.swift \
  SystemBarPluginTests.swift \
  SystemBarPerformanceTests.swift

/tmp/SystemBarPerformanceTests
```

- [ ] **Step 3: Imports, the OS floor, and ignores**

Add `import SystemBarKit` as the last import line of every file under `Sources/Host/` that the compiler complains about (run the build; each "cannot find type" names a file), and of the four test files. Do not add it to files that compile without it.

In `Info.plist` change `LSMinimumSystemVersion` to `14.0`.

In `.gitignore`, under the "Local Swift build products" comment, add `build/` beside the existing `SystemBar` and `SystemBar.app/` lines.

- [ ] **Step 4: Build and test**

Run `./build.sh` then `./test.sh`. Expected: `Built …/SystemBar.app`, `SystemBarPerformanceTests passed`, and:

```bash
head -3 build/SDK/SystemBarKit.swiftinterface
otool -L SystemBar.app/Contents/MacOS/SystemBar | grep SystemBarKit
otool -l SystemBar.app/Contents/MacOS/SystemBar | grep -A2 LC_RPATH | grep path
```

prints an interface header with `-enable-library-evolution` and `-target arm64-apple-macos14`, a `@rpath/libSystemBarKit.dylib` dependency, and the rpath `@executable_path/../Frameworks`. Also `grep -c "package func\|package var" build/SDK/SystemBarKit.swiftinterface` must print 0: the public interface a plugin compiles against has no `send`. Then the app must still start and list plugins:

```bash
SYSTEMBAR_PLUGINS_FILE=$SCRATCH/plugins-check.json ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins
```

with the file removed first; expected six `ok` lines.

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'MSG'
Build SystemBarKit as a dylib with a stable interface, and link the app and tests against it

The app carries the SDK at Contents/Frameworks and its interface at Contents/Resources/SDK.
Everything builds in Swift 5 mode for macOS 14, which is what the code already needed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- build.sh test.sh Info.plist .gitignore Sources TestSupport.swift SystemBarCapacityTests.swift SystemBarPluginTests.swift SystemBarPerformanceTests.swift
```

---

## Task 5: The loader resolves a class, from a bundle or the compiled-in table

**Files:**
- Create: `Sources/Host/PluginPath.swift`, `Sources/Host/BundleTabSource.swift`, `Sources/Host/HostTabSource.swift`
- Modify: `Sources/Host/TabCatalog.swift`, `Sources/Host/BuiltinTabs.swift`, `Sources/Host/TabLoader.swift`, `Sources/Host/App.swift`, `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Change `MapTabSource` in the test file to the new protocol shape:

```swift
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
```

Add three more fakes at the bottom of the file:

```swift
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

    func principalClass(at url: URL) throws -> AnyClass? {
        if let reason = failures[url.lastPathComponent] {
            throw TabLoadError(description: reason)
        }
        return classes[url.lastPathComponent]
    }
}
```

Add to `runAll()`:

```swift
        testCatalogRefusesADuplicateBeforeConstructingIt()
        testPluginPathResolvesNamesInsideThePlugInsFolder()
        testPluginPathRejectsNamesThatLeaveTheFolder()
        testPluginPathResolvesAbsoluteAndTildePaths()
        testPluginPathRejectsRelativeAndEmptyPaths()
        testBundleSourceReportsEachFailureStep()
        testBundleSourceFindsAPrincipalClassThatAdoptsTabPlugin()
        testHostSourcePrefersABundleOverTheCompiledInTab()
```

Under `// MARK: - Catalog`, add:

```swift
    private static func testCatalogRefusesADuplicateBeforeConstructingIt() {
        CountingTab.constructed = 0
        let source = MapTabSource(types: ["a": CountingTab.self, "b": CountingTab.self])
        let config = PluginConfig(plugins: [entry("a"), entry("b")])
        let tabs = TabCatalog.build(config: config, source: source, host: makeHost())
        expect(tabs.compactMap(\.plugin).count == 1, "one of the two loads")
        expect(CountingTab.constructed == 1, "the duplicate is refused before its init runs, got \(CountingTab.constructed) constructions")
    }
```

Under a new `// MARK: - Bundles` section:

```swift
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
        for bad in ["", "..", "../Other.bundle", "a/b.bundle", "/etc/passwd"] {
            do {
                _ = try PluginPath.resolve(entry(bad), builtInPlugInsURL: plugIns, homeDirectory: "/Users/x")
                expect(false, "the name \"\(bad)\" must be refused")
            } catch {
                expect("\(error)".contains("\"\(bad)\""), "the error quotes the bad name, got: \(error)")
            }
        }
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
            ("Empty.bundle", "NSPrincipalClass"),
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
        expect((try? source.resolve(pathEntry("/nowhere/X.bundle"))) == nil, "a path entry never falls back to the compiled-in table")
    }
```

`temporaryDirectory()` and `entry(_:enabled:)` already exist as private statics of the same enum, so the new tests can call them as written.

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile errors, `resolve` not a member of `TabSource`, `PluginPath`, `BundleTabSource`, `BundleLoading`, `HostTabSource` undefined.

- [ ] **Step 3: The catalog constructs after the check**

In `Sources/Host/TabCatalog.swift` replace the protocol and `makeTab`:

```swift
/// Turns one config entry into a plugin class, or throws. The catalog constructs it, after the
/// duplicate-id check, so a refused duplicate never runs its init.
protocol TabSource {
    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type
}
```

```swift
    private static func makeTab(
        for entry: PluginEntry,
        source: TabSource,
        host: HostServices,
        alreadyLoaded: [String: String]
    ) -> LoadedTab {
        let type: TabPlugin.Type
        do {
            type = try source.resolve(entry)
        } catch {
            // A TabSource throws TabLoadError for its own reasons; anything else (a Foundation
            // error from a bundle, say) should show its message, not Swift's dump of it.
            let reason = (error as? TabLoadError)?.description ?? error.localizedDescription
            return .failed(location: entry.location, reason: reason)
        }
        let id = type.identifier
        if let earlier = alreadyLoaded[id] {
            return .failed(location: entry.location, reason: "the id \"\(id)\" is already used by \"\(earlier)\", which comes earlier in the list")
        }
        return .loaded(location: entry.location, plugin: type.init(host: host))
    }
```

(`build` is unchanged: it still reads `type(of: plugin).identifier` from the loaded plugin.)

In `Sources/Host/BuiltinTabs.swift`, `makeTab(for:host:)` becomes:

```swift
    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        guard let name = entry.name else {
            throw TabLoadError(description: "only the compiled-in tabs can be found by name; a \"path\" entry is a bundle")
        }
        guard let type = Self.types[name] else {
            let known = Self.types.keys.sorted().joined(separator: ", ")
            throw TabLoadError(description: "no compiled-in tab is named \"\(name)\"; the names are \(known)")
        }
        return type
    }
```

In the two built-in tests, `BuiltinTabSource().makeTab(for: X, host: makeHost())` becomes `BuiltinTabSource().resolve(X)`; their assertions ("Weather.bundle" with "CPU.bundle", and "path") still hold against the new messages. Rename `testBuiltinSourceDoesNotTakePathsYet` to `testBuiltinSourceDoesNotTakePaths` (in `runAll()` too).

- [ ] **Step 4: Path rules**

Create `Sources/Host/PluginPath.swift`:

```swift
import Foundation

/// Where a config entry points. A name stays inside the app's own PlugIns folder; a path is
/// absolute or starts with `~/`. Anything else is refused before Bundle sees it.
enum PluginPath {
    static func resolve(_ entry: PluginEntry, builtInPlugInsURL: URL?, homeDirectory: String) throws -> URL {
        if let name = entry.name {
            return try resolveName(name, builtInPlugInsURL: builtInPlugInsURL)
        }
        return try resolvePath(entry.path ?? "", homeDirectory: homeDirectory)
    }

    private static func resolveName(_ name: String, builtInPlugInsURL: URL?) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw TabLoadError(description: "the name \"\(name)\" is not a single file name; a name is a bundle inside the app's PlugIns folder, and anything else needs \"path\"")
        }
        guard let folder = builtInPlugInsURL else {
            throw TabLoadError(description: "this build of SystemBar has no PlugIns folder, so \"\(name)\" cannot be found by name")
        }
        return folder.appendingPathComponent(name)
    }

    private static func resolvePath(_ path: String, homeDirectory: String) throws -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: homeDirectory).appendingPathComponent(String(path.dropFirst(2)))
        }
        throw TabLoadError(description: "the path \"\(path)\" must be absolute or start with ~/")
    }
}
```

- [ ] **Step 5: The bundle source**

Create `Sources/Host/BundleTabSource.swift`:

```swift
import Foundation

/// The two Foundation calls that load a bundle, behind a protocol so the loader's outcomes can
/// be tested without a real dylib.
protocol BundleLoading {
    /// Loads the bundle at `url` and returns its principal class, `nil` when Info.plist names
    /// none, or throws when the bundle is not a bundle or its code will not load.
    func principalClass(at url: URL) throws -> AnyClass?
}

struct FoundationBundleLoader: BundleLoading {
    func principalClass(at url: URL) throws -> AnyClass? {
        guard let bundle = Bundle(url: url) else {
            throw TabLoadError(description: "\(url.lastPathComponent) is not a bundle")
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            throw TabLoadError(description: "\(url.lastPathComponent) would not load: \(error.localizedDescription)")
        }
        return bundle.principalClass
    }
}

/// Resolves an entry to the class inside a `.bundle`: a name inside the app's PlugIns folder, or
/// a path anywhere. Each step that can fail says which one did.
struct BundleTabSource: TabSource {
    let builtInPlugInsURL: URL?
    let homeDirectory: String
    let loader: BundleLoading

    static func standard() -> BundleTabSource {
        BundleTabSource(builtInPlugInsURL: Bundle.main.builtInPlugInsURL, homeDirectory: NSHomeDirectory(), loader: FoundationBundleLoader())
    }

    /// True when a bundle by this name sits in the app's PlugIns folder.
    func hasBundle(named name: String) -> Bool {
        guard let url = try? PluginPath.resolve(PluginEntry(name: name, path: nil, isEnabled: true), builtInPlugInsURL: builtInPlugInsURL, homeDirectory: homeDirectory) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        let url = try PluginPath.resolve(entry, builtInPlugInsURL: builtInPlugInsURL, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TabLoadError(description: "nothing at \(url.path)")
        }
        guard let cls = try loader.principalClass(at: url) else {
            throw TabLoadError(description: "\(url.lastPathComponent) names no NSPrincipalClass in its Info.plist, or that class is not in its code")
        }
        guard let type = cls as? TabPlugin.Type else {
            throw TabLoadError(description: "\(NSStringFromClass(cls)) in \(url.lastPathComponent) does not adopt TabPlugin")
        }
        return type
    }
}
```

- [ ] **Step 6: Bundles first, compiled-in tabs second**

Create `Sources/Host/HostTabSource.swift`:

```swift
import Foundation

/// Stage 2's loader: a name whose bundle exists in PlugIns loads as a bundle; a name with no
/// bundle falls back to the tabs still compiled into the app; a path is always a bundle.
/// Deleted in Stage 3 along with BuiltinTabSource, leaving BundleTabSource alone.
struct HostTabSource: TabSource {
    let bundles: BundleTabSource
    let builtins: BuiltinTabSource

    func resolve(_ entry: PluginEntry) throws -> TabPlugin.Type {
        if let name = entry.name, !bundles.hasBundle(named: name), BuiltinTabSource.types[name] != nil {
            return try builtins.resolve(entry)
        }
        return try bundles.resolve(entry)
    }
}
```

In `Sources/Host/App.swift`, the loader call becomes:

```swift
        let source = HostTabSource(bundles: .standard(), builtins: BuiltinTabSource())
        let loaded = TabLoader.load(store: store, source: source, host: host)
```

- [ ] **Step 7: Run the tests to see them pass**

Expected: `SystemBarPerformanceTests passed`; `./build.sh` succeeds; `--list-plugins` against a fresh temp file still prints six `ok` lines.

- [ ] **Step 8: Commit**

```bash
git add Sources/Host/PluginPath.swift Sources/Host/BundleTabSource.swift Sources/Host/HostTabSource.swift
git commit -m "$(cat <<'MSG'
Resolve each plugins.json entry to a class, from a bundle or the compiled-in table

The catalog now constructs a plugin only after the duplicate-id check, a name must stay
inside the app's PlugIns folder, and a path must be absolute or start with ~/.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- Sources/Host SystemBarPluginTests.swift
```

---

## Task 6: The host schedules collect() and feeds the process summary

**Files:**
- Create: `Sources/Host/PluginScheduler.swift`
- Modify: `Sources/Host/Models.swift` (`MonitorSamplingPlan`), `Sources/Host/UnifiedMonitor.swift`, `Sources/Host/Views/RootView.swift`, `Sources/Host/App.swift`, `SystemBarPluginTests.swift`, `SystemBarPerformanceTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `runAll()` in `SystemBarPluginTests.swift`:

```swift
        testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps()
        testSchedulerCollectsAtOnceWhenATabAppears()
        testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt()
```

A fake at the bottom of the file:

```swift
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
```

Under `// MARK: - Scheduler`:

```swift
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
```

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile errors, `PluginScheduler` undefined and `jobs` has no `feeds:` argument.

- [ ] **Step 3: The scheduler**

Create `Sources/Host/PluginScheduler.swift`:

```swift
import Foundation

/// Runs each plugin's `collect()` on a queue the host owns for it, every `refreshInterval`
/// seconds, only while its tab is showing, and never overlapping: the queue is serial, so a slow
/// collect delays the next tick rather than running beside it. Main thread only.
final class PluginScheduler {
    private struct Slot {
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
    }

    private var slots: [ObjectIdentifier: Slot] = [:]

    func setVisible(_ plugin: TabPlugin, _ isVisible: Bool) {
        let key = ObjectIdentifier(plugin)
        var slot = slots[key] ?? Slot(queue: DispatchQueue(label: "systembar.plugin.\(type(of: plugin).identifier)", qos: .utility), timer: nil)
        slot.timer?.cancel()
        slot.timer = nil
        if isVisible {
            let timer = DispatchSource.makeTimerSource(queue: slot.queue)
            timer.schedule(deadline: .now(), repeating: plugin.refreshInterval, leeway: .milliseconds(Int(plugin.refreshInterval * 100)))
            timer.setEventHandler { [weak plugin] in plugin?.collect() }
            timer.resume()
            slot.timer = timer
        }
        slots[key] = slot
    }
}
```

(`deadline: .now()` is what makes the first collect immediate.)

- [ ] **Step 4: The plan learns about declared feeds**

In `Sources/Host/Models.swift`, `MonitorSamplingPlan`, add above the existing `jobs(isVisible:mode:)`:

```swift
    /// What runs for the selected tab: the compiled-in plan for its mode, if it has one, plus
    /// the shared samplers the plugin declares. A tab from a bundle has no mode.
    static func jobs(isVisible: Bool, mode: MonitorMode?, feeds: Set<SharedFeed>) -> Set<MonitorJob> {
        guard isVisible else { return [] }
        var jobs = mode.map { Self.jobs(isVisible: true, mode: $0) } ?? []
        if feeds.contains(.processes) {
            jobs.insert(.processes)
        }
        // .fastStats is not a job here: the 1-second sampler already runs whenever the window is open.
        return jobs
    }
```

In `Sources/Host/UnifiedMonitor.swift`: `private var activeMode = MonitorMode.memory` becomes `private var activeMode: MonitorMode?` plus `private var activeFeeds: Set<SharedFeed> = []`; `visibleJobs` becomes `MonitorSamplingPlan.jobs(isVisible: isWindowVisible, mode: activeMode, feeds: activeFeeds)`; and `updatePresentation` becomes:

```swift
    func updatePresentation(isVisible: Bool, mode: MonitorMode?, feeds: Set<SharedFeed>) {
        slowQueue.async { [weak self] in
            guard let self else { return }
            let becameVisible = isVisible && !self.isWindowVisible
            let changed = mode != self.activeMode || feeds != self.activeFeeds
            self.isWindowVisible = isVisible
            self.activeMode = mode
            self.activeFeeds = feeds

            if becameVisible || changed {
                self.collectVisibleStats()
            }
        }
    }
```

Add, next to `start()`, the bridge into the host's feed (Stage 3 replaces this with a host-owned sampler):

```swift
    private var feedSinks: [AnyCancellable] = []

    /// Every process summary and fast sample this monitor publishes also goes to the host's
    /// feeds, so a plugin from a bundle reads the same readings the compiled-in tabs do.
    func forward(processes: Feed<ProcessSummary>, fastStats: Feed<FastStatsSnapshot>) {
        feedSinks = [
            $processSummary.dropFirst().sink { processes.send($0) },
            $fastStats.dropFirst().sink { fastStats.send($0) },
        ]
    }
```

with `import Combine` at the top of the file.

- [ ] **Step 5: The window uses both**

In `Sources/Host/Views/RootView.swift` add `let scheduler: PluginScheduler` after `configPath`, and replace `present`:

```swift
    /// Tells the scheduler and the monitor what the selected tab needs. A compiled-in tab still
    /// keys the monitor's own samplers by MonitorMode; a tab from a bundle has no mode and gets
    /// only the feeds it declares; an error tab or an empty list needs nothing.
    private func present(index: Int, isVisible: Bool) {
        let plugin = loadedPlugin(at: index)
        plugin?.visibilityChanged(isVisible: isVisible)
        if let plugin {
            scheduler.setVisible(plugin, isVisible)
        }
        monitor.updatePresentation(
            isVisible: isVisible && plugin != nil,
            mode: (plugin as? MonitorBackedTab)?.monitorMode,
            feeds: plugin?.sharedFeeds ?? []
        )
    }
```

In `Sources/Host/App.swift` add `private let scheduler = PluginScheduler()`, pass it: `RootView(monitor: UnifiedMonitor.shared, tabs: tabs, configPath: configPath, scheduler: scheduler)`, and after the `--list-plugins` block in `init()` add:

```swift
        UnifiedMonitor.shared.forward(processes: processes, fastStats: fastStats)
```

- [ ] **Step 6: Fix the sampling-plan test and run everything**

In `SystemBarPerformanceTests.swift`, `testSamplingPlan` still calls the two-argument `jobs`, which still exists; no change needed. Run `./test.sh`; expected `SystemBarPerformanceTests passed`, and `./build.sh` succeeds. Then open the app against the fresh temp config (`./SystemBar.app/Contents/MacOS/SystemBar &`), click the icon, switch tabs, and confirm the panels still update and the Memory tab still shows its process list (the compiled-in path is unchanged). Quit it.

- [ ] **Step 7: Commit**

```bash
git add Sources/Host/PluginScheduler.swift
git commit -m "$(cat <<'MSG'
Schedule each plugin's collect() on its own queue while visible, and feed it the process summary

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- Sources/Host SystemBarPluginTests.swift
```

---

## Task 7: Power moves out to Plugins/Power and loads as a bundle

**Files:**
- Create: `Plugins/Power/Info.plist`, `Plugins/Power/Sources/PowerPlugin.swift`, `Plugins/Power/Sources/PowerModels.swift`, `Plugins/Power/Sources/PowerCollector.swift`, `Plugins/Power/Sources/PowerPanel.swift`, `Plugins/Power/Tests/PowerTests.swift`, `build-plugin.sh`
- Delete: `Sources/Host/UnifiedMonitor+Power.swift`, `Sources/Host/Views/PowerPanel.swift`
- Modify: `Sources/Host/Models.swift`, `Sources/Host/UnifiedMonitor.swift`, `Sources/Host/BuiltinTabs.swift`, `build.sh`, `test.sh`, `SystemBarPerformanceTests.swift`, `SystemBarPluginTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Plugins/Power/Tests/PowerTests.swift`, moving `testBatteryParsing` and `testParseSleepAssertions` out of `SystemBarPerformanceTests.swift` (delete them and their two calls there) and retargeting them:

```swift
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
```

The two moved tests are the existing ones with `UnifiedMonitor.` replaced by `PowerCollector.`. Call `MainActor.assumeIsolated { PowerTests.runAll() }` from `SystemBarPerformanceTests.main()` where `testBatteryParsing()` was (the same way `SystemBarPluginTests.runAll()` is called there), and delete the `testParseSleepAssertions()` call and both bodies there.

In `SystemBarPluginTests.swift`:
- `testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode`: the count becomes 5, and the order assertion compares against `MonitorMode.allCases` (which will have five cases).
- `testEveryDefaultNameIsABuiltin` becomes `testEveryCompiledInTabIsInTheDefaultList`: `expect(Set(BuiltinTabSource.types.keys).isSubset(of: DefaultPlugins.names), …)`, `expect(DefaultPlugins.names.count == 6 && Set(DefaultPlugins.names).count == 6, "six distinct default names")`, and the `.bundle` suffix check over `DefaultPlugins.names`.
- `testLoaderWritesTheDefaultAndLoadsSixTabsOnFirstRun` uses `BuiltinTabSource()` as its source, so with Power gone the first entry fails. Change the title expectation to `["Error", "Dev", "Memory", "Disk", "Network", "CPU"]` with the message "a fresh file lists every default; the five compiled-in tabs load and Power, now a bundle, cannot come from the built-in table", and add `if case let .failed(_, reason)? = loaded.first { expect(reason.contains("Power.bundle"), "the failure names the entry, got \(reason)") }`. (The real loader with the bundle present is checked by Task 8's boundary test.)

In `SystemBarPerformanceTests.swift`, `testSamplingPlan`: delete the `.power` line and the `powerRefreshInterval` line.

- [ ] **Step 2: Run the tests to see them fail**

Expected: compile errors, `PowerCollector`, `PowerPlugin`, `DefaultPlugins` undefined (the test file is not compiled yet either; that is fine, the errors above come first).

- [ ] **Step 3: The plugin**

`Plugins/Power/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Power</string>
  <key>CFBundleIdentifier</key>
  <string>com.ih8celery.systembar.power</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Power</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>SystemBarPowerPlugin</string>
</dict>
</plist>
```

`Plugins/Power/Sources/PowerModels.swift` (moved from `Models.swift`, where both are deleted):

```swift
import Foundation
import SystemBarKit

struct PowerContributor: Identifiable {
    var id: String { name }
    let name: String
    let evidence: String
}

struct PowerSnapshot {
    var powerSource = "Unknown"
    var thermalState = "Unknown"
    var batteryPercent: Int?
    var isCharging: Bool?
    var sleepAssertions: [String] = []
    var contributors: [PowerContributor] = []
    var status = "Waiting for power sample"
    var health = SampleHealth.degraded
    var lastUpdated: Date?
}
```

`Plugins/Power/Sources/PowerCollector.swift` (the static half of the old `UnifiedMonitor+Power.swift`, with `runProcess` replaced by the host):

```swift
import Foundation
import SystemBarKit

/// Two pmset reads and the parsing of them. Pure apart from `collect(using:)`.
enum PowerCollector {
    static func collect(using host: HostServices) -> PowerSnapshot {
        let battery = host.run(path: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let assertions = host.run(path: "/usr/bin/pmset", arguments: ["-g", "assertions"])
        let parsedBattery = parseBatteryStatus(battery.output)
        let parsedAssertions = assertions.status == 0 ? parseSleepAssertions(assertions.output) : []
        var status: [String] = []
        if battery.status != 0 { status.append("battery unavailable") }
        if assertions.status != 0 { status.append("assertions unavailable") }

        return PowerSnapshot(
            powerSource: parsedBattery.powerSource,
            thermalState: thermalStateLabel(ProcessInfo.processInfo.thermalState),
            batteryPercent: parsedBattery.percent,
            isCharging: parsedBattery.isCharging,
            sleepAssertions: parsedAssertions,
            contributors: [],
            status: status.isEmpty ? "Power sample OK" : status.joined(separator: ", "),
            health: SampleHealth(isOK: status.isEmpty),
            lastUpdated: Date()
        )
    }

    static func contributors(from rows: [ProcessSnapshot]) -> [PowerContributor] {
        rows.prefix(5).map { row in
            PowerContributor(
                name: row.name,
                evidence: "\(percentString(row.cpu)) CPU, \(byteString(row.physical)) memory"
            )
        }
    }

    static func parseBatteryStatus(_ output: String) -> (powerSource: String, state: String, percent: Int?, isCharging: Bool?) {
        var powerSource = "Unknown power"
        var state = "Battery unavailable"
        var percent: Int?
        var isCharging: Bool?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Now drawing from") {
                powerSource = line
                    .replacingOccurrences(of: "Now drawing from", with: "")
                    .replacingOccurrences(of: "'", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.contains("%;") {
                let parts = line.components(separatedBy: ";").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let percentPart = parts.first,
                   let percentToken = percentPart.split(whereSeparator: \.isWhitespace).last {
                    percent = Int(percentToken.replacingOccurrences(of: "%", with: ""))
                }
                if parts.count > 1 {
                    state = parts[1]
                    let lower = state.lowercased()
                    isCharging = lower.contains("charging") || lower.contains("charged")
                }
            }
        }

        return (powerSource, state, percent, isCharging)
    }

    static func parseSleepAssertions(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("prevent") && !lower.contains("= 0")
            }
            .prefix(8)
            .map { String($0) }
    }
}
```

`Plugins/Power/Sources/PowerPlugin.swift`:

```swift
import AppKit
import Foundation
import SwiftUI
import SystemBarKit

/// The Power tab as a bundle. The host calls `collect()` on this plugin's queue once a minute
/// while the tab shows; the snapshot is published on the main thread and the panel observes it.
@objc(SystemBarPowerPlugin)
public final class PowerPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "power"
    public let title = "Power"
    public let systemImage = "bolt.heart"
    public let accent = Palette.caution
    public let refreshInterval: TimeInterval = 60
    public let sharedFeeds: Set<SharedFeed> = [.processes]

    @Published var snapshot = PowerSnapshot()
    private let host: HostServices

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
    }

    public func collect() {
        var next = PowerCollector.collect(using: host)
        next.contributors = PowerCollector.contributors(from: host.processes.value.topCPU)
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(PowerPanel(plugin: self))
    }
}
```

`Plugins/Power/Sources/PowerPanel.swift`: the old `Sources/Host/Views/PowerPanel.swift` with `@ObservedObject var monitor: UnifiedMonitor` replaced by `@ObservedObject var plugin: PowerPlugin`, every `monitor.power.` replaced by `plugin.snapshot.`, and `import SystemBarKit` added. Nothing else changes.

- [ ] **Step 4: Remove Power from the host**

- `git rm Sources/Host/UnifiedMonitor+Power.swift Sources/Host/Views/PowerPanel.swift`.
- `Sources/Host/Models.swift`: delete `case power = "Power"` and its `icon` line from `MonitorMode`; delete `PowerContributor` and `PowerSnapshot`; delete `case power` from `MonitorJob`; delete `powerRefreshInterval`; delete the `.power` case from `jobs(isVisible:mode:)`.
- `Sources/Host/UnifiedMonitor.swift`: delete `@Published var powerSnapshot`, `powerQueue`, `powerTimer`, `isCollectingPower`, `var power`, the power timer block in `start()`, the `.power` block in `collectVisibleStats`, `collectPowerIfVisible`, and the `powerTimer?.cancel()` line.
- `Sources/Host/BuiltinTabs.swift`: delete `PowerTab` and its row in `builtins`; move `defaultNames` out into a new type at the top of the file:

```swift
/// What a fresh plugins.json lists, in today's tab order. Power is a bundle in PlugIns; the
/// other five are still compiled in until Stage 3.
enum DefaultPlugins {
    static let names = ["Power.bundle", "Dev.bundle", "Memory.bundle", "Disk.bundle", "Network.bundle", "CPU.bundle"]
}
```

and change `TabLoader` (and any other user of `BuiltinTabSource.defaultNames`) to `DefaultPlugins.names`.

- [ ] **Step 5: build-plugin.sh and the build scripts**

Note: since Task 4's review, the app ships only `Contents/Resources/SDK/SystemBarKit.swiftinterface` (no binary module), `build/SDK/` still holds everything, and `build.sh`/`test.sh` source `toolchain.env` for `target`, `swift_version`, `package_name`; the test binary is `build/SystemBarTests`. Read the current scripts before editing them.

Create `build-plugin.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

# Builds one plugin directory into a .bundle against SystemBar's SDK.
#
#   ./build-plugin.sh <plugin dir> <output .bundle> [<SystemBar.app | build dir>]
#
# The plugin dir holds Info.plist (CFBundleExecutable names the binary, NSPrincipalClass names
# the @objc class) and Sources/*.swift. The third argument is where the SDK is: a built
# SystemBar.app (Contents/Resources/SDK and Contents/Frameworks), or this repository's build/
# directory. It defaults to SystemBar.app next to this script.

src="$1"
out="$2"
base="${3:-$(cd "$(dirname "$0")" && pwd)/SystemBar.app}"

if [[ -d "$base/Contents/Resources/SDK" ]]; then
  sdk="$base/Contents/Resources/SDK"
  libs="$base/Contents/Frameworks"
elif [[ -d "$base/SDK" ]]; then
  sdk="$base/SDK"
  libs="$base/Frameworks"
else
  echo "build-plugin.sh: no SDK at $base (expected SystemBar.app or a build/ directory)" >&2
  exit 64
fi

name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$src/Info.plist")

# The interface header records the target and language mode the SDK was built with; building
# the plugin with the same two means the two always agree, whatever toolchain.env says today.
flags=$(grep -m1 '^// swift-module-flags:' "$sdk/SystemBarKit.swiftinterface")
target=$(sed -E 's/.*-target ([^ ]+).*/\1/' <<< "$flags")
swift_version=$(sed -E 's/.*-swift-version ([^ ]+).*/\1/' <<< "$flags")
if [[ -z "$target" || -z "$swift_version" ]]; then
  echo "build-plugin.sh: could not read -target and -swift-version from $sdk/SystemBarKit.swiftinterface" >&2
  exit 65
fi

rm -rf "$out"
mkdir -p "$out/Contents/MacOS"

# An app ships only the textual interface, which the compiler turns into a module on first use;
# it gets its own cache so that never depends on, or pollutes, the system one.
# @executable_path is the app that loads the bundle, so the SDK is found wherever the bundle lives.
# No -package-name here: a plugin sees only the SDK's public interface.
swiftc \
  -emit-library -parse-as-library -module-name "$name" \
  -swift-version "$swift_version" -target "$target" \
  -module-cache-path "${TMPDIR:-/tmp}/systembar-plugin-module-cache" \
  -I "$sdk" -L "$libs" -lSystemBarKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework SwiftUI -framework AppKit \
  -o "$out/Contents/MacOS/$name" \
  $(find "$src/Sources" -name '*.swift' | sort)
cp -f "$src/Info.plist" "$out/Contents/Info.plist"

echo "Built $out"
```

`chmod +x build-plugin.sh`. In `build.sh`, after the app layout and before the final echo:

```zsh
# 4. Every plugin directory, into the app's PlugIns folder, the way a user's would be built.
for dir in Plugins/*/; do
  name=$(basename "$dir")
  ./build-plugin.sh "$dir" "SystemBar.app/Contents/PlugIns/$name.bundle" build
done
```

In `test.sh`, the source list gains every plugin's sources and tests: after `$(find Sources/Host -name '*.swift' | sort) \` add `$(find Plugins -path '*/Sources/*.swift' -o -path '*/Tests/*.swift' | sort) \`. In `build.sh`, the plugin loop passes `build` as the SDK location (it has the interface and the dylib), so the shipped Power.bundle is built with the same flags a user's bundle gets.

- [ ] **Step 6: Run the tests to see them pass, then the real thing**

`./test.sh` expected `SystemBarPerformanceTests passed`. Then:

```bash
ls SystemBar.app/Contents/PlugIns
rm -f "$SCRATCH/plugins-check.json"
SYSTEMBAR_PLUGINS_FILE=$SCRATCH/plugins-check.json ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins
```

Expected: `Power.bundle`, then the same six `ok` lines as before, the first being `ok power Power Power.bundle`, now produced by loading the bundle. Then open the app against that file, click the icon: the Power tab is first, shows the thermal state, source, battery and assertions, and its Likely Contributors list fills within about ten seconds (the process feed's first sample). Take one screenshot as evidence and quit.

- [ ] **Step 7: Commit**

```bash
git add Plugins build-plugin.sh
git commit -m "$(cat <<'MSG'
Move the Power tab into Plugins/Power and load it as a bundle

build.sh now builds every directory under Plugins/ into Contents/PlugIns with build-plugin.sh,
the same script a person uses for their own tab.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- Plugins build-plugin.sh build.sh test.sh Sources SystemBarPerformanceTests.swift SystemBarPluginTests.swift
```

---

## Task 8: Examples/HelloTab and the boundary check in test.sh

**Files:**
- Create: `Examples/HelloTab/Info.plist`, `Examples/HelloTab/Sources/HelloTab.swift`
- Modify: `test.sh`

- [ ] **Step 1: The smallest plugin that loads**

`Examples/HelloTab/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>HelloTab</string>
  <key>CFBundleIdentifier</key>
  <string>example.systembar.hellotab</string>
  <key>CFBundleName</key>
  <string>HelloTab</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>HelloTabPlugin</string>
</dict>
</plist>
```

`Examples/HelloTab/Sources/HelloTab.swift`:

```swift
import Foundation
import SwiftUI
import SystemBarKit

/// The smallest tab that loads. Copy this directory to start your own; the README's "Writing a
/// plugin" section walks through it.
///
/// The host builds one of these at launch, calls `collect()` on a queue it owns for this plugin
/// every `refreshInterval` seconds while the tab is showing, and puts `makeView()` in the window.
/// `@objc(HelloTabPlugin)` is the name Info.plist's NSPrincipalClass points at.
@objc(HelloTabPlugin)
public final class HelloTabPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "hello"
    public let title = "Hello"
    public let systemImage = "hand.wave"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = 5
    public let sharedFeeds: Set<SharedFeed> = []

    @Published var greeting = "Collecting…"
    private let host: HostServices

    /// Main thread, once, at launch.
    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
    }

    /// Not on the main thread. Do the work here, then publish on main: the panel observes
    /// this object from there. Subprocesses go through the host: a path and arguments, no shell.
    public func collect() {
        let result = host.run(path: "/bin/date", arguments: ["+%H:%M:%S"])
        let time = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = result.status == 0 ? "Hello from a plugin. The time is \(time)." : "date failed: \(result.error)"
        DispatchQueue.main.async { [weak self] in
            self?.greeting = text
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(HelloTabView(plugin: self))
    }
}

struct HelloTabView: View {
    @ObservedObject var plugin: HelloTabPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Hello")
            EvidenceRow(label: "Greeting", value: "Live", detail: plugin.greeting)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
```

- [ ] **Step 2: The boundary check**

Append to `test.sh`, after `build/SystemBarTests` runs:

```zsh
# The one test that crosses a real dylib boundary: a plugin built from the example, against the
# SDK inside the app that build.sh just produced, loaded by the same code a user's would be.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
./build-plugin.sh Examples/HelloTab "$tmp/HelloTab.bundle" SystemBar.app > /dev/null

cat > "$tmp/plugins.json" <<JSON
{ "plugins": [
  { "name": "Power.bundle" },
  { "path": "$tmp/HelloTab.bundle" },
  { "path": "$tmp/Missing.bundle" },
  { "name": "Power.bundle" }
] }
JSON

expected="ok power Power Power.bundle
ok hello Hello $tmp/HelloTab.bundle
error $tmp/Missing.bundle: nothing at $tmp/Missing.bundle
error Power.bundle: the id \"power\" is already used by \"Power.bundle\", which comes earlier in the list"
actual=$(SYSTEMBAR_PLUGINS_FILE="$tmp/plugins.json" ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins)

if [[ "$actual" != "$expected" ]]; then
  echo "Boundary check failed. Expected:" >&2
  echo "$expected" >&2
  echo "Got:" >&2
  echo "$actual" >&2
  exit 1
fi
echo "Boundary check passed: a bundle built against the shipped SDK loads through the real loader"
```

- [ ] **Step 3: Run it, then see the example in the window**

`./test.sh` expected: `SystemBarPerformanceTests passed` then `Boundary check passed…`. Then, by hand, build the example into a user location and load it by path:

```bash
mkdir -p "$SCRATCH/PlugIns"
./build-plugin.sh Examples/HelloTab "$SCRATCH/PlugIns/HelloTab.bundle" SystemBar.app
cat > "$SCRATCH/plugins-check.json" <<JSON
{ "plugins": [ { "path": "$SCRATCH/PlugIns/HelloTab.bundle" }, { "name": "Power.bundle" } ] }
JSON
SYSTEMBAR_PLUGINS_FILE=$SCRATCH/plugins-check.json ./SystemBar.app/Contents/MacOS/SystemBar &
```

Click the icon: the first tab is Hello and within five seconds its row reads "Hello from a plugin. The time is HH:MM:SS.", changing every five seconds. Screenshot, quit.

- [ ] **Step 4: Commit**

```bash
git add Examples
git commit -m "$(cat <<'MSG'
Add Examples/HelloTab and check the real plugin boundary in test.sh

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- Examples test.sh
```

---

## Task 9: Documentation, the spec's decision log, and bug eax

**Files:**
- Modify: `README.md`, `AGENTS.md`, `CLAUDE.md`, `docs/one-page/systembar-tab-plugins.md`

- [ ] **Step 1: README**

Under `## Build`, replace the description of what `build.sh` produces with: `./build.sh` builds the SDK (`libSystemBarKit.dylib` and its `.swiftinterface`), the app, and every tab under `Plugins/`, into `SystemBar.app`; the SDK ships inside the app at `Contents/Frameworks` and `Contents/Resources/SDK`. Keep the existing wording style.

In `## Choosing tabs`, after the JSON example, add one sentence: a `"path"` entry points at a bundle anywhere on disk (absolute, or starting with `~/`), which is how a tab you built yourself is added. Change every `SystemBar --list-plugins` to `./SystemBar.app/Contents/MacOS/SystemBar --list-plugins`.

Add a new section `## Writing a plugin` before `## Requirements` (after Choosing tabs):

````markdown
## Writing a plugin

A tab is a `.bundle` built in Swift against the SDK inside the app. `Examples/HelloTab/` is the smallest one that loads: an `Info.plist` naming the class, and one Swift file with a class that adopts `TabPlugin`, collects on a schedule the app runs for it, and returns a SwiftUI view.

```bash
./build-plugin.sh Examples/HelloTab "~/Library/Application Support/SystemBar/PlugIns/HelloTab.bundle" ~/Applications/SystemBar.app
```

Then add `{ "path": "~/Library/Application Support/SystemBar/PlugIns/HelloTab.bundle" }` to `plugins.json` and press Relaunch. The plugin can run subprocesses through the host (an executable path and arguments, never a shell), read the shared process summary, and use the app's palette and components. The six built-in tabs are being moved to the same shape; `Plugins/Power/` is the first.

A bundle runs inside the app with its privileges. Nothing checks or sandboxes it, so load only bundles you built or trust.
````

- [ ] **Step 2: AGENTS.md and CLAUDE.md**

Keep them identical apart from the title. In `## Build & Test`, the code block becomes:

```bash
./build.sh                                   # SDK dylib, app, every tab under Plugins/, into SystemBar.app
./test.sh                                    # builds, runs the in-process tests, then the plugin boundary check
./build-plugin.sh <dir> <out.bundle> [app]   # one plugin, the way a user builds theirs
```

and the sentence after it: "There is no package manager. `build.sh` invokes `swiftc` once per part: `Sources/Kit` becomes `libSystemBarKit.dylib` with library evolution on, `Sources/Host` becomes the app, and each `Plugins/<Name>/` becomes `Contents/PlugIns/<Name>.bundle`."

Replace the second paragraph of `## Architecture Overview` with:

"The tab bar is being converted to plugins (spec: `docs/one-page/systembar-tab-plugins.md`). `Sources/Kit/` is the SDK: the `TabPlugin` contract, `HostServices` with its `processes` feed, `ProcessRunner`, the shared models and the shared views, all public and built as a dylib whose `.swiftinterface` ships in the app. `Sources/Host/` is the app: it reads `~/Library/Application Support/SystemBar/plugins.json`, resolves each entry to a class (a bundle in `Contents/PlugIns/`, a bundle at a path, or one of the five tabs still compiled in through `BuiltinTabs.swift`), constructs it after the duplicate-id check, and runs its `collect()` on its own queue while visible (`PluginScheduler`). `Plugins/Power/` is the first real bundle. `RootView` renders the loaded list and never names a tab. `UnifiedMonitor.shared` still samples for the compiled-in tabs and feeds the process summary to plugins; it is deleted in Stage 3."

Under `## Conventions & Patterns`, add: "The SDK's public surface is frozen by its `.swiftinterface`: a new `TabPlugin` requirement needs a default in a protocol extension or older bundles stop loading, `SharedFeed` is not frozen so host switches over it need `@unknown default`, and everything builds with `-swift-version 5 -target arm64-apple-macos14` so the interface and the plugins agree. The host's side of a `Feed` (`send`) is `package` access: the app and the tests build with `-package-name SystemBar`, plugins never do, so a plugin can read a feed but not overwrite it. A plugin is constructed on the main thread (`init(host:)` is `@MainActor`), collects on its own queue, and draws on main."

- [ ] **Step 3: The spec's decision log**

Append to the Decision Log in `docs/one-page/systembar-tab-plugins.md`:

```markdown
- 2026-09-24 — Stage 2 SDK rules: `makeView` and `visibilityChanged` are
  `@MainActor`, `collect` runs on the plugin's queue, `HostServices` and its
  closures are `Sendable`, everything builds in Swift 5 mode; adding these later
  would change mangled names — Adam.
- 2026-09-24 — `HostServices.init` is public and the no-shell rule is a
  documented convention; plugins are not sandboxed, so an internal init
  protected nothing — Adam.
- 2026-09-24 — Minimum macOS is 14: the SDK interface records a target, and the
  code already used a macOS 14 API — Adam.
- 2026-09-24 — `init(host:)` is `@MainActor`: the host already constructs on
  main, a plugin's model objects usually are main-actor, and adding the
  attribute after the freeze would break every existing bundle — Claude,
  from code review, for Adam to confirm.
- 2026-09-24 — `Feed.send` is `package` access, not public: a plugin reads a
  shared feed and can never overwrite it for the others — Claude, from code
  review, for Adam to confirm.
- 2026-09-24 — Stage 2 landed: Power loads from `Contents/PlugIns/Power.bundle`
  through the same loader as a user's bundle; a plugin's published changes were
  seen redrawing the host window before any of it was built — Claude, recorded
  for Adam.
```

And in the Plugin Contract's `HostServices` snippet, change `timeout: TimeInterval = 15` to `timeout: TimeInterval = ProcessRunner.defaultTimeout`, note under it that a non-nil `environment` replaces rather than merges, and in the Test Contract change "the host without its `@main`" to say the tests link the built SDK dylib and compile the host, every plugin's sources and tests, and the test files into one binary.

- [ ] **Step 4: Build, test, commit, close the bug**

`./build.sh && ./test.sh` green. Then:

```bash
git commit -m "$(cat <<'MSG'
Document the SDK, build-plugin.sh, and how to write a tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)" -- README.md AGENTS.md CLAUDE.md docs/one-page/systembar-tab-plugins.md
```

The coordinator (not the implementer) closes bug `swift-ui-system-monitor-eax` with the reason that Task 4 set the target and `LSMinimumSystemVersion` to 14.

---

## Done when

- `./test.sh` passes: the in-process tests, then the boundary check that builds `Examples/HelloTab` against the shipped SDK and loads it, Power, a missing path and a duplicate through the real loader.
- `SystemBar.app/Contents/PlugIns/Power.bundle` exists and `--list-plugins` reports `ok power Power Power.bundle` from it.
- The Power tab visibly updates in the popover, including its contributors from the process feed, and the Hello tab's time changes every five seconds.
- `Sources/Kit/` builds as `libSystemBarKit.dylib` with an interface under `Contents/Resources/SDK`; the host and every plugin link it by `@rpath`.
- README, AGENTS.md, CLAUDE.md and the spec describe the layout and the SDK rules; bug `eax` is closed.
