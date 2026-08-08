# Agent Instructions

This file provides instructions and context for AI coding agents working on this project. It doubles as a quick orientation for human contributors.

## Build & Test

```bash
./build.sh   # Builds SystemBar and SystemBar.app
./test.sh    # Builds and runs the in-process test binary
```

There is no package manager. `build.sh` invokes `swiftc` directly on everything under `Sources/`.

## Architecture Overview

SystemBar is a single-file-per-concern SwiftUI menu bar app. `Sources/UnifiedMonitor.swift` plus its `UnifiedMonitor+*.swift` extensions collect system stats (CPU, memory, disk, network, power, developer processes); `Sources/Views/` renders them as tabs behind one `MenuBarExtra` icon.

## Conventions & Patterns

No SPM — built directly via `swiftc` in `build.sh`. Keep it that way unless there's a concrete reason to add package management overhead.

Subprocesses go through `UnifiedMonitor.runProcess`, which launches an explicit executable path with an argument array and never invokes a shell. Keep it that way — this app reads process and network state, so shell interpolation would be a genuine hazard rather than a style nit.

Sampling intervals live together in `MonitorSamplingPlan` in `Sources/Models.swift`. The README documents them, so changing one means updating both.
