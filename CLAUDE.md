# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project. It doubles as a quick orientation for human contributors.

## Build & Test

```bash
./build.sh                                   # SDK dylib, app, every tab under Plugins/, into SystemBar.app
./test.sh                                    # builds, runs the in-process tests, then the plugin boundary check
./build-plugin.sh <dir> <out.bundle> [app]   # one plugin, the way a user builds theirs
```

There is no package manager. `build.sh` and `test.sh` source `toolchain.env` for the target, Swift version, and package name they must agree on, then `build.sh` invokes `swiftc` once per part: `Sources/Kit` becomes `libSystemBarKit.dylib` with library evolution on, `Sources/Host` becomes the app, and each `Plugins/<Name>/` becomes `Contents/PlugIns/<Name>.bundle`.

## Architecture Overview

SystemBar is a single-file-per-concern SwiftUI menu bar app. `Sources/UnifiedMonitor.swift` plus its `UnifiedMonitor+*.swift` extensions collect system stats (CPU, memory, disk, network, power, developer processes); `Sources/Views/` renders them as tabs behind one `MenuBarExtra` icon.

The tab bar is being converted to plugins (spec: `docs/one-page/systembar-tab-plugins.md`). `Sources/Kit/` is the SDK: the `TabPlugin` contract, `HostServices` with its `processes` and `fastStats` feeds, `ProcessRunner`, the shared models and the shared views, all public and built as a dylib whose `.swiftinterface` ships in the app. `Sources/Host/` is the app: it reads `~/Library/Application Support/SystemBar/plugins.json`, resolves each entry to a class (a bundle in `Contents/PlugIns/`, a bundle at a path, or one of the five tabs still compiled in through `BuiltinTabs.swift`), constructs it after the duplicate-id check, and runs its `collect()` on its own queue while visible (`PluginScheduler`). `Plugins/Power/` is the first real bundle. `RootView` renders the loaded list and never names a tab. `UnifiedMonitor.shared` still samples for the compiled-in tabs and feeds the process summary to plugins; it is deleted in Stage 3.

## Conventions & Patterns

No SPM — built directly via `swiftc` in `build.sh`. Keep it that way unless there's a concrete reason to add package management overhead.

Subprocesses go through `ProcessRunner.run` in `Sources/Kit/` (plugins reach it as `HostServices.run`; `UnifiedMonitor.runProcess` is a thin forwarder that goes away with the class), which launches an explicit executable path with an argument array and never invokes a shell. Keep it that way — this app reads process and network state, so shell interpolation would be a genuine hazard rather than a style nit.

Sampling intervals live together in `MonitorSamplingPlan` in `Sources/Models.swift`. The README documents them, so changing one means updating both.

The config parser is deliberately strict: a key it does not recognize, or a value of the wrong type, is an error that names its place in the file. So adding a new config key needs a parser change and a test for it, not just a new field on the struct. Tests must never touch the real `~/Library/Application Support/SystemBar/`: `PluginConfigStore` takes the full file URL, `standard()` derives it from `SYSTEMBAR_PLUGINS_FILE` or Application Support, and the tests build their own path inside a temporary folder.

The SDK's public surface is frozen by its `.swiftinterface`: a new `TabPlugin` requirement needs a default in a protocol extension or older bundles stop loading, `SharedFeed` is not frozen so host switches over it need `@unknown default`, and everything builds with the `-swift-version` and `-target` recorded in `toolchain.env` (`5` and `arm64-apple-macos14`) so the interface and the plugins agree. The app ships only the SDK's textual interface, not its binary `.swiftmodule`: the binary would expose `package`-access members to anyone who also passed `-package-name SystemBar`, and would let a plugin skip the exact compile path a real plugin author uses. The host's side of a `Feed` (`send`) is `package` access for that reason: the app and the tests build with `-package-name SystemBar` from `toolchain.env`, plugins never do, so a plugin can read a feed but never overwrite it for the others. A plugin is constructed on the main thread (`init(host:)` is `@MainActor`), collects on its own queue, and draws on main. Two names in a plugin's `Info.plist` and code must be unique to it — `CFBundleExecutable` (also its Swift module name) and its `@objc(...)` class name — because every loaded bundle shares one Objective-C runtime; a repeated class name is refused.
