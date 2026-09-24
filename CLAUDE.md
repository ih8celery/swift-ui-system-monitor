# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project. It doubles as a quick orientation for human contributors.

## Build & Test

```bash
./build.sh   # Builds SystemBar and SystemBar.app
./test.sh    # Builds and runs the in-process test binary
```

There is no package manager. `build.sh` invokes `swiftc` directly on everything under `Sources/`.

## Architecture Overview

SystemBar is a single-file-per-concern SwiftUI menu bar app. `Sources/UnifiedMonitor.swift` plus its `UnifiedMonitor+*.swift` extensions collect system stats (CPU, memory, disk, network, power, developer processes); `Sources/Views/` renders them as tabs behind one `MenuBarExtra` icon.

The tab bar is being converted to plugins (spec: `docs/one-page/systembar-tab-plugins.md`). `Sources/Kit/` holds the `TabPlugin` contract and `HostServices`; `Sources/Host/` reads `~/Library/Application Support/SystemBar/plugins.json`, builds the tab list (a failed entry keeps its place as an error tab), and holds the relauncher; `Sources/Host/BuiltinTabs.swift` adapts the six existing panels to the contract until each owns its collector, and sampling is still keyed by `MonitorMode` through `MonitorBackedTab.monitorMode`. `RootView` renders that list and never names a tab. `UnifiedMonitor.shared` is the one monitor; its `init` is private, so nothing else can construct a second.

## Conventions & Patterns

No SPM — built directly via `swiftc` in `build.sh`. Keep it that way unless there's a concrete reason to add package management overhead.

Subprocesses go through `ProcessRunner.run` in `Sources/Kit/` (plugins reach it as `HostServices.run`; `UnifiedMonitor.runProcess` is a thin forwarder that goes away with the class), which launches an explicit executable path with an argument array and never invokes a shell. Keep it that way — this app reads process and network state, so shell interpolation would be a genuine hazard rather than a style nit.

Sampling intervals live together in `MonitorSamplingPlan` in `Sources/Models.swift`. The README documents them, so changing one means updating both.

The config parser is deliberately strict: a key it does not recognize, or a value of the wrong type, is an error that names its place in the file. So adding a new config key needs a parser change and a test for it, not just a new field on the struct. Tests must never touch the real `~/Library/Application Support/SystemBar/`: `PluginConfigStore` takes the full file URL, `standard()` derives it from `SYSTEMBAR_PLUGINS_FILE` or Application Support, and the tests build their own path inside a temporary folder.
