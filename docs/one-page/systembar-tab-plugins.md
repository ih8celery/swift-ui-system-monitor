# Every tab becomes a plugin

- **Date:** 2026-09-23
- **Epic:** swift-ui-system-monitor-2ik
- **Blocks:** swift-ui-system-monitor-jhi (Power) and 17o.7 (drop file), which wait for it
- **Status:** approved in conversation 2026-09-23, spec awaiting review

## Goal

Let the person running SystemBar choose which tabs the app has, in what order,
and add tabs of their own, by editing one file and restarting the app.

Today the six tabs are hard-coded: `RootView` switches over a `MonitorMode`
enum, `UnifiedMonitor` owns every collector, every timer and every published
snapshot, and `MonitorSamplingPlan.jobs` is the one place that knows which
shared samplers each tab needs. Adding a tab means editing four files in the
host, and nobody but the repository can add one.

After this change a tab is a bundle on disk. The app ships six of them, a
config file lists which to load, and a person can build their own against a
small SDK. Restarting the app is how a change to the list takes effect.

## Every Mechanism Was Verified First

The risky part is loading Swift code from a bundle built separately from the
app and passing SwiftUI values across that boundary. It was spiked before this
was written, in a scratch directory, with three `swiftc` invocations and no
package manager.

| Mechanism | Verified | Result |
|---|---|---|
| Shared SDK as a dylib | `swiftc -emit-library -enable-library-evolution -emit-module-interface` | Builds; emits `.swiftinterface` for plugins built later. Warns that `-language-mode` (`-swift-version`) must be set for interface emission |
| Plugin bundle | `swiftc -emit-library` linked with `-lSystemBarKit` and `-rpath @loader_path/../../../../Frameworks` | Builds; `otool -L` shows it links `@rpath/libSystemBarKit.dylib`, so host and plugin share one copy of the SDK types |
| Loading | `Bundle(url:).load()` then `principalClass as? TabPlugin.Type` | Works when the class is `@objc(Name)` and `Info.plist` names it in `NSPrincipalClass` |
| Construction across the boundary | `cls.init(host:)` with a host-owned `HostServices` object | Works; the plugin called the host's process runner and got the output back |
| SwiftUI across the boundary | `makeView() -> AnyView` | Returns a view built from an `ObservableObject` that lives in the plugin |

Not yet verified, and the first thing Stage 2 must do: that a plugin's
`@Published` changes redraw the host's window at runtime, not just compile. The
spike never opened a window. Everything about Combine and SwiftUI says it will,
because both sides link the same SwiftUI and the same SDK dylib, but it is a
claim until a tab is seen updating.

## Decisions

### D1: What is a plugin, physically?

- **Option A — a loadable bundle:** a `.bundle` holding a dylib and an
  `Info.plist`, loaded at launch. Enabling or disabling a tab is a config edit
  plus a restart. The six existing tabs become the first six bundles.
- **Option B — a source directory compiled in:** the config lists directories
  and `build.sh` compiles them into one binary. No dylib boundary, but changing
  the tab set means a rebuild, and "providing a plugin" means providing source.
- **Option C — a separate process:** any executable printing JSON on a
  schedule, rendered by a generic panel. Any language, but the rich per-tab
  panels would be reduced to what a generic layout can express.

**Selected: A.** It is the only option where "edit the file and restart" is
literally what happens, and where a plugin is a thing you can hand to someone.
Building the six existing tabs the same way proves the SDK is enough before
anyone outside the repository depends on it.

### D2: What does a plugin own?

- **Option A — collector and view, with shared services from the host:** a
  plugin owns its collector, its refresh interval and its panel. The host offers
  the process list, the one-second CPU and network counters, the subprocess
  runner, and the shared look. A shared sampler runs only while a visible plugin
  wants it.
- **Option B — collector and view, nothing shared:** every plugin runs its own
  `ps`. Power, Memory and CPU would each run one every ten seconds.
- **Option C — view only:** the host keeps `UnifiedMonitor`; plugins render.
  A user plugin could only show what the host already collects.

**Selected: A.** It is what `MonitorSamplingPlan.jobs` already does, restated
as something each plugin declares about itself instead of a central switch.

### D3: What format is the config file?

- **Option A — JSON:** parsed by Foundation, zero new code, clear errors.
- **Option B — YAML, parsed by a small in-house parser for a fixed subset.**
- **Option C — YAML, by vendoring the Yams library and its C `libyaml`.**

**Selected: A.** YAML was the original ask, and the README's "no third-party
dependencies" line was worth more than comments in the config file. A JSON
file that the app writes for you when it is missing is easy enough to edit.

### D4: How does this sequence against the open Power and Dev epics?

- **Option A — conversion first:** the Power epic then lands as work inside the
  Power plugin, and proves the SDK carries a real feature.
- **Option B — epics first:** every line added now moves again later.
- **Option C — convert the four untouched tabs, keep Power and Dev in the host
  until their epics finish:** two registration paths for a while.

**Selected: A.** `jhi` and `17o.7` wait for this epic.

### D5: Who schedules collection?

- **Option A — the host:** a plugin declares its interval; the host calls
  `collect()` on a queue it owns for that plugin, only while that tab is on
  screen, never overlapping.
- **Option B — the plugin:** it owns its own timers.

**Selected: A.** A plugin cannot accidentally keep sampling while hidden, which
is the app's oldest guarantee, and a slow or stuck plugin is contained on its
own queue exactly as today's collectors are.

### D6: Do built-in tabs take a shortcut?

- **Option A — no:** they are bundles in `Contents/PlugIns/`, loaded by the
  same code as a user's.
- **Option B — yes:** compiled into the host and registered directly.

**Selected: A.** One loader, one contract, and the app itself is the proof
that the contract is complete. Stage 1 compiles the tabs in temporarily, but
already through the `TabPlugin` protocol, so nothing is thrown away.

### D7: What happens when a plugin cannot load?

- **Option A — an error tab:** the tab still appears, showing the reason and the
  config path.
- **Option B — skip it and log.**

**Selected: A.** A typo in a path should be visible in the app, not in a log
file nobody opens. An empty list shows one tab saying where the file is.

### D8: Where does the config file live?

`~/Library/Application Support/SystemBar/plugins.json`, the macOS convention
for per-user app state. If it is missing at launch the host writes one listing
the six built-ins, so the first run looks exactly like today.

## Plugin Contract

The SDK is one dylib, `SystemBarKit`, shipped inside the app at
`Contents/Frameworks/libSystemBarKit.dylib` with its `.swiftinterface` under
`Contents/Resources/SDK/`. It is built with library evolution on and a fixed
`-swift-version`, so a plugin built against an older SDK still loads as long as
nothing it uses was removed.

A plugin is a class the SDK can name:

```swift
public protocol TabPlugin: AnyObject {
    /// Stable, unique, lowercase. Two loaded plugins with the same id is an error.
    static var identifier: String { get }
    var title: String { get }
    var systemImage: String { get }
    var accent: Color { get }
    /// How often the host calls collect() while this tab is showing.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must be running while this tab is showing.
    var sharedFeeds: Set<SharedFeed> { get }

    init(host: HostServices)
    /// Runs on this plugin's own queue, never concurrently with itself, only while visible.
    func collect()
    /// Called on the main thread when the tab is switched to or away from. Default: nothing.
    func visibilityChanged(isVisible: Bool)
    /// Called on the main thread. The panel observes the plugin's own model objects.
    func makeView() -> AnyView
}

public enum SharedFeed: Hashable {
    case processes   // the 10-second ps summary: top by CPU, top by memory, counts
    case fastStats   // the 1-second CPU and network counters and their histories
}
```

The `Info.plist` names the class in `NSPrincipalClass`, and the class carries
an `@objc(...)` name so the lookup finds it.

What the host hands every plugin:

```swift
public final class HostServices {
    /// The only way built-in plugins run a subprocess: explicit path, argument array, no shell.
    /// `environment` exists because an app started by launchd has almost no PATH.
    public func run(path: String, arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = 15) -> CommandOutput
    /// Latest value plus a publisher. Reading one does not start the sampler; declaring it
    /// in `sharedFeeds` does.
    public let processes: Feed<ProcessSummary>
    public let fastStats: Feed<FastStatsSnapshot>
    public let homeDirectory: String
    public func log(_ message: String)
}
```

Also exported from the SDK, because every tab uses them: `Palette`,
`EvidenceRow`, `StatPill`, `RateCard`, `SectionTitle`, `SegmentedBar`, the
formatting helpers in `ViewFormatting`, and the models that more than one tab
reads (`ProcessSnapshot`, `ProcessSummary`, `FastStatsSnapshot`,
`SampleHealth`, `BoundedHistory`, `CommandOutput`).

A shared feed's sampler runs while at least one visible plugin declares it and
stops when none does. With one tab visible at a time, that is the same rule as
today's `jobs(isVisible:mode:)`, and the host keeps the existing behaviour that
the one-second fast stats run whenever the window is open at all.

## Config Contract

```json
{
  "plugins": [
    { "name": "CPU.bundle" },
    { "name": "Memory.bundle" },
    { "name": "Disk.bundle" },
    { "name": "Network.bundle", "enabled": false },
    { "name": "Power.bundle" },
    { "name": "Dev.bundle" },
    { "path": "~/Library/Application Support/SystemBar/PlugIns/LeaseMonitor.bundle" }
  ]
}
```

- Tab order is list order.
- An entry has exactly one of `name` (a bundle inside the app's own
  `Contents/PlugIns/`) or `path` (absolute, or `~`-prefixed). Both, or neither,
  is an error for that entry.
- `enabled` defaults to true. A disabled entry is kept in the file and skipped.
- Unknown keys are an error, so a misspelt `enabled` cannot silently do
  nothing.
- A file that does not parse produces a single error tab naming the line, and
  no plugins load, rather than a guess at what was meant.

## Loading Contract

For each enabled entry, in order: resolve the path; `Bundle(url:)`; `load()`;
`principalClass as? TabPlugin.Type`; check the id is not already loaded;
`init(host:)`. Each step that fails yields an error tab in that position with
the path and the reason. Nothing loaded before a failure is undone.

`SystemBar --list-plugins` performs the same loading, prints one line per entry
(`ok <id> <title> <path>` or `error <path>: <reason>`), and exits without
opening a window. It exists so the boundary can be tested in CI.

The header keeps its Quit button and gains a Relaunch button, which opens the
app's own bundle URL and then terminates. That is the whole "restart" story.

## Build Contract

```
Sources/
  Kit/        -> Contents/Frameworks/libSystemBarKit.dylib, Contents/Resources/SDK/
  Host/       -> Contents/MacOS/SystemBar
Plugins/
  CPU/Sources/, CPU/Tests/, CPU/Info.plist   -> Contents/PlugIns/CPU.bundle
  Memory/ Disk/ Network/ Power/ Dev/         -> likewise
Examples/
  HelloTab/   -> the smallest plugin that loads, referenced from the README
build.sh          builds the Kit, the host, and every directory under Plugins/
build-plugin.sh   <source dir> <output .bundle> [<app or SDK dir>]; what a user runs
```

Still no package manager. `build.sh` grows from one `swiftc` call to one per
part, and `build-plugin.sh` is the one call a user needs, pointed at the SDK
directory inside a built app.

`UnifiedMonitor` is deleted when the last tab moves out. Each
`UnifiedMonitor+X.swift` and `Views/XPanel.swift` pair becomes `Plugins/X/`.
`MonitorSamplingPlan` goes with it: intervals become each plugin's
`refreshInterval`, and the fast and process intervals belong to the host. The
README's interval table is regrouped by plugin, and `AGENTS.md` and
`CLAUDE.md` describe the new layout, including that the "explicit path, no
shell" subprocess rule is now `HostServices.run`.

## Test Contract

Tests are written first at every stage, as the project's rules require.

- **One in-process test binary, as now.** `test.sh` compiles the Kit, the host
  without its `@main`, every plugin's `Sources/` and `Tests/`, and the shared
  `expect` helper into one binary. The existing capacity and performance tests
  move into `Plugins/Dev/Tests/` and the relevant plugin's `Tests/` and keep
  running unchanged. The dylib boundary is deliberately absent here; these
  tests are about behaviour.
- **Unit tests that exist before their code:** config decoding, including every
  error case above; path resolution for `name`, absolute and `~` forms; the
  shared-feed start-and-stop rule; the loader's outcome for each failure step,
  driven by a fake bundle source so no real dylib is needed.
- **One boundary check in `test.sh`.** After `build.sh`, write a temporary
  config naming a built-in, a missing path and a duplicate, run
  `SystemBar --list-plugins` against it, and compare the printed lines. This is
  the only test that crosses a real dylib boundary, and it runs in CI on the
  existing macOS runner.

## A User Plugin, Walked Through

The example that shaped the SDK surface: a lease activity monitor for `mc`,
the machine capacity tool, which reports which single-copy resources (the iOS
Simulator, an Android emulator, a build slot) are leased and by whom.

- **Identity.** `identifier` is `mc-leases`, title `Leases`, icon `key`,
  `refreshInterval` 30 seconds, `sharedFeeds` empty: it needs nothing from the
  host but the runner.
- **Collect.** `host.run` with the resolved `~/.local/bin/mc`, the arguments
  `resource list --json`, and an `environment` that puts `node` on the PATH. The
  `environment` parameter is why it exists: `mc` is a `#!/usr/bin/env node`
  script, and an app started by launchd has a PATH without `node` on it. The
  plugin decodes the JSON into one row per resource.
- **View.** A `SectionTitle` and one `EvidenceRow` per resource, "ios-simulator
  — 2 of 3 in use" with the holders as detail, all from the SDK. Because the
  panel is the plugin's own SwiftUI, a "release stale leases" button that runs
  `mc resource release --stale` is the plugin's decision, not the host's.
- **Install.** `./build-plugin.sh ~/proj/mc-leases-tab "~/Library/Application
  Support/SystemBar/PlugIns/LeaseMonitor.bundle"`, add a `path` entry to
  `plugins.json`, press Relaunch.

Nothing in the host knows what `mc` is. If the SDK could not carry this
plugin, the SDK would be wrong.

## Expected Outcomes

- The tab bar shows exactly the tabs in `plugins.json`, in that order, and a
  first launch with no file looks identical to today.
- Removing an entry and relaunching removes the tab and stops its sampling.
- A plugin built from `Examples/HelloTab/` with `build-plugin.sh` loads and
  shows a tab, without the repository being edited.
- A wrong path, a bad bundle, or a duplicate id shows up as a tab that says so.
- `UnifiedMonitor` no longer exists; nothing in `Sources/Host/` names a
  specific tab.
- The window closed still means no heavy sampling, and switching tabs still
  means only that tab's samplers run.

## Non-Goals

- No reload without a restart. Relaunch is the mechanism.
- No sandboxing, signing or verification of plugins. A bundle runs inside the
  app with its privileges; the README says so, and says to load only bundles
  you built or trust. The config file is the person's own, under their home.
- No plugins written in anything but Swift against the SDK. A separate-process
  adapter could be written later as a plugin itself.
- No plugin contributions to the menu bar icon, the window size or the header.
- No data between plugins except through host feeds. The Power epic's need for
  the Dev tab's capacity grade becomes a third feed, added when `jhi` lands.
- No change to what any of the six tabs shows. This is a move, not a redesign.
- No YAML.

## Issue Map

Epic swift-ui-system-monitor-2ik, three stage issues (2ik.1 to 2ik.3), each
leaving a working, buildable, tested app:

1. **Config and tab bar.** Kit and host exist as directories; `plugins.json` is
   read and written; tabs appear in list order and can be disabled; the six
   tabs still compile into the host but register through `TabPlugin`.
2. **First real bundle.** The Kit becomes a dylib, Power moves out to
   `Plugins/Power/`, the loader, error tabs, `--list-plugins`, `build.sh` and
   `build-plugin.sh` land, `Examples/HelloTab/` exists, and the runtime redraw
   question above is answered.
3. **The rest.** CPU, Memory, Disk, Network and Dev move out; `UnifiedMonitor`
   and `MonitorSamplingPlan` are deleted; README, AGENTS.md and CLAUDE.md are
   rewritten for the layout.

## Decision Log

- 2026-09-23 — D1: chose A — a loadable bundle is the only form where "edit
  and restart" is literal — Adam.
- 2026-09-23 — D2: chose A — plugins own collector and view, shared samplers
  come from the host — Adam.
- 2026-09-23 — D3: chose A — JSON over a YAML parser or a vendored library —
  Adam.
- 2026-09-23 — D4: chose A — conversion lands before the Power and Dev work
  continues — Adam.
- 2026-09-23 — D5 to D8 proposed by Claude, accepted with the design — Adam.
