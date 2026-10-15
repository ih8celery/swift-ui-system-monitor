# Every tab becomes a plugin

- **Date:** 2026-09-23
- **Epic:** swift-ui-system-monitor-2ik
- **Blocks:** swift-ui-system-monitor-jhi (Power) and 17o.7 (drop file), which wait for it
- **Status:** approved in conversation 2026-09-23; Stages 1 and 2 shipped; Stage 3 is implemented

## Goal

Let the person running SystemBar choose which tabs the app has, in what order,
and add tabs of their own, by editing one file and restarting the app.

Before this change the six tabs were hard-coded: `RootView` switched over a
`MonitorMode` enum, `UnifiedMonitor` owned every collector, every timer and
every published snapshot, and `MonitorSamplingPlan.jobs` was the one place that
knew which shared samplers each tab needed. Adding a tab meant editing four
files in the host, and nobody but the repository could add one.

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

Verified in the Stage 2 Task 1 spike, using a plain window: a plugin's
`@Published` changes do redraw the host's window at runtime, not just compile.
The original spike never opened a window; everything about Combine and SwiftUI
said it would, because both sides link the same SwiftUI and the same SDK
dylib, but it stayed a claim until that spike put a tab on screen and watched
it update.

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

### D9: May a plugin sample while its tab is hidden?

Decided 2026-10-10 in `systembar-ewy-cpu-machine-state-and-background-sampling.md`
(D2, D3, D7) and adopted by `systembar-ifd-disk-distribution-and-movers.md`.

- **Option A — yes, by declaring a `backgroundInterval`:** nil by default; the
  host keeps calling `collect()` at that cadence while the tab is not showing,
  with a 5-second floor, and makes the first background tick wait two minutes after
  the Mac wakes. Shared feeds stay visible-only.
- **Option B — never:** the guarantee D5 relied on, kept absolute.
- **Option C — a host-sampled background feed:** the host does the hidden work
  and plugins read it.

**Selected: A.** Two tabs need a memory of what normal looks like (the CPU
tab's movers, the Disk tab's size ledger), and a memory that fills only while
someone is looking is not one. Leaving the guarantee is opt-in per plugin, each
opt-in is reported by `--list-plugins` and named in the README, and nothing
changes for a plugin that declares nothing.

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
    /// How often the host calls collect() while this tab is showing. Clamped
    /// to 0.25s...86,400s (one day): NaN, zero and negative values become
    /// 0.25s, infinity and anything larger become one day, and each
    /// substitution is logged.
    var refreshInterval: TimeInterval { get }
    /// Which shared samplers must be running while this tab is showing.
    var sharedFeeds: Set<SharedFeed> { get }
    /// How often the host calls collect() while this tab is NOT showing. Nil (the
    /// default) means never. Clamped to 5s...86,400s. Shared feeds do not run for a
    /// hidden tab. Every wake restarts the cadence with a tick 120s later, so a
    /// slower cadence of your own belongs in your bookkeeping, checked each tick.
    var backgroundInterval: TimeInterval? { get }

    /// @MainActor, and must not do slow work: the host times this call and logs a warning when
    /// it passes 100 ms, so slow work belongs in collect() instead.
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
    case fastStats   // the 1-second CPU (whole machine, per core, user/system) and network counters and their histories
}
```

The `Info.plist` names the class in `NSPrincipalClass`, and the class carries
an `@objc(...)` name so the lookup finds it.

What the host hands every plugin:

```swift
public final class HostServices {
    /// The way a plugin runs a subprocess: explicit path, argument array, no shell.
    /// `environment` exists because an app started by launchd has almost no PATH. A non-nil
    /// `environment` replaces the child's inherited environment entirely; it does not merge.
    public func run(path: String, arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = ProcessRunner.defaultTimeout) -> CommandOutput
    /// Latest value plus a publisher. Reading one does not start the sampler; declaring it
    /// in `sharedFeeds` does.
    public let processes: Feed<ProcessSummary>
    public let fastStats: Feed<FastStatsSnapshot>
    public let homeDirectory: String
    public func log(_ message: String)
}
```

Also exported from the SDK, because every tab uses them: `Palette`,
`EvidenceRow`, `StatPill`, `RateCard`, `SectionTitle`, `SegmentedBar`,
`BarSegment`, `SegmentedLegend`, `ChartUnitLabel`, `LegendLabel`,
`ProgressBar`, `Sparkline`, `DualSparkline`, `ProcessList` (the top-N process
list), `Feed`, `ProcessRunner`, `ProcessCPUScale`, `ProcessTable` (the `ps`
path, its arguments, and `parse`, which turns that output into `PidRecord`s),
the formatting helpers in `ViewFormatting`, and the models that more than one
tab reads (`ProcessSnapshot`, `ProcessSummary`, `FastStatsSnapshot`,
`SampleHealth`, `BoundedHistory`, `CommandOutput`). `ProcessSummary` also
exposes `memoryDisplayLimit`, `cpuDisplayLimit`, and three initializers. Two
bundles can share code only through the SDK, so anything two tabs both need
joins it or, when it is a line or two, is copied.

The host runs two shared samplers of its own, in `HostSamplers`. The 1-second
sampler (CPU percent for the whole machine, each core and the user/system split, and network rates, with 90 seconds of history for the headline figures) runs
whenever the app runs, from launch, window open or closed, so the histories are
full when the window opens and a hidden tab can read a live CPU figure. The
10-second `ps` sampler runs only while the window is open on a tab that
declares `.processes`. With the window closed, or an error tab showing, `ps`
does not run, and no tab is collected except a plugin that declared a
`backgroundInterval` (D9), on its own queue, at that cadence. A
sampler samples at once when it starts, and one that keeps running across a
tab switch keeps its rhythm.

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
the path and the reason. Nothing loaded before a failure is undone. Every
entry resolves to a bundle; no tab is compiled into the host, and a missing
`plugins.json` is written from `DefaultPlugins.names`, the six bundles the app
ships, in their default order.

`TabPresenter` is the one place that hears what is showing: the window opening
or closing, and the selection moving. It tells the tab (`visibilityChanged`),
`PluginScheduler` (which runs that tab's `collect()` on its own queue while it
is visible) and `HostSamplers`.

`SystemBar --list-plugins` performs the same loading, prints one line per entry
(`ok <id> <title> <location as written>` or `error <location as written>:
<reason>` — the location is the entry exactly as written in `plugins.json`,
so a `name` entry prints the name, not the resolved path), and exits without
opening a window. It always exits 0, even when some lines start with `error`,
so a script must read the lines rather than the exit status. It exists so the
boundary can be tested in CI.

The header keeps its Quit button and gains a Relaunch button. Under the
login-item LaunchAgent, Relaunch asks launchd to restart the app
(`launchctl kickstart -k`); otherwise it starts a second copy of the
executable and quits. That is the whole "restart" story.

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

Still no package manager. `toolchain.env` holds the `-target`, `-swift-version`,
and `-package-name` that `build.sh` and `test.sh` both source, so the SDK, the
app, and the tests always agree. `build.sh` makes one `swiftc` call per part: `Sources/Kit` becomes the dylib, `Sources/Host` becomes the app, and
each `Plugins/<Name>/` becomes a bundle via `build-plugin.sh`. The app ships
only the SDK's textual interface at `Contents/Resources/SDK/SystemBarKit.swiftinterface`,
not a binary `.swiftmodule`; `build/SDK/` keeps the binary module the app and
the tests build against directly. `build-plugin.sh <plugin dir> <out.bundle>
[SystemBar.app | build dir]` is the one call a user needs: it reads the
`-target` and `-swift-version` that a built app's or build directory's
`.swiftinterface` was made with, builds against the SDK and frameworks under
that directory with its own module cache under `$TMPDIR`, never passes
`-package-name` (a plugin only ever sees the SDK's public interface), and
exits 64 on a usage error.

Nothing in `Sources/Host/` names a tab. A tab's intervals live in its plugin:
its `refreshInterval`, and any slower cadences in its `<Name>Sampling` enum
next to its models. The host owns only the shared feeds' intervals,
`HostSamplers.fastInterval` and `HostSamplers.processInterval`. The README's
interval table is grouped by tab, and `AGENTS.md` and `CLAUDE.md` describe the
layout, including that the "explicit path, no shell" subprocess rule is
`HostServices.run`.

## Test Contract

Tests are written first at every stage, as the project's rules require.

- **One in-process test binary, as now.** `test.sh` links the SDK dylib that
  `build.sh` just built and compiles the host, every plugin's `Sources/` and
  `Tests/`, and the test files into one binary, `build/SystemBarTests`. Each
  tab's tests live in its own `Plugins/<Name>/Tests/` (the capacity tests in
  `Plugins/Dev/Tests/`); the host's, the loader's and the samplers' tests stay
  in the test files at the top of the repository. The dylib
  boundary a real plugin crosses — a separately built bundle, loaded at
  runtime — is deliberately absent here; these tests are about behaviour.
- **Unit tests that exist before their code:** config decoding, including every
  error case above; path resolution for `name`, absolute and `~` forms; the
  shared-feed start-and-stop rule; the loader's outcome for each failure step,
  driven by a fake bundle source so no real dylib is needed.
- **One boundary check in `test.sh`.** After `build.sh`, build
  `Examples/HelloTab` with `build-plugin.sh` against the SDK inside the
  just-built `SystemBar.app`, write a temporary config naming the app's own
  `Power.bundle`, that HelloTab bundle by `path`, a missing path, and
  `Power.bundle` again as a duplicate, run
  `./SystemBar.app/Contents/MacOS/SystemBar --list-plugins` against it, and
  compare the printed lines. This is the only test that crosses a real dylib
  boundary — a bundle built separately from the app, loaded by the same
  loader a user's bundle goes through — and it runs in CI on the existing
  macOS runner.
- **A fresh-file check in `test.sh`.** Run `--list-plugins` once more against
  a `plugins.json` that does not exist yet, as on a new user's first launch,
  and expect the file to be written and all six tabs to load from the bundles
  inside the app, in the default order.
- **A name check in `test.sh`.** Search the sources for the names of the types
  Stage 3 deleted, and fail if any of them is back.

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
- **Install.** `./build-plugin.sh ~/proj/mc-leases-tab "$HOME/Library/Application
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
- The window closed still means no heavy sampling (only the 1-second counter
  reads), and switching tabs still means `ps` runs only for a tab that wants it.

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
- 2026-09-24 — Stage 1: the popover opens on the first listed tab (Power in a
  fresh file, where it was Memory before); Relaunch is launchd-aware. —
  Claude, recorded for Adam
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
  from code review; confirmed by Adam 2026-09-24, who also asked that the
  no-slow-work-in-init rule be enforced, not just documented (2ik.7).
- 2026-09-24 — `Feed.send` is `package` access, not public: a plugin reads a
  shared feed and can never overwrite it for the others — Claude, from code
  review; confirmed by Adam 2026-09-24 as fair for now. He expects to want
  plugins that drive controls eventually, which needs a host-side channel
  designed when the need is concrete (2ik.8).
- 2026-09-24 — The app ships only the SDK's textual `.swiftinterface`, not the
  binary `.swiftmodule`: the binary would expose `package`-access members to
  anyone who also passed `-package-name SystemBar`, and would let a plugin
  skip the exact compile path a real plugin author uses — Claude, from code
  review; confirmed by Adam 2026-09-24.
- 2026-09-24 — Stage 2 landed: Power loads from `Contents/PlugIns/Power.bundle`
  through the same loader as a user's bundle; a plugin's published changes were
  seen redrawing the host window before any of it was built. The popover
  itself showing `Power.bundle`'s tab was not looked at during Stage 2 — the
  dev build's menu bar icon sat off-screen in the notch overflow — so a
  person should still look once — Claude, recorded for Adam.
- 2026-09-24 — `refreshInterval` is clamped to 0.25s to one day: NaN, zero and
  negative values become 0.25s, infinity and anything larger become one day,
  and each substitution is logged — Claude, from code review.
- 2026-09-24 — The host times each `init(host:)` and logs when it passes 100
  ms: Adam asked that the no-slow-work rule be enforced, and a log line is the
  lightest enforcement that never refuses a working plugin — Adam.
- 2026-09-24 — Stage 3 landed: CPU, Memory, Disk, Network and Dev load from
  `Contents/PlugIns/` through the same loader as Power; `UnifiedMonitor`,
  `MonitorMode`, `MonitorSamplingPlan` and the compiled-in table are gone,
  and nothing in `Sources/Host/` names a tab. The host keeps two samplers of
  its own, for the two shared feeds — Claude, recorded for Adam.
- 2026-09-24 — `PidRecord`/`ProcessTable.parse` and `ProcessList` joined the
  SDK: CPU and Dev both parse `ps`, Memory and CPU both show the top-N list,
  and two bundles can share code only through the SDK. `ProcessTable` also
  carries the `ps` path and arguments, because its parser understands only
  that one column order. A helper of a line or two (`port(from:)`) is copied
  instead of widening the SDK — Claude, from the Stage 3 plan, for Adam to
  confirm.
- 2026-09-24 — CPU's `collect()` is empty and its `refreshInterval` is one
  day, the scheduler's ceiling: everything it shows comes from the two shared
  feeds, so there is nothing for it to collect — Claude, from the Stage 3
  plan, for Adam to confirm.
- 2026-09-24 — The 1-second sampler runs for every visible tab, not only
  those that declare `.fastStats`: the CPU and network histories are 90
  seconds long, and stopping it on a tab switch would leave gaps in them. A
  sampler samples at once when it starts and keeps its rhythm while it keeps
  running; an error tab pauses both — Claude, from the Stage 3 plan, for Adam
  to confirm.
- 2026-09-24 — Dev declares `sharedFeeds = [.fastStats]`, where its old
  adapter said nothing: its capacity grade reads the 1-second CPU figure. It
  changes nothing at run time, but the declaration is now true — Claude, from
  the Stage 3 plan.
- 2026-09-24 — `ProcessSummary` keeps one row-taking init,
  `init(rows:memoryLimit:cpuLimit:)`, with the display limits as its defaults;
  `init(rows:limit:)` is removed, since it was a convenience only tests used.
  Removing a public symbol breaks bundles built against the earlier interface,
  which is allowed only because that interface was never pushed and every
  shipped bundle rebuilds with the app. From here on, public SDK symbols are
  only added — Claude, from 2ik.6, for Adam to confirm.
- 2026-10-10 — D9: chose A — a plugin may declare a `backgroundInterval`; the
  window-closed guarantee is kept unless a plugin opts out, reported by `--list-plugins`
  — Adam, through the CPU and Disk epics.
- 2026-10-10 — `FastStatsSnapshot` gains `perCoreUsage`, `cpuUserPercent` and
  `cpuSystemPercent`, additive, because the host already read every core's ticks
  and only published the sum (CPU epic D5) — Adam.
- 2026-10-10 — CPU's `refreshInterval` is 10 seconds again, superseding the
  2026-09-24 entry: its `collect()` now reads the load average, the thermal
  state and `pmset -g therm`, which the shared feeds do not carry. While showing, it also
  runs `collect()` from its own queue on a thermal-state change, so the
  "never concurrently with itself" promise is one it waives for itself —
  Claude, from the Stage 2 plan, for Adam to confirm.
- 2026-10-10 — Per-plugin `settings` (passed through plugins.json untouched,
  checked only to be an object) and `HostServices.dataDirectory` (one folder
  per identifier under Application Support/SystemBar/PluginData, root
  overridable) join the SDK; the catalog builds one `HostServices` per plugin.
  Spec: systembar-ifd — Adam.
- 2026-10-10 — The Disk tab is the first plugin to declare `backgroundInterval`
  (900 s) and the first to keep state between launches; it saves a size ledger
  in its `dataDirectory` — Adam.
