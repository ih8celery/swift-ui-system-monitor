# SystemBar

A single menu bar icon for Memory, CPU, Disk, Network, and Power — instead of five separate ones.

![SystemBar screenshot](screenshot.png)

SystemBar replaces a cluttered row of individual menu bar monitors with one icon and a tabbed popover. Tap between tabs to see memory pressure, per-process CPU share, where disk space goes, network throughput, and battery/power state, all sampled live from macOS kernel APIs.

## The tabs

| Tab | What it shows |
|---|---|
| **CPU** | Total load, process count, a 90-second history graph, and the top processes by CPU with their memory |
| **Memory** | Used and available the way Activity Monitor counts them, the kernel's pressure level, the wired/active/inactive/compressed/free breakdown, swap, how busy the GPU is and how much memory it holds, and top processes by memory |
| **Disk** | Free and used space per volume, Time Machine local snapshots, a map of which folders hold the space, and what grew or shrank over the last day or week, measured by scans that run in the background and saved between launches, every number stamped with its age. Free is what `df` reports; Finder's Available also counts purgeable space, so it can read higher |
| **Network** | Live up/down bandwidth, which processes are talking and where to, latency, and an on-demand speed test |
| **Power** | Battery and power source, and the sleep assertions keeping your Mac awake with their likely causes |
| **Dev** | How much capacity the machine has left, and which projects are using it: one row per project with the kind of expensive work it is running (builds, simulators, test runs, bundlers, automation) and its measured CPU, memory and disk I/O, plus listening ports grouped by the project serving them |

## Choosing tabs

Which tabs appear, and in what order, comes from a file the app writes the first time it runs:

```
~/Library/Application Support/SystemBar/plugins.json
```

It lists the six tabs above. Reorder the entries to reorder the tabs, set `"enabled": false` on one to hide it, and press the Relaunch button in the popover header (the circular arrow next to Quit) or quit and reopen to apply the change. The first tab listed is the one that opens, so a fresh file opens on Power.

```json
{ "plugins": [
  { "name": "Memory.bundle" },
  { "name": "CPU.bundle" },
  { "name": "Power.bundle", "enabled": false }
] }
```

A `"path"` entry points at a bundle anywhere on disk (absolute, or starting with `~/`), which is how a tab you built yourself is added.

An entry may carry a `"settings"` object for its plugin. The app checks only that it is an object; the keys are the plugin's own, and a plugin reports a value it cannot use in its own panel rather than refusing to load. The Disk tab reads one key: `"backgroundScans": false` stops its folder scans from running while the window is closed.

```json
{ "plugins": [
  { "name": "Disk.bundle", "settings": { "backgroundScans": false } }
] }
```

An entry the app cannot load, say a misspelt name, still gets a tab: it is titled Error and shows the entry, what went wrong, and where the file is, so a typo is never silent. A file that cannot be read or parsed at all gives one Error tab and nothing else. A key the app does not know, or a value of the wrong type, is reported with its place in the file. Two things the parser cannot catch: a trailing comma is accepted, and if a key appears twice the first one wins.

`./SystemBar.app/Contents/MacOS/SystemBar --list-plugins` prints the same outcome to the terminal, one line per enabled entry, and exits without opening a window (on a fresh machine it creates the file, just like a normal launch). It always exits 0, even when a line reports an error, so a script has to look at the text of each line rather than the exit code; a line for a failed entry starts with `error`, and the location it shows for a `name` entry is the name as written in `plugins.json` (say `Power.bundle`), not a resolved path. A plugin that samples while hidden has `background every <n>s` at the end of its line. `SYSTEMBAR_PLUGINS_FILE=/some/other.json` points one run at a different file.

Relaunch restarts the app in place: when SystemBar was installed as a login item it asks launchd to restart it, and otherwise it starts a fresh copy and quits. If a relaunch fails, the reason goes to the system log.

## Writing a plugin

A tab is a `.bundle` built in Swift against the SDK inside the app. `Examples/HelloTab/` is the smallest one that loads: an `Info.plist` naming the class, and one Swift file with a class that adopts `TabPlugin`, collects on a schedule the app runs for it, and returns a SwiftUI view.

```bash
./build-plugin.sh Examples/HelloTab "$HOME/Library/Application Support/SystemBar/PlugIns/HelloTab.bundle" ~/Applications/SystemBar.app
```

Then add `{ "path": "~/Library/Application Support/SystemBar/PlugIns/HelloTab.bundle" }` to `plugins.json` and press Relaunch. The plugin can run subprocesses through the host (an executable path and arguments, never a shell), read the shared process summary (`host.processes.value` now, or `host.processes.publisher` to follow it, as `Plugins/Power/` does), and use the app's palette and components. Give your plugin its own executable name in Info.plist (it doubles as the Swift module name, so make it a valid identifier) and its own `@objc(...)` class name; the app refuses a bundle whose class name another loaded bundle already defines.

Every tab the app ships is built this way, under `Plugins/`: `Plugins/Power/` is the smallest, and `Plugins/Network/` shows following the 1-second feed and running slow work on a queue of its own.

A plugin says in `sharedFeeds` which of the host's two shared readings it uses, and the host samples only what the showing tab asks for:

| Feed | What it holds | When the host samples it |
|---|---|---|
| `.fastStats` | CPU percent (the whole machine, each core, and the user/system split) and network rates, with 90 seconds of history for the headline figures | Every second while the window is open, whatever the tab, so the history has no gaps |
| `.processes` | The top processes by CPU and by memory | Every 10 seconds, only while a tab that declares it is showing |

Nothing is sampled while the window is closed, unless a plugin declares a `backgroundInterval`: then the app keeps calling that plugin's `collect()` at that cadence while its tab is hidden, on the plugin's own queue, with a floor of 5 seconds. The first such call after the Mac wakes waits two minutes, so nothing lands on the login moment. The shared feeds run for the open window and its showing tab, never for a hidden one, so a background `collect()` samples for itself. The table below says which tabs sample while hidden; `--list-plugins` reports it too, as `background every <n>s` on that plugin's line.

To test a plugin that follows a feed, make the feed with `Feed.forTesting(initial:)`. It returns a new feed and a closure that writes to that feed alone, the way the host writes its own; a plugin cannot write the host's feeds, so this is the only writer it gets. Hand the feed to a `HostServices` you build yourself, push a reading, and let the main run loop turn once, because a feed delivers on the main thread:

```swift
@MainActor func testFollowsTheProcessFeed() {
    let (processes, sendProcesses) = Feed.forTesting(initial: ProcessSummary())
    let host = HostServices(
        homeDirectory: "/Users/test",
        processes: processes,
        fastStats: Feed(initial: FastStatsSnapshot()),
        runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
        log: { print($0) }
    )
    let plugin = MyPlugin(host: host)  // keeps the top CPU group's name in `busiest`

    sendProcesses(ProcessSummary(rows: [
        ProcessSnapshot(name: "clang", count: 4, physical: 2_000_000_000, virtualSize: 0, cpu: 250)
    ]))
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    assert(plugin.busiest == "clang")
}
```

A plugin's `refreshInterval` is clamped to between 0.25 seconds and one day: NaN, zero, and negative values become 0.25 seconds, and infinity or anything larger becomes one day, with each substitution logged. Build your plugin with the same Xcode as the app, or a newer one — the SDK interface names types from that Xcode's SwiftUI, so an older Xcode cannot read it.

A plugin gets two more things from `HostServices`. `settings` is its entry's `"settings"` object from `plugins.json`, as a `PluginSettings` with typed accessors (`bool(forKey:)`, `number(forKey:)`, `string(forKey:)`); a present key of the wrong type reads as nil from those and non-nil from the subscript, so the plugin can tell the person. The app never checks a key inside `settings`, only that `settings` is an object; `"settings": null` counts as leaving it out, while `"enabled": null` is rejected like any other wrong type. `dataDirectory` is a folder of its own, `~/Library/Application Support/SystemBar/PluginData/<identifier>/`, which may not exist until the plugin creates it; anything a plugin saves between launches goes there and nowhere else. `SYSTEMBAR_PLUGIN_DATA_ROOT=/some/folder` moves the root for every plugin, which is how tests and scripts keep the real folder untouched.

A plugin that needs to keep sampling while its tab is hidden declares `backgroundInterval` (nil by default). The app then calls its `collect()` at that cadence, clamped to between 5 seconds and one day, while the window is closed or another tab is showing, and restarts the cadence with a call two minutes after every wake of the Mac or its screen, so no call lands on the login moment. That restart means a long interval still gets a call soon after each wake: keep one call cheap, and keep any slower cadence (a scan every few hours, say) in your own bookkeeping, checked on each call, as the Disk tab does. It is the same `collect()`; a plugin that wants to do less while hidden keeps a flag from `visibilityChanged(isVisible:)`. Shared feeds do not run for a hidden tab, so a background `collect()` samples for itself. Say in your plugin's README what it runs while hidden and how often; the app reports the cadence in `--list-plugins`.

The SDK's documentation is the doc comments in `Sources/Kit/`. The app ships them beside the interface, as `Contents/Resources/SDK/SystemBarKit.swiftdoc`, so tools that read a module's documentation through the compiler, such as `swift-symbolgraph-extract` (and so DocC), show them for a plugin built against the app. The `.swiftinterface` file itself holds only signatures; the comments themselves are in the repository under `Sources/Kit/`.

The host times how long your plugin's `init(host:)` takes and logs a warning once it passes 100 ms, so put slow work in `collect()` instead of `init(host:)`.

A bundle runs inside the app with its privileges. Nothing checks or sandboxes it, so load only bundles you built or trust.

See `docs/one-page/systembar-tab-plugins.md` for the full contract.

## Requirements

- **macOS 14 (Sonoma) or later** — the SDK's stable interface records that target, and the code already used a macOS 14 API
- **Xcode Command Line Tools**, for `swiftc`:
  ```bash
  xcode-select --install
  ```

There are no third-party dependencies and no package manager. `build.sh` calls `swiftc` directly on the sources.

## Build

```bash
./build.sh
```

`./build.sh` builds the SDK (`libSystemBarKit.dylib` and its `.swiftinterface`), the app, and every tab under `Plugins/`, into a `SystemBar.app` bundle in the repo directory; the SDK ships inside the app at `Contents/Frameworks` and `Contents/Resources/SDK`.

The app is **not code-signed or notarized**. Building it yourself is fine — locally compiled binaries aren't quarantined, so Gatekeeper stays out of the way. But copying the built `.app` to another Mac will trip Gatekeeper there, and rebuilding changes the binary's identity, so macOS may re-ask for any permissions you previously granted.

## Install as a login item

```bash
./install.sh
```

This builds the app, copies it to `~/Applications/SystemBar.app`, and registers a LaunchAgent that keeps it running across login.

To check what's currently installed:

```bash
./install.sh status
```

To uninstall:

```bash
./install.sh uninstall
```

## What SystemBar reads from your system

It's a system monitor, so it looks at your processes, disks, and network connections. Here is the complete list of what it runs and why — worth reading before you trust any tool like this.

Alongside direct kernel calls (`host_statistics`, `sysctl`, and friends) for CPU, memory, and interface counters, SystemBar shells out to these stock macOS utilities. Every command below starts only while the tab that needs it is showing (a `du` scan or speed test already under way finishes even if you switch away), except where the "While hidden" column of the table further down says a tab keeps sampling with the window closed.

| Command | Used for | How often |
|---|---|---|
| `/bin/ps` | Process list, per-process CPU and memory | Every 10s while the Power, Memory or CPU tab is showing; also every 60s for the Dev tab, with arguments, to work out which project each process belongs to |
| `/usr/sbin/ioreg` | GPU (`AGXAccelerator`) info | Every 30s |
| `/usr/bin/pmset` | Battery state and sleep assertions; thermal and performance warnings; the thermal speed limit | Every 60s for the Power and Dev tabs; every 10s while the CPU tab is showing |
| `/usr/bin/nettop` | Per-process network throughput | Every 30s |
| `/usr/sbin/lsof` | Active TCP connections; listening ports for the Dev tab; working directories of running build/test/bundler processes, to name the project each belongs to | Every 30–60s |
| `/usr/bin/tmutil` | Count of Time Machine local snapshots | Every 30s |
| `/usr/bin/du` | Folder sizes for the Disk tab's map: one level under home, `~/Library`, `/Applications`, `/opt` and `/Library` every 3 hours; under the developer folders (`~/Library/Application Support`, `Containers`, `Group Containers`, `Developer/Xcode`, `~/.cache`, `~/.ollama`, `~/.android`, `~/proj`) and each simulator device every 6 hours | One `du` per folder, on those cadences while the Mac is awake, or all at once on the Disk tab's rescan button |
| `/usr/bin/xcrun` | `simctl list devices -j`, to name each simulator device folder and say when it last booted | Once per simulator scan, every 6 hours |
| `/usr/bin/networkQuality` | Speed test | **Only when you press the button** |

Three things worth calling out:

- **The Dev tab guesses which project a process belongs to, and says so when it cannot.** It reads absolute paths out of a process's command line and walks up to the nearest enclosing `.git` directory, treating that repository as the project. Only paths inside your home directory count, and repositories in hidden directories are ignored, so a tool that installs itself into Git — Homebrew does — cannot pose as a project of yours. Per-project CPU, memory and disk I/O come from two `proc_pid_rusage` reads a second apart across only the processes that matched a category. Anything that cannot be measured that way says "not measurable" rather than showing a zero. When the arguments name nothing — real Swift builds pass relative source paths — one `lsof` call asks for the working directories of the handful of processes actually running, capped at 64 per sample, and the repository they run in names them. Xcode builds are never given a CPU figure at all: the compile jobs are replaced between reads and a finished process's CPU time is gone with it, while the build driver that does survive spends its time waiting on children at a fraction of a percent. A build therefore shows as work being done, with no number attached, and the whole-machine CPU figure at the top of the tab is what reflects its cost.

- **The disk scan reads folder sizes only, and remembers them.** It runs three plans: an overview of the top-level folders every 3 hours, the developer folders every 6 hours, and each iOS simulator device every 6 hours, each folder by its own `du` with a 5-minute cap and each plan capped at 15 minutes, so one huge or unreadable tree costs only its own row. It reads sizes, never file contents, and never deletes anything; the tab has no cleanup hints, only a map of where the space is and what changed. Sizes are saved in `~/Library/Application Support/SystemBar/PluginData/disk/disk-ledger.json`, every sample for two days and then one a day for thirty, so the popover shows the last scan at once with the age of every number, and the Movers list compares today with a day or a week ago. The plans run while the window is closed: the host calls the Disk tab every 15 minutes while it is hidden, waits two minutes after the Mac wakes, and the tab runs whatever is due. A plan that measured nothing waits its full cadence before trying again, rather than retrying on every call. `"backgroundScans": false` in the tab's settings stops that; the rescan button still works. Because `~/Library/Containers` and `~/Library/Group Containers` are on the list, macOS may ask for Files and Folders permission the first time. A folder it refuses is never recorded as empty: a `du` that fails leaves that folder's earlier size in place, and a root that cannot be listed at all keeps its folders' earlier sizes rather than marking them freed. The footer keeps the last scan's summary when something was not measured.
- **The speed test is the only thing that leaves your machine.** Pressing it runs Apple's built-in `networkQuality`, which measures throughput against Apple's servers (`mensura.cdn-apple.com`). Nothing else here sends data anywhere; every other reading is computed locally and stays on your Mac. There is no telemetry, analytics, or crash reporting.

SystemBar runs entirely as your user. It never asks for `sudo` or elevated privileges, and the tabs that ship with the app and the host itself launch every subprocess with an explicit executable path and argument array — never through a shell. A loaded plugin is not held to that rule and can run whatever it likes with your privileges, which is why you should only install plugins you trust.

### How often each tab samples

Each interval lives in that tab's plugin, next to the code that uses it.

| Tab | Its own sampling | While hidden | Where the number lives |
|---|---|---|---|
| Power | `pmset` every 60s | — | `PowerPlugin.refreshInterval` |
| Dev | `ps`, `lsof`, `pmset` and two usage reads a second apart, every 60s | — | `DevSampling` in `Plugins/Dev/Sources/CapacityModels.swift` |
| Memory | Kernel counters and pressure level every 3s; `ioreg` every 30s | — | `MemorySampling` in `Plugins/Memory/Sources/MemoryModels.swift` |
| Disk | Volumes and `tmutil` every 30s; the overview scan every 3 h and the developer and simulator scans every 6 h, each folder one `du` capped at 5 min and each plan at 15 min | A due check every 15 min, unless `"backgroundScans": false` | `DiskSampling` in `Plugins/Disk/Sources/DiskModels.swift` |
| Network | `nettop` and `lsof` every 30s; `networkQuality` only on the button | — | `NetworkSampling` in `Plugins/Network/Sources/NetworkModels.swift` |
| CPU | Load average, thermal state and `pmset -g therm` every 10s; the headline, history, cluster bars and user/system split come from the 1-second feed | — | `CPUSampling` in `Plugins/CPU/Sources/CPUModels.swift` |

The shared feeds' intervals are `HostSamplers.fastInterval` and `HostSamplers.processInterval` in `Sources/Host/HostSamplers.swift`.

## Test

```bash
./test.sh
```

After the in-process tests, `./test.sh` runs the boundary check: it builds `Examples/HelloTab` against the SDK inside the `SystemBar.app` it just built, then runs `--list-plugins` against a temporary config naming Power, that HelloTab bundle by path, a missing path, and a duplicate — the one test that crosses a real dylib boundary, loading a bundle built separately from the app through the same loader a user's bundle goes through. It then runs `--list-plugins` once more against a `plugins.json` that does not exist yet, as on a new user's first launch, and expects all six tabs to load from the bundles inside the app, in the default order. Last, it searches the sources for the names of the types the move to plugins deleted, and fails if any of them is back.

You can also check the plugin loader from a script, without opening the app: `./SystemBar.app/Contents/MacOS/SystemBar --list-plugins` prints what it would show and exits 0 regardless of whether any line reports an error, so the boundary check in `test.sh` compares the printed lines rather than the exit status. Point `SYSTEMBAR_PLUGINS_FILE` at a temporary file first, so the check reads and writes that instead of your real `plugins.json`.

## Status

This is a personal project maintained casually in spare time — no guarantees on response time, but bug reports, feature requests, and pull requests are genuinely welcome.

## License

MIT — see [LICENSE](LICENSE).
