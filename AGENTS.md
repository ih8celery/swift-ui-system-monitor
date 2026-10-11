# Agent Instructions

This file provides instructions and context for AI coding agents working on this project. It doubles as a quick orientation for human contributors.

## Build & Test

```bash
./build.sh                                   # SDK dylib, app, every tab under Plugins/, into SystemBar.app
./test.sh                                    # builds, runs the in-process tests, then the boundary, fresh-file and name checks
./build-plugin.sh <dir> <out.bundle> [app]   # one plugin, the way a user builds theirs
```

There is no package manager. `build.sh` and `test.sh` source `toolchain.env` for the target, Swift version, and package name they must agree on, then `build.sh` invokes `swiftc` once per part: `Sources/Kit` becomes `libSystemBarKit.dylib` with library evolution on, `Sources/Host` becomes the app, and each `Plugins/<Name>/` becomes `Contents/PlugIns/<Name>.bundle`.

## Architecture Overview

SystemBar is a SwiftUI menu bar app: one `MenuBarExtra` icon, and a popover whose tabs are all plugins (spec: `docs/one-page/systembar-tab-plugins.md`). `Sources/Kit/` is the SDK: the `TabPlugin` contract, `HostServices` with its `processes` and `fastStats` feeds, `ProcessRunner`, `ProcessTable`, the shared models and the shared views (including `ProcessList`), all public and built as a dylib whose `.swiftinterface` ships in the app. `Sources/Host/` is the app: it reads `~/Library/Application Support/SystemBar/plugins.json` (writing `DefaultPlugins.names` on first run), resolves each entry to a bundle in `Contents/PlugIns/` or at a path, constructs it after the duplicate-id check, and keeps an error tab in the place of an entry that fails. Each plugin is constructed with a `HostServices` of its own (`HostServices.forPlugin`): the shared feeds and runner, plus its entry's `settings` and a `dataDirectory` under `~/Library/Application Support/SystemBar/PluginData/<id>/` (root overridable with `SYSTEMBAR_PLUGIN_DATA_ROOT`). A plugin that saves anything saves it there; the Disk tab's size ledger is the first. `TabPresenter` is the one place that hears what is showing; it tells the tab, `PluginScheduler` (which runs the tab's `collect()` on its own queue while visible) and `HostSamplers` (the 1-second CPU and network sampler, run whenever the window is open, and the 10-second `ps` sampler, run only while the showing tab declares `.processes`). `RootView` renders the loaded list and never names a tab.

Every tab lives in `Plugins/<Name>/` with its `Info.plist`, `Sources/` and `Tests/`: Power, Dev, Memory, Disk, Network and CPU. Nothing in `Sources/Host/` names one; `test.sh` checks that a fresh `plugins.json` loads all six from the app's bundles.

## Conventions & Patterns

No SPM — built directly via `swiftc` in `build.sh`. Keep it that way unless there's a concrete reason to add package management overhead.

Subprocesses go through `ProcessRunner.run` in `Sources/Kit/` (plugins reach it as `HostServices.run`), which launches an explicit executable path with an argument array and never invokes a shell. Keep it that way — this app reads process and network state, so shell interpolation would be a genuine hazard rather than a style nit.

A tab's sampling intervals live in its plugin: `refreshInterval`, and any slower cadences in its `<Name>Sampling` enum next to its models. The shared feeds' intervals are `HostSamplers.fastInterval` and `HostSamplers.processInterval`. A tab that samples while hidden declares `backgroundInterval`, which the host clamps and reports in `--list-plugins` as `background every <n>s`; `test.sh`'s fresh-file check pins that line, so changing the Disk tab's interval means changing `test.sh` too. The README documents all of them, so changing one means updating both.

The config parser is deliberately strict: a key it does not recognize, or a value of the wrong type, is an error that names its place in the file. So adding a new config key needs a parser change and a test for it, not just a new field on the struct. Tests must never touch the real `~/Library/Application Support/SystemBar/`: `PluginConfigStore` takes the full file URL, `standard()` derives it from `SYSTEMBAR_PLUGINS_FILE` or Application Support, and the tests build their own path inside a temporary folder. Plugin data stays out of it too: `makeHost` in `TestFakes.swift` gives a plugin built directly a `dataDirectory` under the temporary directory, and `testDataRoot` does the same for plugins the catalog or loader builds.

The SDK's public surface is frozen by its `.swiftinterface`: a new `TabPlugin` requirement needs a default in a protocol extension or older bundles stop loading, `SharedFeed` is not frozen so host switches over it need `@unknown default`, and everything builds with the `-swift-version` and `-target` recorded in `toolchain.env` (`5` and `arm64-apple-macos14`) so the interface and the plugins agree. The app ships only the SDK's textual interface and its `.swiftdoc` (the public doc comments, which the interface lacks), not its binary `.swiftmodule`: the binary would expose `package`-access members to anyone who also passed `-package-name SystemBar`, and would let a plugin skip the exact compile path a real plugin author uses. The host's side of a `Feed` (`send`) is `package` access for that reason: the app and the tests build with `-package-name SystemBar` from `toolchain.env`, plugins never do, so a plugin can read a feed but never overwrite it for the others. A plugin is constructed on the main thread (`init(host:)` is `@MainActor`), collects on its own queue, and draws on main. Two names in a plugin's `Info.plist` and code must be unique to it — `CFBundleExecutable` (also its Swift module name) and its `@objc(...)` class name — because every loaded bundle shares one Objective-C runtime; a repeated class name is refused. Bundles cannot share code except through the SDK, so something two plugins both need either joins the SDK (as `ProcessTable` and `ProcessList` did) or, when it is a line or two, is copied.
