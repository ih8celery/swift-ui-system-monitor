# Tab Plugins Stage 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CPU, Memory, Disk, Network and Dev become bundles under `Plugins/`, loaded by the same loader as Power. `UnifiedMonitor` is deleted and nothing in `Sources/Host/` names a tab. A closed window runs no heavy sampler, and switching tabs runs only that tab's samplers. What each tab shows does not change.

**Architecture:** The host keeps exactly two samplers of its own, in `Sources/Host/HostSamplers.swift`: the 1-second sampler (CPU percent and network rates, `FastStatsSampler`) runs whenever the window is open, so the 90-second histories stay continuous across tab switches, and the 10-second process sampler (`ProcessSampler`) runs only while the visible tab lists `.processes`. Both fill the feeds plugins already read through `HostServices`, using `Feed.send` (package access). Everything else a tab samples moves into its own bundle under `Plugins/<Name>/`, collected by `PluginScheduler` on the plugin's own queue only while that tab is showing, exactly as Power is today. `TabPresenter` is the one place that tells the tab, the scheduler and the samplers what is showing; `RootView` only forwards appear, disappear and selection changes to it. The five tabs move one at a time, and each task deletes that tab's slice of `UnifiedMonitor`, `Models.swift`, `MonitorSamplingPlan`, `MonitorMode` and `BuiltinTabs.swift`, so every commit builds, passes, and can be bisected.

**Tech Stack:** Swift 6.3 toolchain in `-swift-version 5` mode, `-target arm64-apple-macos14`, `swiftc` only (no package manager), SwiftUI, Combine, Foundation. Plugins see only the SDK's `.swiftinterface`; the tests compile the host, every plugin's sources and tests, and the test files into one module.

**Decisions already made (issue 2ik.3, 2026-09-24):**

- `Sources/Host/HostSamplers.swift` holds the two shared samplers. API: `update(isVisible:feeds:)`. A sampler that starts samples at once; one that keeps running keeps its rhythm. It owns its timers and one serial queue, and takes its collector closures and intervals in its init so tests can drive it.
- `Sources/Host/FastStatsSampler.swift` holds the rate math, `collectCPUCounters`, `collectNetworkCounters`, `CPUCounters` and `NetworkCounters`. `Sources/Host/ProcessSampler.swift` holds `runPS`, `groupsNeedingRefinement`, `physicalFootprint` and `RawProcessSample`.
- `DefaultPlugins.names` moves into `TabLoader.swift` unchanged. The refresh-interval minimum and maximum become statics on `PluginScheduler`.
- `Sources/Host/TabPresenter.swift`: init with the scheduler and the samplers; `present(plugin: TabPlugin?, isVisible: Bool)` and `switching(from:to:)`. It closes issue 2ik.4.
- The one SDK change the design names: `Sources/Kit/ProcessTable.swift` with `public struct PidRecord` and `public enum ProcessTable { public static func parse(_ output: String) -> [Int32: PidRecord] }`.
- Each bundle has `Info.plist` (Power's with `CFBundleExecutable`, `CFBundleName`, `CFBundleIdentifier com.ih8celery.systembar.<name>` and `NSPrincipalClass SystemBar<Name>Plugin` changed), `Sources/`, and `Tests/`. Each plugin mirrors `PowerPlugin`: `@objc(SystemBar<Name>Plugin) public final class <Name>Plugin: NSObject, TabPlugin, ObservableObject`, `@Published private(set)` state, `@MainActor public init(host:)` that does no slow work, a `collect()` that publishes on main, and `@MainActor makeView()`. The old `isCollectingX` guards are dropped: the scheduler already never overlaps a plugin's collects.

**Where the code forced something the design did not name (each is also in the Decision Log in Task 9):**

1. `ProcessList` (the top-N list view) moves into the SDK as `Sources/Kit/Views/ProcessList.swift`, in Task 1. Memory and CPU both show it, and two bundles can share code only through the SDK. It is a second SDK addition beside `ProcessTable`.
2. `Sources/Host/Capacity/` moves whole into `Plugins/Dev/Sources/Capacity/` in Task 4. A bundle cannot see host types, and those five files are the Dev tab's model.
3. CPU's `refreshInterval` is the literal `86_400` (its `collect()` does nothing; everything it shows comes from the two feeds). A bundle cannot name `PluginScheduler.maximumRefreshInterval`; the CPU test asserts the two are equal, which works because the tests are one module.
4. `MonitorMode` has a raw type, and Swift refuses an enum with a raw type and no cases. So the task that moves the last compiled-in tab (Task 7, Network) must also delete `MonitorMode`, `MonitorJob`, `MonitorSamplingPlan`, `Models.swift`, `MonitorBackedTab`, `BuiltinTabSource`, `HostTabSource.swift`, `HostFormatting.swift` and `UnifiedMonitor*`, and rewrite the loader tests against `MapTabSource`. Task 8 is then `TabPresenter`, the fresh-file boundary check and the name check.
5. One tiny helper is copied rather than shared, because bundles cannot share code: `port(from:)` (Network keeps its own, Dev gets a copy inside `CapacityCollector`). The `ps` command line is not copied: a parser that understands only one exact column order carries that order itself, so `ProcessTable.executable` and `ProcessTable.arguments` sit in the SDK next to `ProcessTable.parse` (Task 1), and CPU and Dev both run `host.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)`.
6. `DefaultPlugins.names` is the one list of tab names left in `Sources/Host/`. It is the default `plugins.json` (spec D8), data rather than code that treats a tab specially, and the name check in Task 8 does not match it.
7. "Sample immediately on a change" is read as "sample when a sampler starts". A sampler already running when the tab changes keeps its rhythm, so switching between two tabs that both want the process feed does not run `ps` twice in a row.
8. With an error tab selected, the samplers get `isVisible: false`, as today: an error tab has nothing to feed.
9. The Dev plugin declares `sharedFeeds = [.fastStats]` (the old adapter said `[]`) because its capacity grade reads the 1-second CPU figure. It changes nothing at run time, since that sampler runs for every visible tab, but the declaration is now true.

**Rules for every task:**

- Every path is absolute; `cd` does not persist between commands. `R` below is shorthand for `/Users/adamu/proj/swift-ui-system-monitor-2ik.3` in prose only; every command spells it out.
- Every test run is exactly this command, never piped into `head`:

  ```bash
  mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
  ```

  A green run ends with `SystemBarPerformanceTests passed` followed by the boundary-check line(s) and `mc`'s own summary.
- Use `git mv` for every move, so history follows the file. Commit with named paths, never a bare commit. A rename needs both its old and its new path in the commit's path list; a new file needs `git add` first.
- Tests never touch `~/Library/Application Support/SystemBar/`. Subprocesses run only through `host.run` or `ProcessRunner.run`, with an explicit path and an argument array, never a shell.
- Line numbers below are from the start of Stage 3 (commit `394d33a`). Earlier tasks shift them, so find each block by the name given with it; the line range is for orientation.
- When a step says "move lines A–B of X unchanged into Y", copy that text exactly and change only what the step lists.
- Immutable data, small functions, files under 800 lines, plain-words comments that say why.

---

## File structure after this stage

```
Sources/
  Kit/                          -> libSystemBarKit.dylib + its .swiftinterface
    ProcessTable.swift          NEW (Task 1): PidRecord, ProcessTable.parse
    Views/ProcessList.swift     NEW (Task 1): the top-N process list (moved out of CPUPanel.swift)
    TabPlugin.swift, HostServices.swift, Feed.swift, ProcessRunner.swift, SharedModels.swift,
    Views/{Palette,SharedComponents,SegmentedBar,ViewFormatting}.swift        unchanged
  Host/                         -> SystemBar.app/Contents/MacOS/SystemBar
    App.swift                   feeds, BundleTabSource.standard(), TabPresenter
    HostSamplers.swift          NEW (Task 2): the 1-second and 10-second samplers and when each runs
    FastStatsSampler.swift      NEW (Task 2, git mv of UnifiedMonitor+FastStats.swift): counters, rate math
    ProcessSampler.swift        NEW (Task 2): ps, grouping, footprint refinement
    TabPresenter.swift          NEW (Task 8): what is showing -> tab, scheduler, samplers
    PluginScheduler.swift       gains minimumRefreshInterval / maximumRefreshInterval statics
    TabLoader.swift             gains DefaultPlugins
    BundleTabSource.swift, PluginConfig.swift, PluginConfigStore.swift, PluginPath.swift,
    TabCatalog.swift, PluginListReport.swift, Relauncher.swift                 unchanged
    Views/RootView.swift        renders the list, forwards visibility to TabPresenter
    Views/ConfigStatusViews.swift                                             unchanged
    (deleted: UnifiedMonitor*.swift, Models.swift, BuiltinTabs.swift, HostTabSource.swift,
     Capacity/, Views/{CPU,Memory,Disk,Network,Developer}Panel.swift, Views/HostFormatting.swift)
Plugins/
  Power/                        unchanged
  Disk/     Info.plist, Sources/{DiskPlugin,DiskCollector,DiskModels,DiskPanel}.swift, Tests/DiskTests.swift
  Dev/      Info.plist, Sources/{DevPlugin,CapacityCollector,CapacityModels,DeveloperPanel}.swift,
            Sources/Capacity/{CapacityGrade,CapacitySnapshot,ProjectAttribution,ProjectLoadRollup,WorkCategory}.swift,
            Tests/{CapacityTests,DevPluginTests}.swift
  Memory/   Info.plist, Sources/{MemoryPlugin,MemoryCollector,MemoryModels,MemoryFormatting,MemoryPanel}.swift,
            Tests/MemoryTests.swift
  CPU/      Info.plist, Sources/{CPUPlugin,ProcessDetail,ProcessClassifier,CPUPanel}.swift, Tests/CPUTests.swift
  Network/  Info.plist, Sources/{NetworkPlugin,NetworkCollector,NetworkModels,SpeedTest,NetworkFormatting,NetworkPanel}.swift,
            Tests/NetworkTests.swift
TestSupport.swift               unchanged (expect)
TestFakes.swift                 gains waitUntil, LogRecorder, recordingRunner, makeHost(fastStats:)
SystemBarConfigTests.swift      unchanged
SystemBarLoaderTests.swift      builtin-table tests replaced by MapTabSource ones (Task 7)
SystemBarSchedulerTests.swift   gains the sampler tests (Task 2) and the presenter tests (Task 8)
SystemBarPerformanceTests.swift the @main runner, plus the Kit and host-sampler tests that stay
SystemBarCapacityTests.swift    -> Plugins/Dev/Tests/CapacityTests.swift (Task 4)
test.sh                         loses SystemBarCapacityTests.swift; gains the fresh-file check (Task 8)
README.md, AGENTS.md, CLAUDE.md, docs/one-page/systembar-tab-plugins.md      Task 9
```

`build.sh` needs no change: it already builds every `Plugins/*/` directory, and `test.sh` already compiles every `Plugins/*/Sources` and `Plugins/*/Tests` file.

### Where every test ends up

| Test (file at the start of Stage 3) | Destination | Task |
|---|---|---|
| `testProcessTableParsing` (Performance) | stays; calls `ProcessTable.parse` | 1 |
| `testRunProcessDrainsLargeStderrConcurrently`, `testRunProcessTimesOutHungCommand` (Performance) | stay; call `ProcessRunner.run` | 1 |
| `testGroupsNeedingRefinement`, `testCollectorsDoNotLeakHostPortRights` (Performance) | stay; call `ProcessSampler` / `FastStatsSampler` (the memory half of the leak test moves to Memory in Task 5) | 2 |
| `testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt` (Scheduler) | deleted; replaced by the `HostSamplers` tests | 2 |
| `testSchedulerClampsABadRefreshInterval` (Scheduler) | stays; reads `PluginScheduler`'s statics | 2 |
| `testDiskVolumeMath` … `testDiskHogScanReportsPermissionTroubleSeparately` (Performance, 11 tests + 3 helpers) | `Plugins/Disk/Tests/DiskTests.swift` | 3 |
| disk and disk-hog lines of `testSamplingPlan` | `DiskTests.testSamplingIntervalsKeepDuRare` | 3 |
| all 24 tests of `SystemBarCapacityTests.swift` | `Plugins/Dev/Tests/CapacityTests.swift` (git mv) | 4 |
| `testListeningPortParsing` (Performance) | `CapacityTests` | 4 |
| capacity lines of `testSamplingPlan` | `DevPluginTests.testSamplingIntervalsStayConservative` | 4 |
| `testSwapStatText`, `testMemorySegmentsMatchEveryBarSegment` (Performance) | `Plugins/Memory/Tests/MemoryTests.swift` | 5 |
| `testParentChainWalk`, `testGroupDetailRows`, `testProcessClassifier` + `detail(...)` helper (Performance) | `Plugins/CPU/Tests/CPUTests.swift` (with a copy of `psSample`) | 6 |
| `testHostnameCacheEntryExpiry`, `testParseCSVLine`, `testParseNettopCSV`, `testParseLsofTCP`, `testIsLANAddress`, `testParseNetworkQualityJSON`, `testParseNetworkQualitySummary` (Performance) | `Plugins/Network/Tests/NetworkTests.swift` | 7 |
| network lines of `testSamplingPlan`, then `testSamplingPlan` itself | `NetworkTests.testPluginIdentityMatchesTheOldTab`; function deleted | 7 |
| `testLoaderWritesTheDefault…`, `…UnparseableFile…`, `…EmptyList` (Loader) | rewritten against `MapTabSource` | 7 |
| `testEveryCompiledInTabIsInTheDefaultList` (Loader) | becomes `testDefaultListNamesSixBundles` | 7 |
| `testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode`, `testBuiltinSourceNamesTheUnknownTab`, `testBuiltinSourceDoesNotTakePaths`, `testHostSourcePrefersABundleOverTheCompiledInTab` (Loader) | deleted with the code they test; the fresh-file boundary check in Task 8 covers what they guarded | 7 |
| every other test | unchanged | — |

---

## Task 1: `ProcessTable` and `ProcessList` join the SDK

The process table is read by two tabs that are about to become two bundles (CPU's drill-in, Dev's project tracing), and the top-N list is drawn by two (Memory, CPU). Moving both into the SDK first means neither later task has to copy them.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Kit/ProcessTable.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Kit/Views/ProcessList.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Models.swift` (delete `PidRecord`, lines 41–51)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor+Processes.swift` (delete `parseProcessTable`, lines 86–116; line 161 calls `ProcessTable.parse`)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor+Capacity.swift` (line 26)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Views/CPUPanel.swift` (delete `struct ProcessList`, lines 109–174)
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift` (lines 362, 375, 389, 478, 486, 492)
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarCapacityTests.swift` (lines 254, 278)

- [ ] **Step 1: Point the tests at the SDK names**

In `SystemBarPerformanceTests.swift`, replace every `UnifiedMonitor.parseProcessTable(` with `ProcessTable.parse(` (three places: `testProcessTableParsing`, `testParentChainWalk`, `testGroupDetailRows`) and every `UnifiedMonitor.runProcess(` with `ProcessRunner.run(` (three places in `testRunProcessDrainsLargeStderrConcurrently` and `testRunProcessTimesOutHungCommand`; the argument labels `path:arguments:timeout:` are the same). In `SystemBarCapacityTests.swift`, replace both `UnifiedMonitor.parseProcessTable(` with `ProcessTable.parse(`.

```bash
sed -i '' -e 's/UnifiedMonitor\.parseProcessTable(/ProcessTable.parse(/g' -e 's/UnifiedMonitor\.runProcess(/ProcessRunner.run(/g' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
sed -i '' -e 's/UnifiedMonitor\.parseProcessTable(/ProcessTable.parse(/g' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarCapacityTests.swift
grep -n "ProcessTable.parse\|ProcessRunner.run" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarCapacityTests.swift
```

Expected: eight lines, three `ProcessTable.parse` and three `ProcessRunner.run` in the performance file, two `ProcessTable.parse` in the capacity file.

Then add one new test to `SystemBarPerformanceTests.swift`, next to `testProcessTableParsing`, and call it from `main()` directly after `testProcessTableParsing()`:

```swift
    private static func testProcessTableCarriesTheColumnsItParses() {
        expect(ProcessTable.executable == "/bin/ps", "the table is read from ps by explicit path")
        expect(ProcessTable.arguments == ["-eo", "pid,ppid,pcpu,rss,etime,args"], "the columns the parser depends on, in its order, got \(ProcessTable.arguments)")

        // What `ps -eo pid,ppid,pcpu,rss,etime,args` prints: a header, then the five space-free
        // fields and the whole command line, spaces and all.
        let sample = """
          PID  PPID  %CPU    RSS     ELAPSED ARGS
            1     0   0.0  20000 10-00:00:00 /sbin/launchd
          412     1  12.5  81920    01:02:03 /Applications/Some App.app/Contents/MacOS/Some App --flag value
        """
        let table = ProcessTable.parse(sample)
        expect(table.count == 2, "the header is skipped and both rows are read, got \(table.count)")
        expect(table[412]?.ppid == 1 && table[412]?.cpu == 12.5, "pid, ppid and pcpu come from the first three columns")
        expect(table[412]?.memory == 81_920 * 1024, "rss is in kilobytes and becomes bytes, got \(String(describing: table[412]?.memory))")
        expect(table[412]?.etime == "01:02:03", "etime is the fifth column, got \(String(describing: table[412]?.etime))")
        expect(table[412]?.args == "/Applications/Some App.app/Contents/MacOS/Some App --flag value", "args is the whole remainder, spaces included")
    }
```

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: the test binary does not compile, with lines like `SystemBarPerformanceTests.swift:362:19: error: cannot find 'ProcessTable' in scope`. (`ProcessRunner.run` already exists, so those lines compile.)

- [ ] **Step 3: Create `Sources/Kit/ProcessTable.swift`**

The struct is `Models.swift` lines 41–51 made public with an explicit init; `parse` is the body of `UnifiedMonitor+Processes.swift` lines 89–116, unchanged.

```swift
import Foundation

/// One row of `ps -eo pid,ppid,pcpu,rss,etime,args`. Public because two tabs read the whole
/// process table — CPU to explain a tapped group, Dev to trace work to projects — and two
/// bundles can share code only through the SDK.
public struct PidRecord: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let cpu: Double        // raw `ps` pcpu (percent of a single core)
    public let memory: UInt64     // bytes
    public let etime: String      // ps ELAPSED, e.g. "00:10:00" or "3-04:05:06"
    public let path: String       // executable path (first token of args)
    public let args: String       // full command line
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(pid: Int32, ppid: Int32, cpu: Double, memory: UInt64, etime: String, path: String, args: String) {
        self.pid = pid
        self.ppid = ppid
        self.cpu = cpu
        self.memory = memory
        self.etime = etime
        self.path = path
        self.args = args
    }
}

/// Reads the output of `ps -eo pid,ppid,pcpu,rss,etime,args`. The caller runs `ps` itself,
/// through `HostServices.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)`,
/// so the SDK never starts a process a plugin did not ask for.
public enum ProcessTable {
    public static let executable = "/bin/ps"
    /// `parse` depends on exactly this column order; change the two together or not at all.
    public static let arguments = ["-eo", "pid,ppid,pcpu,rss,etime,args"]

    /// A pid -> record map. The five leading fields are space-free; args is the whole trailing
    /// remainder, so name and path come from args rather than a separate, space-prone comm
    /// column. The header line and anything unreadable are skipped.
    public static func parse(_ output: String) -> [Int32: PidRecord] {
        var map: [Int32: PidRecord] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(maxSplits: 5, whereSeparator: \.isWhitespace)
            guard parts.count == 6,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }

            let cpu = Double(parts[2]) ?? 0
            let rssKB = UInt64(parts[3]) ?? 0
            let etime = String(parts[4])
            let args = String(parts[5])
            let path = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? args

            map[pid] = PidRecord(
                pid: pid,
                ppid: ppid,
                cpu: cpu,
                memory: rssKB * 1024,
                etime: etime,
                path: path,
                args: args
            )
        }

        return map
    }
}
```

- [ ] **Step 4: Create `Sources/Kit/Views/ProcessList.swift`**

This is `CPUPanel.swift` lines 109–174 made public. What changes: `public` on the struct, `body` and a new init; `onTap` becomes a `let` set by the init (it was a `var` only so the memberwise init could default it).

```swift
import SwiftUI

/// A titled, scrolling list of process groups: a value on the right, a bar, and a second line.
/// Public because the Memory and CPU tabs both show one, and two bundles can share a view only
/// through the SDK.
public struct ProcessList: View {
    let title: String
    let rows: [ProcessSnapshot]
    let value: (ProcessSnapshot) -> String
    let subvalue: (ProcessSnapshot) -> String
    let fraction: (ProcessSnapshot) -> Double
    let color: Color
    /// When set, each row becomes a tap target that drills into that group.
    let onTap: ((ProcessSnapshot) -> Void)?

    public init(
        title: String,
        rows: [ProcessSnapshot],
        value: @escaping (ProcessSnapshot) -> String,
        subvalue: @escaping (ProcessSnapshot) -> String,
        fraction: @escaping (ProcessSnapshot) -> Double,
        color: Color,
        onTap: ((ProcessSnapshot) -> Void)? = nil
    ) {
        self.title = title
        self.rows = rows
        self.value = value
        self.subvalue = subvalue
        self.fraction = fraction
        self.color = color
        self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title)
                Spacer()
                Text("\(rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        if let onTap {
                            Button { onTap(row) } label: { rowContent(row) }
                                .buttonStyle(.plain)
                        } else {
                            rowContent(row)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ row: ProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.count > 1 ? "\(row.name) (\(row.count))" : row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(value(row))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                ProgressBar(value: fraction(row), color: color)
                    .frame(height: 6)
                Text(subvalue(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 5: Delete the host copies and repoint the two callers**

- `Sources/Host/Models.swift`: delete lines 41–51 (the doc comment `/// One row of the on-demand ...` and `struct PidRecord { ... }`).
- `Sources/Host/UnifiedMonitor+Processes.swift`: delete lines 86–116 (the doc comment starting `/// Parse \`ps -eo pid,ppid,pcpu,rss,etime,args\`` through the closing brace of `parseProcessTable`). In `fetchGroupDetail` (was line 161) change `let map = parseProcessTable(result.output)` to `let map = ProcessTable.parse(result.output)`.
- `Sources/Host/UnifiedMonitor+Capacity.swift` line 26: change `Self.parseProcessTable(table.output)` to `ProcessTable.parse(table.output)`.
- `Sources/Host/Views/CPUPanel.swift`: delete lines 109–174 (`struct ProcessList: View { ... }` and its blank line). `CPUPanel` and `MemoryPanel` now build the SDK's `ProcessList` with the same argument labels.

```bash
grep -rn "parseProcessTable\|struct PidRecord\|struct ProcessList" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources /Users/adamu/proj/swift-ui-system-monitor-2ik.3/*.swift
```

Expected: two lines, both in `Sources/Kit/` (`ProcessTable.swift` and `Views/ProcessList.swift`).

- [ ] **Step 6: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` then `Boundary check passed: a bundle built against the shipped SDK loads through the real loader`. The boundary check rebuilding `Examples/HelloTab` against the new interface proves the additions did not break an existing plugin.

- [ ] **Step 7: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Sources/Kit/ProcessTable.swift Sources/Kit/Views/ProcessList.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Move the process table parser and the process list into the SDK" -m "CPU and Dev both read the full ps table, and Memory and CPU both draw the
top-N list. They are about to become separate bundles, which can share code
only through the SDK, so both move there first.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Sources/Kit/ProcessTable.swift Sources/Kit/Views/ProcessList.swift Sources/Host/Models.swift Sources/Host/UnifiedMonitor+Processes.swift Sources/Host/UnifiedMonitor+Capacity.swift Sources/Host/Views/CPUPanel.swift SystemBarPerformanceTests.swift SystemBarCapacityTests.swift
```

---

## Task 2: The host owns the 1-second and process samplers

Today `UnifiedMonitor` samples the fast stats and the process summary and forwards them into the feeds. After this task `HostSamplers` does, driven by what the visible tab declares, and the monitor only mirrors the feeds for the panels still compiled in. The Memory and CPU tabs already declare `.processes`, so the monitor's own plan stops listing the process job.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/HostSamplers.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/ProcessSampler.swift`
- Create (git mv): `Sources/Host/UnifiedMonitor+FastStats.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/FastStatsSampler.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor.swift` (rewritten in full below)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor+Processes.swift` (only the drill-in is left)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Models.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/PluginScheduler.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/BuiltinTabs.swift` (`CPUTab.refreshInterval`)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/App.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Views/RootView.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/TestFakes.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarSchedulerTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift`

- [ ] **Step 1: Shared test helpers in `TestFakes.swift`**

Later tasks' plugin tests need to wait on a feed, record commands, and build a host with a chosen fast feed, so these become shared now. Replace `makeHost` (lines 8–25) with the version below, and append the other three definitions to the end of the file.

```swift
/// A HostServices with empty feeds, a silent log, and a runner that succeeds with no output
/// unless a test passes its own.
@MainActor
func makeHost(
    processes: Feed<ProcessSummary> = Feed(initial: ProcessSummary()),
    fastStats: Feed<FastStatsSnapshot> = Feed(initial: FastStatsSnapshot()),
    runner: @escaping CommandRunner = { _, _, _, _ in
        CommandOutput(output: "", error: "", status: 0, didTimeout: false)
    },
    log: @escaping @Sendable (String) -> Void = { _ in }
) -> HostServices {
    HostServices(
        homeDirectory: "/tmp/systembar-tests",
        processes: processes,
        fastStats: fastStats,
        runner: runner,
        log: log
    )
}
```

```swift
/// Spins the run loop until `condition` holds or `timeout` elapses, so a test waits only as
/// long as the machine actually needs rather than a fixed guess that either flakes under load
/// or wastes time when the machine is fast.
func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

/// Lets the run loop turn for `seconds`, for the tests that check something did *not* happen.
/// (Not named `pause`: Darwin already has a `pause()`.)
func spinRunLoop(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Captures every message it is given, under a lock, because runners and log closures are
/// `@Sendable` and may be called from a plugin's collect queue.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ message: String) {
        lock.withLock { stored.append(message) }
    }

    var count: Int { lock.withLock { stored.count } }
    var messages: [String] { lock.withLock { stored } }
}

/// A runner that writes each command it is asked to run into `recorder` as "path arg arg" and
/// answers from `answers`, keyed by that same line. Anything not listed fails with status 1, so
/// a test sees an unexpected command rather than an empty success.
func recordingRunner(_ recorder: LogRecorder, answers: [String: String]) -> CommandRunner {
    { path, arguments, _, _ in
        let line = ([path] + arguments).joined(separator: " ")
        recorder.record(line)
        guard let output = answers[line] else {
            return CommandOutput(output: "", error: "unexpected command: \(line)", status: 1, didTimeout: false)
        }
        return CommandOutput(output: output, error: "", status: 0, didTimeout: false)
    }
}
```

In `SystemBarSchedulerTests.swift`, delete the private `waitUntil` (lines 21–29, its doc comment included) and the `LogRecorder` class (lines 162–173, doc comment included): both now come from `TestFakes.swift`, and every existing call site compiles unchanged.

- [ ] **Step 2: Write the failing sampler tests**

In `SystemBarSchedulerTests.swift`:

Change the doc comment above the struct (lines 6–7) to:

```swift
/// Tests for what runs a tab once it is loaded: the feeds it reads, the scheduler that calls
/// its collect(), and the host's two shared samplers.
```

Replace `runAll()` (lines 10–19) with:

```swift
    static func runAll() {
        testFeedHoldsTheLatestValueAndPublishesTheNext()
        testHostServicesCarriesTheFeedsItWasBuiltWith()
        testSchedulerCollectsOnlyWhileVisibleAndNeverOverlaps()
        testSchedulerCollectsAtOnceWhenATabAppears()
        testSchedulerStopsThePreviousPluginWhenAnotherIsShown()
        testSchedulerNeverOverlapsACollectInterruptedByHideAndShow()
        testSchedulerClampsABadRefreshInterval()
        testSamplersWantNothingWhileTheWindowIsClosed()
        testSamplersRunNothingWhileTheWindowIsClosed()
        testSamplersRunTheFastSamplerForEveryVisibleTab()
        testSamplersRunTheProcessSamplerOnlyWhileATabDeclaresIt()
        testSamplersSampleAtOnceWhenStartedAndKeepTheirRhythm()
        testSamplersFillTheFeeds()
        testFastStatsSamplerTurnsCountersIntoRates()
        testFastStatsSamplerKeepsNinetySeconds()
        testProcessSamplerGroupsRowsAndDropsTinyOnes()
        testProcessSamplerUsesTheFootprintOnlyForShownGroups()
        testProcessSamplerRunsPsThroughTheRunner()
    }
```

In `testSchedulerClampsABadRefreshInterval`, change `MonitorSamplingPlan.minimumRefreshInterval` to `PluginScheduler.minimumRefreshInterval` and `MonitorSamplingPlan.maximumRefreshInterval` to `PluginScheduler.maximumRefreshInterval`.

Delete `testSamplingPlanAddsTheProcessesJobForAPluginThatDeclaresIt` (lines 154–159) and put these in its place, inside the struct:

```swift
    // MARK: - Host samplers

    /// Samplers whose collectors only count calls and hand back fixed readings, with intervals
    /// short enough to watch several ticks in a fraction of a second.
    private static func makeTestSamplers(
        fast: CallCounter,
        processes: CallCounter,
        processFeed: Feed<ProcessSummary> = Feed(initial: ProcessSummary()),
        fastFeed: Feed<FastStatsSnapshot> = Feed(initial: FastStatsSnapshot()),
        fastReading: FastStatsSnapshot = FastStatsSnapshot(),
        processReading: ProcessSummary = ProcessSummary(),
        interval: TimeInterval = 0.05
    ) -> HostSamplers {
        HostSamplers(
            processes: processFeed,
            fastStats: fastFeed,
            sampleFast: { fast.increment(); return fastReading },
            sampleProcesses: { processes.increment(); return processReading },
            fastInterval: interval,
            processInterval: interval
        )
    }

    private static func testSamplersWantNothingWhileTheWindowIsClosed() {
        expect(HostSamplers.wanted(isVisible: false, feeds: [.processes, .fastStats]).isEmpty, "a closed window wants no sampler, whatever the tab declares")
        expect(HostSamplers.wanted(isVisible: true, feeds: []) == [.fastStats], "an open window always wants the 1-second sampler, so the histories have no gaps")
        expect(HostSamplers.wanted(isVisible: true, feeds: [.processes]) == [.fastStats, .processes], "a tab that declares the process feed adds the process sampler")
    }

    private static func testSamplersRunNothingWhileTheWindowIsClosed() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        samplers.update(isVisible: false, feeds: [.processes, .fastStats])
        spinRunLoop(for: 0.2)
        expect(fast.count == 0 && processes.count == 0, "a closed window runs no sampler, got fast \(fast.count) processes \(processes.count)")
        expect(samplers.running.isEmpty, "and reports none running, got \(samplers.running)")
    }

    private static func testSamplersRunTheFastSamplerForEveryVisibleTab() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        samplers.update(isVisible: true, feeds: [])
        waitUntil { fast.count >= 3 }
        expect(fast.count >= 3, "the 1-second sampler ticks for a tab that declares nothing, got \(fast.count)")
        expect(processes.count == 0, "but ps never runs for it, got \(processes.count)")
        samplers.update(isVisible: false, feeds: [])
    }

    private static func testSamplersRunTheProcessSamplerOnlyWhileATabDeclaresIt() {
        let fast = CallCounter()
        let processes = CallCounter()
        let samplers = makeTestSamplers(fast: fast, processes: processes)

        samplers.update(isVisible: true, feeds: [.processes])
        waitUntil { processes.count >= 2 }
        expect(processes.count >= 2, "the process sampler ticks while the tab declares .processes, got \(processes.count)")

        samplers.update(isVisible: true, feeds: [])
        let afterSwitch = processes.count
        spinRunLoop(for: 0.2)
        // One tick may already have been handed to the queue when the timer was cancelled.
        expect(processes.count <= afterSwitch + 1, "switching to a tab without .processes stops ps, went \(afterSwitch) -> \(processes.count)")
        expect(samplers.running == [.fastStats], "only the 1-second sampler is left, got \(samplers.running)")

        samplers.update(isVisible: false, feeds: [])
        let afterClose = fast.count
        spinRunLoop(for: 0.2)
        expect(fast.count <= afterClose + 1, "closing the window stops the 1-second sampler too, went \(afterClose) -> \(fast.count)")
    }

    private static func testSamplersSampleAtOnceWhenStartedAndKeepTheirRhythm() {
        let fast = CallCounter()
        let processes = CallCounter()
        // A minute between ticks: anything seen within the test is the at-once sample on start.
        let samplers = makeTestSamplers(fast: fast, processes: processes, interval: 60)

        samplers.update(isVisible: true, feeds: [])
        waitUntil { fast.count >= 1 }
        expect(fast.count == 1, "a starting sampler reads at once instead of a minute later, got \(fast.count)")

        samplers.update(isVisible: true, feeds: [.processes])
        waitUntil { processes.count >= 1 }
        spinRunLoop(for: 0.1)
        expect(processes.count == 1, "the process sampler reads at once when a tab starts wanting it, got \(processes.count)")
        expect(fast.count == 1, "a sampler that keeps running is not restarted by a tab switch, so it keeps its rhythm, got \(fast.count)")
        samplers.update(isVisible: false, feeds: [])
    }

    private static func testSamplersFillTheFeeds() {
        let processFeed = Feed(initial: ProcessSummary())
        let fastFeed = Feed(initial: FastStatsSnapshot())
        var reading = FastStatsSnapshot()
        reading.cpuUsagePercent = 42
        let row = ProcessSnapshot(name: "clang", count: 1, physical: 1, virtualSize: 1, cpu: 1)
        let samplers = makeTestSamplers(
            fast: CallCounter(),
            processes: CallCounter(),
            processFeed: processFeed,
            fastFeed: fastFeed,
            fastReading: reading,
            processReading: ProcessSummary(rows: [row], limit: 1)
        )
        samplers.update(isVisible: true, feeds: [.processes])
        waitUntil { fastFeed.value.cpuUsagePercent == 42 && processFeed.value.totalCount == 1 }
        expect(fastFeed.value.cpuUsagePercent == 42, "the 1-second reading lands in the fastStats feed plugins read")
        expect(processFeed.value.topCPU.map(\.name) == ["clang"], "the process reading lands in the processes feed plugins read")
        samplers.update(isVisible: false, feeds: [])
    }

    // MARK: - Fast stats

    private static func testFastStatsSamplerTurnsCountersIntoRates() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = sampler.sample(
            cpu: CPUCounters(user: 100, system: 50, idle: 850, nice: 0),
            network: NetworkCounters(received: 1_000, sent: 500),
            at: start
        )
        expect(first.cpuUsagePercent == 0 && first.currentDownloadRate == 0, "a first sample has nothing to compare with, so it reports zero rather than a lifetime average")

        let second = sampler.sample(
            cpu: CPUCounters(user: 130, system: 60, idle: 910, nice: 0),
            network: NetworkCounters(received: 3_000, sent: 1_500),
            at: start.addingTimeInterval(2)
        )
        expect(second.cpuUsagePercent == 40, "40 busy ticks out of 100 is 40%, got \(second.cpuUsagePercent)")
        expect(second.currentDownloadRate == 1_000, "2000 bytes received over 2 seconds is 1000 B/s, got \(second.currentDownloadRate)")
        expect(second.currentUploadRate == 500, "1000 bytes sent over 2 seconds is 500 B/s, got \(second.currentUploadRate)")
        expect(second.cpuHistory == [0, 40], "each sample appends to the history, got \(second.cpuHistory)")

        let reset = sampler.sample(
            cpu: CPUCounters(user: 0, system: 0, idle: 0, nice: 0),
            network: NetworkCounters(received: 0, sent: 0),
            at: start.addingTimeInterval(3)
        )
        expect(reset.currentDownloadRate == 0, "a counter that went backwards (an interface reset) reads as no traffic, not a huge wrapped number")
        expect(reset.cpuUsagePercent == 40, "with no CPU time elapsed the last percent stands, got \(reset.cpuUsagePercent)")
    }

    private static func testFastStatsSamplerKeepsNinetySeconds() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)
        let last = (0..<100).reduce(FastStatsSnapshot()) { _, second in
            sampler.sample(
                cpu: CPUCounters(user: UInt64(second) * 10, system: 0, idle: UInt64(second) * 90, nice: 0),
                network: NetworkCounters(received: UInt64(second) * 100, sent: 0),
                at: start.addingTimeInterval(TimeInterval(second))
            )
        }
        expect(last.cpuHistory.count == FastStatsSampler.historyLimit, "the CPU history keeps the last \(FastStatsSampler.historyLimit) samples, got \(last.cpuHistory.count)")
        expect(last.downloadHistory.count == FastStatsSampler.historyLimit && last.uploadHistory.count == FastStatsSampler.historyLimit, "and so do both network histories")
        expect(FastStatsSampler.historyLimit == 90, "90 one-second samples is the 'last 90s' the graphs are labelled with")
    }

    // MARK: - Process sampler

    /// `ps -eo pid,rss,vsz,pcpu,comm -r` output: rss and vsz in kilobytes.
    private static let psRows = """
      PID    RSS      VSZ  %CPU COMM
      101   2048   400000  10.0 /usr/bin/clang
      102   4096   400000  30.0 /usr/bin/clang
      103    512   100000  90.0 /usr/libexec/tiny
      104   3072   200000   5.0 /Applications/Safari.app/Contents/MacOS/Safari
    """

    private static func testProcessSamplerGroupsRowsAndDropsTinyOnes() {
        let samples = ProcessSampler.parsePS(psRows)
        expect(samples.count == 4, "every row but the header is read, got \(samples.count)")

        let rows = ProcessSampler.snapshots(samples: samples, footprint: { _ in nil })
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        expect(byName["tiny"] == nil, "a process under a megabyte resident is noise in a top-N list and is dropped")
        expect(byName["clang"]?.count == 2, "processes with one name are one group")
        expect(byName["clang"]?.physical == 6_144 * 1_024, "a group's memory is the sum of its members', in bytes")
        expect(byName["clang"]?.cpu == 40, "and so is its CPU")
        expect(byName["Safari"]?.physical == 3_072 * 1_024, "the name is the executable's basename")
    }

    private static func testProcessSamplerUsesTheFootprintOnlyForShownGroups() {
        let samples = ProcessSampler.parsePS(psRows)
        let asked = LogRecorder()
        let rows = ProcessSampler.snapshots(samples: samples, memoryLimit: 1, cpuLimit: 1) { pid in
            asked.record("\(pid)")
            return 1
        }
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        expect(Set(asked.messages) == ["101", "102"], "only the group that would be shown (clang, top by memory and by CPU) pays for the footprint syscall, got \(asked.messages)")
        expect(byName["clang"]?.physical == 2, "a refined group's memory is the sum of its footprints")
        expect(byName["Safari"]?.physical == 3_072 * 1_024, "an unrefined group keeps ps's resident size")
    }

    private static func testProcessSamplerRunsPsThroughTheRunner() {
        let recorder = LogRecorder()
        let runner = recordingRunner(recorder, answers: ["/bin/ps -eo pid,rss,vsz,pcpu,comm -r": psRows])
        let summary = ProcessSampler.summary(runner: runner, footprint: { _ in nil })
        expect(recorder.messages == ["/bin/ps -eo pid,rss,vsz,pcpu,comm -r"], "one ps, by explicit path, with an argument array, got \(recorder.messages)")
        expect(summary.totalCount == 2, "the summary counts groups after the tiny one is dropped, got \(summary.totalCount)")
        expect(summary.topCPU.first?.name == "clang", "and ranks them by CPU")
    }
```

Append to the end of the file, after `SlowTickingTab`:

```swift
/// Counts calls from any thread, for the samplers' fake collectors.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() {
        lock.withLock { calls += 1 }
    }

    var count: Int { lock.withLock { calls } }
}
```

In `SystemBarPerformanceTests.swift`:

- `testSamplingPlan` line 54: `expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .memory) == [.memory, .processes], "memory mode should refresh memory and processes")` becomes `expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .memory) == [.memory], "memory mode runs the memory sampler; the process feed comes from the host samplers now")`.
- Line 55: `expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .cpu) == [.processes], "cpu mode should refresh processes only")` becomes `expect(MonitorSamplingPlan.jobs(isVisible: true, mode: .cpu).isEmpty, "cpu mode needs nothing of the monitor; both its feeds come from the host samplers")`.
- `testCollectorsDoNotLeakHostPortRights` line 509: `UnifiedMonitor.collectCPUCounters()` becomes `FastStatsSampler.collectCPUCounters()`.
- `testGroupsNeedingRefinement` lines 532 and 535: `UnifiedMonitor.groupsNeedingRefinement(` becomes `ProcessSampler.groupsNeedingRefinement(`.

- [ ] **Step 3: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: compile errors including `error: cannot find 'HostSamplers' in scope`, `error: cannot find 'FastStatsSampler' in scope`, `error: cannot find 'ProcessSampler' in scope` and `error: type 'PluginScheduler' has no member 'minimumRefreshInterval'`.

- [ ] **Step 4: `FastStatsSampler.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+FastStats.swift Sources/Host/FastStatsSampler.swift
```

Rewrite the file. `collectCPUCounters` is lines 51–89 unchanged and `collectNetworkCounters` is lines 91–120 unchanged; the rate math is lines 13–42 split into two pure functions; `CPUCounters` and `NetworkCounters` are `Models.swift` lines 403–421 unchanged. The whole file:

```swift
import Darwin
import Foundation
import SystemBarKit

/// The 1-second sample: CPU busy percent and network rates, each worked out from how far the
/// kernel's counters moved since the last sample, with their short histories. Only
/// HostSamplers' serial queue calls `sample()`, which is what makes the unlocked state safe.
final class FastStatsSampler: @unchecked Sendable {
    /// Ninety one-second samples: the "last 90s" the CPU and Network graphs are labelled with.
    static let historyLimit = 90

    private var previousCPU: CPUCounters?
    private var previousNetwork: NetworkCounters?
    private var previousDate: Date?
    private var last = FastStatsSnapshot()

    func sample() -> FastStatsSnapshot {
        sample(cpu: Self.collectCPUCounters(), network: Self.collectNetworkCounters(), at: Date())
    }

    /// The rate math, kept apart from the kernel reads so a test can feed it counters. Until
    /// there is a previous reading to compare with, the last figures stand.
    func sample(cpu: CPUCounters, network: NetworkCounters, at date: Date) -> FastStatsSnapshot {
        let cpuPercent = Self.busyPercent(from: previousCPU, to: cpu) ?? last.cpuUsagePercent
        let rates = Self.rates(from: previousNetwork, at: previousDate, to: network, at: date)
            ?? (download: last.currentDownloadRate, upload: last.currentUploadRate)

        var next = last
        next.cpuUsagePercent = cpuPercent
        next.currentDownloadRate = rates.download
        next.currentUploadRate = rates.upload
        BoundedHistory.append(cpuPercent, to: &next.cpuHistory, limit: Self.historyLimit)
        BoundedHistory.append(rates.download, to: &next.downloadHistory, limit: Self.historyLimit)
        BoundedHistory.append(rates.upload, to: &next.uploadHistory, limit: Self.historyLimit)

        previousCPU = cpu
        previousNetwork = network
        previousDate = date
        last = next
        return next
    }

    /// Nil when there is nothing to compare with or no CPU time passed. A counter that went
    /// backwards counts as no change rather than a huge wrapped number.
    static func busyPercent(from previous: CPUCounters?, to current: CPUCounters) -> Double? {
        guard let previous else { return nil }
        let totalDelta = current.total >= previous.total ? current.total - previous.total : 0
        let activeDelta = current.active >= previous.active ? current.active - previous.active : 0
        guard totalDelta > 0 else { return nil }
        return Double(activeDelta) / Double(totalDelta) * 100
    }

    /// Bytes per second since the previous reading; nil for the first one. A counter that went
    /// backwards (an interface reset) reads as no traffic.
    static func rates(
        from previous: NetworkCounters?,
        at previousDate: Date?,
        to current: NetworkCounters,
        at date: Date
    ) -> (download: Double, upload: Double)? {
        guard let previous, let previousDate else { return nil }
        let elapsed = max(0.001, date.timeIntervalSince(previousDate))
        let received = current.received >= previous.received ? current.received - previous.received : 0
        let sent = current.sent >= previous.sent ? current.sent - previous.sent : 0
        return (download: Double(received) / elapsed, upload: Double(sent) / elapsed)
    }

    // Move lines 51–89 of the old UnifiedMonitor+FastStats.swift here unchanged:
    // `static func collectCPUCounters() -> CPUCounters { ... }`

    // Move lines 91–120 here unchanged:
    // `private static func collectNetworkCounters() -> NetworkCounters { ... }`
}

// Move Models.swift lines 403–421 here unchanged: `struct CPUCounters { ... }` and
// `struct NetworkCounters { ... }`.
```

(The four `// Move ...` comments are instructions to the implementer: replace each with the code it names, then delete the comment.)

Delete `CPUCounters` and `NetworkCounters` (lines 403–421) from `Models.swift`.

- [ ] **Step 5: `ProcessSampler.swift`**

Create the file. `groupsNeedingRefinement` is `UnifiedMonitor+Processes.swift` lines 63–82 unchanged, `parsePS` is the body of lines 170–189 with `result.output` read as `output`, `physicalFootprint` is lines 192–202 without `private`, and the grouping in `snapshots` is lines 26–60 with the two substitutions shown. `RawProcessSample` is `Models.swift` lines 395–401 unchanged.

```swift
import Darwin
import Foundation
import SystemBarKit

/// The 10-second process summary behind `HostServices.processes`: one `ps` of every process,
/// grouped by name, with the exact memory footprint read only for the groups that will be shown.
enum ProcessSampler {
    /// Below a megabyte resident, a process is noise in a top-N list.
    static let minimumResidentBytes: UInt64 = 1_048_576

    static func summary(
        runner: CommandRunner,
        footprint: (Int32) -> UInt64? = ProcessSampler.physicalFootprint(pid:)
    ) -> ProcessSummary {
        ProcessSummary(rows: snapshots(samples: runPS(runner: runner), footprint: footprint))
    }

    /// Groups ps rows by name. `footprint` is `physicalFootprint` in the app and a fake in tests.
    static func snapshots(
        samples allSamples: [RawProcessSample],
        memoryLimit: Int = ProcessSummary.memoryDisplayLimit,
        cpuLimit: Int = ProcessSummary.cpuDisplayLimit,
        footprint: (Int32) -> UInt64?
    ) -> [ProcessSnapshot] {
        let samples = allSamples.filter { $0.rss >= minimumResidentBytes }
        guard !samples.isEmpty else { return [] }

        // proc_pid_rusage is hundreds of syscalls per 10s cycle if called for
        // every process; only the groups that would actually be displayed are
        // worth refining, so pick those using ps's cheap rss/pcpu first.
        let refinedNames = groupsNeedingRefinement(
            samples: samples.map { (name: $0.name, rss: $0.rss, cpu: $0.cpu) },
            memoryLimit: memoryLimit,
            cpuLimit: cpuLimit
        )

        var groups: [String: (count: Int, physical: UInt64, virtualSize: UInt64, cpu: Double)] = [:]
        for sample in samples {
            let physical = refinedNames.contains(sample.name)
                ? (footprint(sample.pid) ?? sample.rss)
                : sample.rss

            var group = groups[sample.name] ?? (count: 0, physical: 0, virtualSize: 0, cpu: 0)
            group.count += 1
            group.physical += physical
            group.virtualSize += sample.virtualSize
            group.cpu += sample.cpu
            groups[sample.name] = group
        }

        return groups.map { name, group in
            ProcessSnapshot(
                name: name,
                count: group.count,
                physical: group.physical,
                virtualSize: group.virtualSize,
                cpu: group.cpu
            )
        }
    }

    // Move UnifiedMonitor+Processes.swift lines 63–82 here unchanged (doc comment included):
    // `static func groupsNeedingRefinement(samples:memoryLimit:cpuLimit:) -> Set<String>`

    static func runPS(runner: CommandRunner) -> [RawProcessSample] {
        let result = runner("/bin/ps", ["-eo", "pid,rss,vsz,pcpu,comm", "-r"], nil, ProcessRunner.defaultTimeout)
        guard result.status == 0 else { return [] }
        return parsePS(result.output)
    }

    /// `ps -eo pid,rss,vsz,pcpu,comm -r` rows; the header and anything unreadable are skipped.
    static func parsePS(_ output: String) -> [RawProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let parts = rawLine.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard parts.count == 5, parts[0] != "PID" else { return nil }
            guard let pid = Int32(parts[0]),
                  let rssKB = UInt64(parts[1]),
                  let vszKB = UInt64(parts[2]) else {
                return nil
            }

            let cpu = Double(parts[3]) ?? 0
            let command = String(parts[4])
            let name = URL(fileURLWithPath: command).lastPathComponent
            return RawProcessSample(
                pid: pid,
                rss: rssKB * 1024,
                virtualSize: vszKB * 1024,
                cpu: cpu,
                name: name.isEmpty ? command : name
            )
        }
    }

    // Move UnifiedMonitor+Processes.swift lines 192–202 here, dropping `private`:
    // `static func physicalFootprint(pid: Int32) -> UInt64? { ... }`
}

// Move Models.swift lines 395–401 here unchanged: `struct RawProcessSample { ... }`.
```

Then:

- `Models.swift`: delete `RawProcessSample` (lines 395–401).
- `UnifiedMonitor+Processes.swift`: delete `collectProcesses` (lines 8–19), `collectProcessSnapshots` (lines 22–61), `groupsNeedingRefinement` (lines 63–82), `runPS` (lines 166–190) and `physicalFootprint` (lines 192–202). What is left is the `// MARK: - On-demand process drill-in` block: `parentChain`, `groupDetail` and `fetchGroupDetail`, which move to the CPU bundle in Task 6.

- [ ] **Step 6: `HostSamplers.swift`**

```swift
import Foundation
import SystemBarKit

/// The two samplers the host runs on every plugin's behalf, and when each one runs.
///
/// The 1-second sampler runs whenever the window is open, whatever the tab: the CPU and network
/// histories are ninety seconds long, and stopping it on a tab switch would leave a gap in them.
/// The 10-second process sampler runs only while the visible tab lists `.processes`, because a
/// `ps` of every process is the heavy one. With the window closed, neither runs.
///
/// Main thread only. Both timers fire on one serial queue, so a slow `ps` delays the next
/// 1-second tick rather than running beside it, and each sampler's own state is only ever
/// touched from that queue.
@MainActor
final class HostSamplers {
    nonisolated static let fastInterval: TimeInterval = 1
    nonisolated static let processInterval: TimeInterval = 10

    private let processes: Feed<ProcessSummary>
    private let fastStats: Feed<FastStatsSnapshot>
    private let sampleFast: @Sendable () -> FastStatsSnapshot
    private let sampleProcesses: @Sendable () -> ProcessSummary
    private let fastInterval: TimeInterval
    private let processInterval: TimeInterval
    private let queue = DispatchQueue(label: "systembar.host.samplers", qos: .utility)
    private var fastTimer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?

    /// The collectors and intervals are parameters so a test can count calls on a short
    /// interval; the app uses `standard(processes:fastStats:)`.
    init(
        processes: Feed<ProcessSummary>,
        fastStats: Feed<FastStatsSnapshot>,
        sampleFast: @escaping @Sendable () -> FastStatsSnapshot,
        sampleProcesses: @escaping @Sendable () -> ProcessSummary,
        fastInterval: TimeInterval = HostSamplers.fastInterval,
        processInterval: TimeInterval = HostSamplers.processInterval
    ) {
        self.processes = processes
        self.fastStats = fastStats
        self.sampleFast = sampleFast
        self.sampleProcesses = sampleProcesses
        self.fastInterval = fastInterval
        self.processInterval = processInterval
    }

    /// The real samplers: the kernel's counters every second, and `ps` through the real runner.
    static func standard(processes: Feed<ProcessSummary>, fastStats: Feed<FastStatsSnapshot>) -> HostSamplers {
        let fast = FastStatsSampler()
        return HostSamplers(
            processes: processes,
            fastStats: fastStats,
            sampleFast: { fast.sample() },
            sampleProcesses: { ProcessSampler.summary(runner: ProcessRunner.run) }
        )
    }

    /// Which samplers a tab that declares `feeds` needs.
    nonisolated static func wanted(isVisible: Bool, feeds: Set<SharedFeed>) -> Set<SharedFeed> {
        guard isVisible else { return [] }
        return feeds.contains(.processes) ? [.fastStats, .processes] : [.fastStats]
    }

    /// Which samplers are running now.
    var running: Set<SharedFeed> {
        Set([fastTimer.map { _ in SharedFeed.fastStats }, processTimer.map { _ in SharedFeed.processes }].compactMap { $0 })
    }

    /// Starts what the visible tab now needs and stops what it no longer does. A sampler that
    /// starts reads at once, so a tab never opens on a stale feed; one that keeps running keeps
    /// its rhythm, so calling this on every tab switch costs nothing extra.
    func update(isVisible: Bool, feeds: Set<SharedFeed>) {
        let wanted = Self.wanted(isVisible: isVisible, feeds: feeds)
        let fastStats = self.fastStats
        let sampleFast = self.sampleFast
        fastTimer = reconciled(fastTimer, isWanted: wanted.contains(.fastStats), interval: fastInterval) {
            fastStats.send(sampleFast())
        }
        let processes = self.processes
        let sampleProcesses = self.sampleProcesses
        processTimer = reconciled(processTimer, isWanted: wanted.contains(.processes), interval: processInterval) {
            processes.send(sampleProcesses())
        }
    }

    private func reconciled(
        _ timer: DispatchSourceTimer?,
        isWanted: Bool,
        interval: TimeInterval,
        tick: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer? {
        switch (timer, isWanted) {
        case (let running?, true):
            return running
        case (let running?, false):
            running.cancel()
            return nil
        case (nil, true):
            return started(interval: interval, tick: tick)
        case (nil, false):
            return nil
        }
    }

    /// Reads once straight away, then every `interval` with a tenth of it as leeway — the same
    /// allowance PluginScheduler gives a plugin's timer. The first reading is queued directly
    /// rather than left to the timer, whose leeway would let the system defer it by up to a
    /// second on the 10-second sampler.
    private func started(interval: TimeInterval, tick: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        queue.async(execute: tick)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler(handler: tick)
        timer.resume()
        return timer
    }
}
```

- [ ] **Step 7: `PluginScheduler` owns its bounds**

In `PluginScheduler.swift`, add inside the class, above `private var slots`:

```swift
    /// The floor under any plugin's declared refreshInterval, so a bad bundle cannot spin a core or trap.
    nonisolated static let minimumRefreshInterval: TimeInterval = 0.25
    /// The ceiling: a day is the longest a tab can sensibly wait, and Dispatch traps far above it.
    nonisolated static let maximumRefreshInterval: TimeInterval = 86_400
```

and change the init defaults (lines 26–27) to `minimumRefreshInterval: TimeInterval = PluginScheduler.minimumRefreshInterval,` and `maximumRefreshInterval: TimeInterval = PluginScheduler.maximumRefreshInterval,`. The instance properties of the same names stay: Swift allows a static and an instance property to share a name.

- [ ] **Step 8: `Models.swift`: the plan loses the host's samplers**

In `MonitorSamplingPlan` delete `fastRefreshInterval` (line 293), `processRefreshInterval` (line 295), `minimumRefreshInterval` and `maximumRefreshInterval` with their comments (lines 311–314), and the three-argument `jobs(isVisible:mode:feeds:)` with its doc comment (lines 316–326). In the two-argument `jobs(isVisible:mode:)`, change `case .memory: return [.memory, .processes]` to `case .memory: return [.memory]` and `case .cpu: return [.processes]` to `case .cpu: return []`. In `MonitorJob` delete `case processes`.

In `BuiltinTabs.swift` line 115, change `let refreshInterval = MonitorSamplingPlan.processRefreshInterval` to `let refreshInterval = HostSamplers.processInterval`.

- [ ] **Step 9: Rewrite `UnifiedMonitor.swift`**

The fast and process timers, their queues, `collectFastStats`, `collectProcesses` and `forward` leave. The four timers that remain are built by one helper and dispatched by one switch, so each later task deletes one line in each place. The whole file:

```swift
import AppKit
import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// What is left of the one monitor while the tabs move into bundles: the samplers the
/// compiled-in tabs still need, keyed by MonitorMode. The 1-second and process readings are the
/// host's now (HostSamplers); this class only mirrors those feeds for the panels still compiled in.
final class UnifiedMonitor: ObservableObject {
    @Published var fastStats = FastStatsSnapshot()
    @Published var memoryStats = MemoryStatsSnapshot()
    @Published var processSummary = ProcessSummary()
    @Published var networkSummary = NetworkSummary()
    @Published var capacitySnapshot = CapacitySnapshot()
    @Published var diskSnapshot = DiskSnapshot()
    @Published var isSpeedTestRunning = false
    @Published var speedTestStatus = "Ready"
    @Published var speedTestHealth = SampleHealth.ok
    @Published var speedTestResult: SpeedTestResult?

    // slowQueue is the sole owner of isWindowVisible/activeMode: every read or
    // write of that pair happens here, so the per-collector queues below can
    // run each check's own syscalls concurrently without racing on it.
    private let slowQueue = DispatchQueue(label: "systembar.monitor.slow", qos: .utility)
    let dnsQueue = DispatchQueue(label: "systembar.monitor.dns", qos: .utility)
    let speedTestQueue = DispatchQueue(label: "systembar.monitor.speedtest", qos: .utility)
    private let memoryQueue = DispatchQueue(label: "systembar.monitor.memory", qos: .utility)
    private let networkQueue = DispatchQueue(label: "systembar.monitor.network", qos: .utility)
    private let developerQueue = DispatchQueue(label: "systembar.monitor.developer", qos: .utility)
    let diskQueue = DispatchQueue(label: "systembar.monitor.disk", qos: .utility)
    /// The hog scan gets its own queue: it can run for minutes, and sharing diskQueue would
    /// stall the 30s capacity read behind it — freezing the rest of the Disk tab. It also
    /// owns `isScanningDiskHogs` and `lastDiskHogScan`, which are touched from nowhere else.
    let diskHogQueue = DispatchQueue(label: "systembar.monitor.diskhogs", qos: .utility)
    private var timers: [DispatchSourceTimer] = []
    private var feedSinks: [AnyCancellable] = []
    var isCollectingMemory = false
    var isCollectingNetwork = false
    var isCollectingCapacity = false
    var isCollectingDisk = false
    var isScanningDiskHogs = false
    var lastDiskHogScan = Date.distantPast
    var lastPressureRefresh = Date.distantPast
    var cachedPressure: Double?
    var cachedGPU = GPUSnapshot()
    var hostnameCache: [String: HostnameCacheEntry] = [:]
    var hostnameLookupsInFlight = Set<String>()
    private var isWindowVisible = false
    private var activeMode: MonitorMode?

    var memory: MemorySnapshot { memoryStats.memory }
    var gpu: GPUSnapshot { memoryStats.gpu }
    var pressure: Double? { memoryStats.pressure }
    var pressureHistory: [Double] { memoryStats.pressureHistory }
    var lastUpdated: Date? { memoryStats.lastUpdated }
    var currentDownloadRate: Double { fastStats.currentDownloadRate }
    var currentUploadRate: Double { fastStats.currentUploadRate }
    var cpuUsagePercent: Double { fastStats.cpuUsagePercent }
    var cpuHistory: [Double] { fastStats.cpuHistory }
    var downloadHistory: [Double] { fastStats.downloadHistory }
    var uploadHistory: [Double] { fastStats.uploadHistory }
    var topMemoryProcesses: [ProcessSnapshot] { processSummary.topMemory }
    var topCPUProcesses: [ProcessSnapshot] { processSummary.topCPU }
    var totalProcessCount: Int { processSummary.totalCount }
    var maxPhysicalProcessMemory: UInt64 { processSummary.maxPhysical }
    var networkProcesses: [NetworkProcessSnapshot] { networkSummary.processes }
    var networkProcessCount: Int { networkSummary.totalProcessCount }
    var networkMaxCombinedRate: Double { networkSummary.maxCombinedRate }
    var destinations: [NetworkDestination] { networkSummary.destinations }
    var resolvedHostnames: [String: String] { networkSummary.resolvedHostnames }
    var networkStatus: String { networkSummary.status }
    var networkHealth: SampleHealth { networkSummary.health }
    var capacity: CapacitySnapshot { capacitySnapshot }
    var disk: DiskSnapshot { diskSnapshot }

    /// The compiled-in tabs reach the one monitor through this until each owns its own
    /// collector. Deleted with the class.
    static let shared = UnifiedMonitor()

    private init() {
        timers = [
            makeTimer(every: MonitorSamplingPlan.memoryRefreshInterval, leeway: .seconds(1), job: .memory),
            makeTimer(every: MonitorSamplingPlan.networkRefreshInterval, leeway: .seconds(5), job: .network),
            makeTimer(every: MonitorSamplingPlan.capacityRefreshInterval, leeway: .seconds(10), job: .capacity),
            makeTimer(every: MonitorSamplingPlan.diskRefreshInterval, leeway: .seconds(5), job: .disk),
        ]
    }

    deinit {
        timers.forEach { $0.cancel() }
    }

    private func makeTimer(every interval: TimeInterval, leeway: DispatchTimeInterval, job: MonitorJob) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: slowQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.collectIfVisible(job) }
        timer.resume()
        return timer
    }

    func updatePresentation(isVisible: Bool, mode: MonitorMode?) {
        slowQueue.async { [weak self] in
            guard let self else { return }
            let becameVisible = isVisible && !self.isWindowVisible
            let changed = mode != self.activeMode
            self.isWindowVisible = isVisible
            self.activeMode = mode

            if becameVisible || changed {
                self.visibleJobs.forEach { self.run($0) }
            }
        }
    }

    /// The panels still compiled in read the host's feeds through here until each moves into
    /// its bundle and reads the feed itself.
    func follow(processes: Feed<ProcessSummary>, fastStats: Feed<FastStatsSnapshot>) {
        processSummary = processes.value
        self.fastStats = fastStats.value
        feedSinks = [
            processes.publisher.sink { [weak self] in self?.processSummary = $0 },
            fastStats.publisher.sink { [weak self] in self?.fastStats = $0 },
        ]
    }

    private var visibleJobs: Set<MonitorJob> {
        guard isWindowVisible, let activeMode else { return [] }
        return MonitorSamplingPlan.jobs(isVisible: true, mode: activeMode)
    }

    private func collectIfVisible(_ job: MonitorJob) {
        guard visibleJobs.contains(job) else { return }
        run(job)
    }

    // Each check hops from slowQueue to its own dedicated queue here, so a
    // slow one (network's nettop alone takes ~1s by design) can't hold up
    // the others.
    private func run(_ job: MonitorJob) {
        switch job {
        case .memory: memoryQueue.async { [weak self] in self?.collectMemory() }
        case .network: networkQueue.async { [weak self] in self?.collectNetwork() }
        case .capacity: developerQueue.async { [weak self] in self?.collectCapacity() }
        case .disk: diskQueue.async { [weak self] in self?.collectDisk() }
        }
    }
}
```

- [ ] **Step 10: App and RootView drive the samplers**

`App.swift`: add `private let samplers: HostSamplers` below `private let scheduler = PluginScheduler()`. In `init()`, directly after the `let host = HostServices(...)` statement, add:

```swift
        samplers = HostSamplers.standard(processes: processes, fastStats: fastStats)
```

replace `UnifiedMonitor.shared.forward(processes: processes, fastStats: fastStats)` with `UnifiedMonitor.shared.follow(processes: processes, fastStats: fastStats)`, and change the `RootView(...)` line to:

```swift
            RootView(monitor: UnifiedMonitor.shared, tabs: tabs, configPath: configPath, scheduler: scheduler, samplers: samplers)
```

`Views/RootView.swift`: add `let samplers: HostSamplers` below `let scheduler: PluginScheduler`, and replace `present(index:isVisible:)` (lines 119–135) with:

```swift
    /// Tells the scheduler, the host samplers and the monitor what the selected tab needs. A
    /// compiled-in tab still keys the monitor's own samplers by MonitorMode; every tab gets the
    /// shared samplers it declares; an error tab or an empty list needs nothing.
    private func present(index: Int, isVisible: Bool) {
        let plugin = loadedPlugin(at: index)
        plugin?.visibilityChanged(isVisible: isVisible)
        if isVisible, let plugin {
            scheduler.show(plugin)
        } else {
            scheduler.hide()
        }
        samplers.update(isVisible: isVisible && plugin != nil, feeds: plugin?.sharedFeeds ?? [])
        monitor.updatePresentation(
            isVisible: isVisible && plugin != nil,
            mode: (plugin as? MonitorBackedTab)?.monitorMode
        )
    }
```

- [ ] **Step 11: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`.

- [ ] **Step 12: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Sources/Host/HostSamplers.swift Sources/Host/ProcessSampler.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Give the host its own 1-second and process samplers" -m "HostSamplers runs the 1-second sampler whenever the window is open and the
ps sampler only while the visible tab declares .processes, filling the feeds
plugins read. UnifiedMonitor stops sampling either and only mirrors the feeds
for the panels still compiled in. The refresh-interval bounds move onto
PluginScheduler.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Sources/Host/HostSamplers.swift Sources/Host/ProcessSampler.swift Sources/Host/FastStatsSampler.swift Sources/Host/UnifiedMonitor+FastStats.swift Sources/Host/UnifiedMonitor.swift Sources/Host/UnifiedMonitor+Processes.swift Sources/Host/Models.swift Sources/Host/PluginScheduler.swift Sources/Host/BuiltinTabs.swift Sources/Host/App.swift Sources/Host/Views/RootView.swift TestFakes.swift SystemBarSchedulerTests.swift SystemBarPerformanceTests.swift
```

---

## Task 3: Disk moves out

The first of the five. Its shape is the template for Tasks 4–7: tests move into `Plugins/<Name>/Tests/`, the collector becomes a class that runs its commands through `host.run`, the panel observes the plugin, and the tab's slice of the monitor, the models, the plan, `MonitorMode` and `BuiltinTabs.swift` is deleted.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Info.plist`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources/DiskModels.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources/DiskPlugin.swift`
- Create (git mv): `Sources/Host/UnifiedMonitor+Disk.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources/DiskCollector.swift`
- Create (git mv): `Sources/Host/Views/DiskPanel.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources/DiskPanel.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Models.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/BuiltinTabs.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Tests/DiskTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarLoaderTests.swift`

- [ ] **Step 1: Move the disk tests and write the new ones**

Check the block boundaries in the performance tests first (Tasks 1 and 2 changed lines only in place, so these still hold):

```bash
sed -n '17p;27p;56p;57p;64p;76p;79p;312p' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
```

Expected, in order: `testDiskVolumeMath()`, `testDiskHogScanReportsPermissionTroubleSeparately()`, the `mode: .disk) == [.disk]` expect, the `mode: .disk).isEmpty` expect, the `diskHogRefreshInterval >= 300` expect, a lone `)` closing the `diskHogPathTimeout` expect, `private static func testDiskVolumeMath() {`, and a lone `    }`.

Build `DiskTests.swift` from a header, the moved block (lines 79–312: `testDiskVolumeMath` through `testDiskHogScanReportsPermissionTroubleSeparately`, including the `duFinished`, `hogHome` and `hogCandidates` helpers, with `UnifiedMonitor.` renamed to `DiskCollector.`), and the new tests:

```bash
mkdir -p /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Tests /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources
{
cat <<'SWIFT'
import Foundation
import SystemBarKit

/// The Disk tab: volume math, the du-based hog scan, and the plugin that runs both.
/// Main-actor because a plugin is constructed on the main thread, by contract.
@MainActor
enum DiskTests {
    static func runAll() {
        testDiskVolumeMath()
        testDiskUsageParsing()
        testLocalSnapshotParsing()
        testReclaimableTotalIgnoresNestedPaths()
        testDiskHogCandidatePaths()
        testDiskHogScanDueRule()
        testDiskHogScanKeepsPathsThatFinished()
        testDiskHogScanMeasuresBiggestCandidatesFirst()
        testDiskHogScanPublishesRowsAsTheyFinish()
        testDiskHogScanStopsAtItsBudget()
        testDiskHogScanReportsPermissionTroubleSeparately()
        testSamplingIntervalsKeepDuRare()
        testSnapshotCountRunsTmutilThroughTheHost()
        testSnapshotAppliesAReadingAndEachHogUpdate()
        testHogScanRunsOnceUntilDueOrForced()
        testCollectPublishesVolumesAndTheHogScan()
        testPluginIdentityMatchesTheOldTab()
    }

SWIFT
sed -n '79,312p' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift | sed 's/UnifiedMonitor\./DiskCollector./g'
cat <<'SWIFT'

    private static func testSamplingIntervalsKeepDuRare() {
        expect(DiskSampling.refreshInterval == 30, "the volume read keeps its 30-second interval")
        expect(DiskSampling.hogRefreshInterval >= 300, "du walks real trees and must stay rare")
        expect(DiskSampling.hogRefreshInterval > DiskSampling.refreshInterval, "hog scan should be rarer than the cheap capacity read")
        expect(DiskSampling.hogScanBudget < DiskSampling.hogRefreshInterval, "a scan must be over before the next one is due, so scans never pile up")
        expect(DiskSampling.hogPathTimeout < DiskSampling.hogScanBudget, "one slow tree must not be able to spend the whole scan budget")
    }

    private static func testSnapshotCountRunsTmutilThroughTheHost() {
        let recorder = LogRecorder()
        let listing = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-09-24-101010.local\ncom.apple.os.update-ABC\n"
        let collector = DiskCollector(host: makeHost(runner: recordingRunner(recorder, answers: ["/usr/bin/tmutil listlocalsnapshots /": listing])))
        expect(collector.collectLocalSnapshotCount() == 2, "both Time Machine and OS-update snapshots count")
        expect(recorder.messages == ["/usr/bin/tmutil listlocalsnapshots /"], "tmutil runs through the host by explicit path, got \(recorder.messages)")

        let failing = DiskCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.collectLocalSnapshotCount() == 0, "a tmutil that fails counts no snapshots rather than guessing")
    }

    private static func testSnapshotAppliesAReadingAndEachHogUpdate() {
        let volume = DiskVolume(name: "Macintosh HD", path: "/", total: 1000, free: 100, purgeable: 50, isRoot: true)
        let at = Date(timeIntervalSince1970: 5_000)

        let read = DiskSnapshot().applying(DiskVolumeReading(volumes: [volume], localSnapshotCount: 3, sampledAt: at))
        expect(read.boot?.path == "/" && read.localSnapshotCount == 3, "a volume reading fills the volumes and the snapshot count")
        expect(read.status == "Disk sample OK" && read.health == .ok && read.lastUpdated == at, "a reading with volumes is healthy and dated, got \(read.status)")

        let empty = DiskSnapshot().applying(DiskVolumeReading(volumes: [], localSnapshotCount: 0, sampledAt: at))
        expect(empty.status == "No readable volumes found" && empty.health == .degraded, "no readable volume says so and is degraded, got \(empty.status)")

        let hog = DiskHog(name: "Downloads", path: "/Users/adam/Downloads", size: 10, hint: "")
        let started = read.applying(DiskHogUpdate.started)
        expect(started.isScanningHogs && started.hogStatus == "Measuring reclaimable paths", "a starting scan says it is measuring, got \(started.hogStatus)")
        let partway = started.applying(DiskHogUpdate.progress([hog]))
        expect(partway.hogs.map(\.name) == ["Downloads"] && partway.isScanningHogs, "each finished tree shows while the scan goes on")
        let done = partway.applying(DiskHogUpdate.finished(hogs: [hog], status: "Measured 1 path", at: at))
        expect(!done.isScanningHogs && done.hogStatus == "Measured 1 path" && done.lastHogScan == at, "a finished scan records its status and time")
        expect(done.volumes.count == 1 && done.localSnapshotCount == 3, "a hog update leaves the volume reading alone")
    }

    private static func testHogScanRunsOnceUntilDueOrForced() {
        let updates = LogRecorder()
        let collector = DiskCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        let record: (DiskHogUpdate) -> Void = { update in
            switch update {
            case .started: updates.record("started")
            case .progress: updates.record("progress")
            case .finished: updates.record("finished")
            }
        }
        let count: (String) -> Int = { name in updates.messages.filter { $0 == name }.count }

        collector.scanHogsIfDue(force: false, publish: record)
        collector.scanHogsIfDue(force: false, publish: record)
        waitUntil(2) { count("finished") >= 1 }
        spinRunLoop(for: 0.1)
        expect(count("started") == 1, "a second request straight after the first finds the scan not due, got \(updates.messages)")

        collector.scanHogsIfDue(force: true, publish: record)
        waitUntil(2) { count("finished") >= 2 }
        expect(count("started") == 2, "the rescan button forces a scan however recent the last one was, got \(updates.messages)")
    }

    private static func testCollectPublishesVolumesAndTheHogScan() {
        let recorder = LogRecorder()
        let answers = ["/usr/bin/tmutil listlocalsnapshots /": "com.apple.TimeMachine.1.local\n"]
        let plugin = DiskPlugin(host: makeHost(runner: recordingRunner(recorder, answers: answers)))
        plugin.collect()
        waitUntil(2) { plugin.snapshot.lastUpdated != nil && plugin.snapshot.lastHogScan != nil }
        expect(plugin.snapshot.boot != nil, "the boot volume is always read, got \(plugin.snapshot.volumes.map(\.path))")
        expect(plugin.snapshot.localSnapshotCount == 1, "the snapshot count comes through the host's runner")
        expect(plugin.snapshot.lastHogScan != nil && !plugin.snapshot.isScanningHogs, "a fresh plugin's first collect also runs the hog scan, which is due")
        expect(recorder.messages.allSatisfy { $0.hasPrefix("/usr/bin/tmutil ") || $0.hasPrefix("/usr/bin/du -s -k -x ") }, "every command goes through the host by explicit path, got \(recorder.messages)")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = DiskPlugin(host: makeHost())
        expect(DiskPlugin.identifier == "disk" && plugin.title == "Disk" && plugin.systemImage == "internaldrive", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.cyan, "and its accent")
        expect(plugin.refreshInterval == 30 && plugin.sharedFeeds.isEmpty, "and its interval, and it needs no shared feed")
    }
}
SWIFT
} > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Tests/DiskTests.swift
```

Then take the moved block and the disk lines out of the performance tests, and run the new suite in their place. One `sed` pass, so every line number refers to the file before the edit:

```bash
sed -i '' -e '79,312d' -e '64,76d' -e '56,57d' -e '17,27c\
        MainActor.assumeIsolated { DiskTests.runAll() }
' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
grep -n "Disk\|disk" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
```

Expected: one line, `MainActor.assumeIsolated { DiskTests.runAll() }`.

In `SystemBarLoaderTests.swift`, make the three tests that knew the built-in list by heart read it from `BuiltinTabSource` instead, so this task and the next three do not each have to edit them:

- In `runAll()`, rename `testLoaderWritesTheDefaultAndLoadsFiveTabsAndOneErrorOnFirstRun()` to `testLoaderWritesTheDefaultAndLoadsWhatTheSourceKnowsOnFirstRun()`, and replace that function (lines 43–54) with:

```swift
    private static func testLoaderWritesTheDefaultAndLoadsWhatTheSourceKnowsOnFirstRun() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        let loaded = TabLoader.load(store: store, source: BuiltinTabSource(), host: makeHost())
        let expected = DefaultPlugins.names.map { BuiltinTabSource.types[$0] != nil }
        expect(loaded.map { $0.plugin != nil } == expected,
               "a fresh file lists all six defaults in order; each tab still compiled in loads, and each that is now a bundle cannot come from the built-in table so it is an error tab in its place, got \(loaded.map(\.title))")
        if case let .failed(_, reason)? = loaded.first {
            expect(reason.contains("Power.bundle"), "the failure names the entry, got \(reason)")
        }
        expect(FileManager.default.fileExists(atPath: store.fileURL.path), "and the default file is written")
    }
```

- In `testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode`, change `plugins.count == 5, "all five compiled-in tabs load` to `plugins.count == BuiltinTabSource.builtins.count, "every compiled-in tab loads` and `ids.count == 5, "the five built-ins have five different ids` to `ids.count == BuiltinTabSource.builtins.count, "the built-ins have different ids`. Its last assertion (the order equals `MonitorMode.allCases`) stays true, because each task deletes its tab's `MonitorMode` case.
- In `testBuiltinSourceNamesTheUnknownTab`, change `"\(error)".contains("Weather.bundle") && "\(error)".contains("CPU.bundle")` to `"\(error)".contains("Weather.bundle") && BuiltinTabSource.types.keys.allSatisfy { "\(error)".contains($0) }`.

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `build.sh` stops at the new folder before the tests compile: `build-plugin.sh: no Info.plist at Plugins/Disk//Info.plist` (the doubled slash is how `build.sh` spells the folder). Once the bundle exists, the same run would fail at `error: cannot find 'DiskCollector' in scope` if the code below were missing.

- [ ] **Step 3: `Info.plist`**

```bash
sed -e 's/<string>Power<\/string>/<string>Disk<\/string>/g' -e 's/systembar\.power/systembar.disk/' -e 's/SystemBarPowerPlugin/SystemBarDiskPlugin/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Power/Info.plist > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Info.plist
for key in CFBundleExecutable CFBundleName CFBundleIdentifier NSPrincipalClass; do /usr/libexec/PlistBuddy -c "Print :$key" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Info.plist; done
```

Expected: `Disk`, `Disk`, `com.ih8celery.systembar.disk`, `SystemBarDiskPlugin`.

- [ ] **Step 4: `DiskModels.swift`**

```swift
import Foundation
import SystemBarKit

// Move Models.swift lines 191–282 here unchanged: `struct DiskVolume`, `struct DiskHog`,
// `struct DiskSnapshot` and `struct DiskHogCandidate`, with their doc comments.

/// How often the Disk tab samples, and how long its du scan may run.
enum DiskSampling {
    static let refreshInterval: TimeInterval = 30
    /// `du` walks real directory trees, so it runs far less often than the capacity read it ships with.
    static let hogRefreshInterval: TimeInterval = 600
    /// Per-tree ceiling. Generous, because a cold DerivedData or CoreSimulator walk is slow,
    /// but bounded so one pathological tree cannot hold the whole scan open.
    static let hogPathTimeout: TimeInterval = 45
    /// Whole-scan ceiling, kept well under the refresh interval so scans never overlap.
    static let hogScanBudget: TimeInterval = 240
}

/// What one 30-second volume read found.
struct DiskVolumeReading {
    let volumes: [DiskVolume]
    let localSnapshotCount: Int
    let sampledAt: Date

    var status: String { volumes.isEmpty ? "No readable volumes found" : "Disk sample OK" }
    var health: SampleHealth { SampleHealth(isOK: !volumes.isEmpty) }
}

/// What the hog scan reports as it goes, so the list fills in tree by tree.
enum DiskHogUpdate {
    case started
    case progress([DiskHog])
    case finished(hogs: [DiskHog], status: String, at: Date)
}

extension DiskSnapshot {
    /// A copy with a volume reading applied; the hog fields are left alone.
    func applying(_ reading: DiskVolumeReading) -> DiskSnapshot {
        var next = self
        next.volumes = reading.volumes
        next.localSnapshotCount = reading.localSnapshotCount
        next.status = reading.status
        next.health = reading.health
        next.lastUpdated = reading.sampledAt
        return next
    }

    /// A copy with one hog-scan update applied; the volume fields are left alone.
    func applying(_ update: DiskHogUpdate) -> DiskSnapshot {
        var next = self
        switch update {
        case .started:
            next.isScanningHogs = true
            next.hogStatus = "Measuring reclaimable paths"
        case .progress(let hogs):
            next.hogs = hogs
        case let .finished(hogs, status, at):
            next.hogs = hogs
            next.hogStatus = status
            next.isScanningHogs = false
            next.lastHogScan = at
        }
        return next
    }
}
```

Delete lines 191–282 from `Sources/Host/Models.swift`.

- [ ] **Step 5: `DiskCollector.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+Disk.swift Plugins/Disk/Sources/DiskCollector.swift
```

Replace lines 1–76 (the imports, `extension UnifiedMonitor {`, `collectDisk`, `isDiskHogScanDue` and `scanDiskHogs`) with:

```swift
import Darwin
import Foundation
import SystemBarKit

/// The Disk tab's two samplers: a cheap volume read every 30 seconds, and a `du` scan of the
/// usual space hogs at most every ten minutes. The volume read runs on the plugin's queue. The
/// scan gets its own serial queue because it can run for minutes, and sharing would freeze the
/// volume read behind it; that queue alone touches `lastScan`.
final class DiskCollector: @unchecked Sendable {
    private let host: HostServices
    private let hogQueue = DispatchQueue(label: "systembar.disk.hogs", qos: .utility)
    private var lastScan = Date.distantPast

    init(host: HostServices) {
        self.host = host
    }

    func readVolumes(at date: Date = Date()) -> DiskVolumeReading {
        DiskVolumeReading(volumes: Self.collectDiskVolumes(), localSnapshotCount: collectLocalSnapshotCount(), sampledAt: date)
    }

    /// Starts a hog scan if one is due. Every volume read asks; the rescan button passes
    /// `force: true`. A scan runs inside one block on the serial queue, so a request made while
    /// one is running waits, then finds the scan not due. `publish` is called on the scan queue.
    func scanHogsIfDue(force: Bool, publish: @escaping (DiskHogUpdate) -> Void) {
        hogQueue.async { [self] in
            guard Self.isDiskHogScanDue(force: force, lastScan: lastScan, now: Date(), interval: DiskSampling.hogRefreshInterval) else { return }
            lastScan = Date()
            publish(.started)
            // A full scan can run for minutes, so each tree lands in the list as it finishes
            // rather than leaving the panel empty until the last one is done.
            let result = collectDiskHogs { publish(.progress($0)) }
            publish(.finished(hogs: result.hogs, status: result.status, at: Date()))
        }
    }

    static func isDiskHogScanDue(force: Bool, lastScan: Date, now: Date, interval: TimeInterval) -> Bool {
        force || now.timeIntervalSince(lastScan) >= interval
    }
```

Then, further down the same file:

- `collectDiskVolumes` (old lines 78–119): unchanged.
- `collectLocalSnapshotCount` (old lines 121–125) becomes an instance method that runs through the host:

```swift
    func collectLocalSnapshotCount() -> Int {
        let result = host.run(path: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
        guard result.status == 0 else { return 0 }
        return Self.parseLocalSnapshotCount(result.output)
    }
```

- `parseLocalSnapshotCount` and `parseDiskUsage` (old lines 127–147): unchanged.
- `collectDiskHogs` (old lines 149–167) becomes:

```swift
    func collectDiskHogs(onProgress: ([DiskHog]) -> Void = { _ in }) -> (hogs: [DiskHog], status: String) {
        let start = Date()
        let host = self.host
        return Self.measureDiskHogs(
            candidates: DiskHogCandidate.all,
            homeDirectory: host.homeDirectory,
            budget: DiskSampling.hogScanBudget,
            pathExists: { FileManager.default.fileExists(atPath: $0) },
            elapsed: { Date().timeIntervalSince(start) },
            measure: { path in
                // -x keeps du on one filesystem; -k normalises to KiB across macOS versions.
                host.run(path: "/usr/bin/du", arguments: ["-s", "-k", "-x", path], timeout: DiskSampling.hogPathTimeout)
            },
            onProgress: onProgress
        )
    }
```

- `measureDiskHogs` and `diskHogStatus` (old lines 169–239): unchanged.
- Delete the stale comment about draining pipes (old lines 241–245); it describes `ProcessRunner`, which lives in the SDK.

- [ ] **Step 6: `DiskPlugin.swift`**

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

@objc(SystemBarDiskPlugin)
public final class DiskPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "disk"
    public let title = "Disk"
    public let systemImage = "internaldrive"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = DiskSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = []

    @Published private(set) var snapshot = DiskSnapshot()
    private let collector: DiskCollector

    @MainActor public init(host: HostServices) {
        collector = DiskCollector(host: host)
        super.init()
    }

    public func collect() {
        let reading = collector.readVolumes()
        publish { $0.applying(reading) }
        scanHogs(force: false)
    }

    /// The panel's rescan button passes `force: true`; every collect asks without forcing.
    func scanHogs(force: Bool) {
        collector.scanHogsIfDue(force: force) { [weak self] update in
            self?.publish { $0.applying(update) }
        }
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

- [ ] **Step 7: `DiskPanel.swift` observes the plugin**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/Views/DiskPanel.swift Plugins/Disk/Sources/DiskPanel.swift
sed -i '' -e 's/@ObservedObject var monitor: UnifiedMonitor/@ObservedObject var plugin: DiskPlugin/' -e 's/monitor\.disk\./plugin.snapshot./g' -e 's/monitor\.scanDiskHogs(force: true)/plugin.scanHogs(force: true)/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources/DiskPanel.swift
grep -n "monitor" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Disk/Sources/DiskPanel.swift
```

Expected: no output.

- [ ] **Step 8: Delete Disk's slice of the host**

`Sources/Host/UnifiedMonitor.swift` — delete these lines:

```
    @Published var diskSnapshot = DiskSnapshot()
    let diskQueue = DispatchQueue(label: "systembar.monitor.disk", qos: .utility)
    /// The hog scan gets its own queue: ... (the three comment lines)
    let diskHogQueue = DispatchQueue(label: "systembar.monitor.diskhogs", qos: .utility)
    var isCollectingDisk = false
    var isScanningDiskHogs = false
    var lastDiskHogScan = Date.distantPast
    var disk: DiskSnapshot { diskSnapshot }
            makeTimer(every: MonitorSamplingPlan.diskRefreshInterval, leeway: .seconds(5), job: .disk),
        case .disk: diskQueue.async { [weak self] in self?.collectDisk() }
```

`Sources/Host/Models.swift` — in `MonitorMode` delete `case disk = "Disk"` and `case .disk: return "internaldrive"`; in `MonitorJob` delete `case disk`; in `MonitorSamplingPlan` delete `diskRefreshInterval`, `diskHogRefreshInterval`, `diskHogPathTimeout` and `diskHogScanBudget` with their comments, and the two lines `case .disk:` / `return [.disk]`.

`Sources/Host/BuiltinTabs.swift` — delete the row `("Disk.bundle", DiskTab.self),` and the whole `final class DiskTab` (lines 82–94).

```bash
grep -rn "DiskSnapshot\|diskQueue\|DiskTab\|case disk\|case .disk\|diskRefresh\|diskHog" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host
```

Expected: no output.

- [ ] **Step 9: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`. `build.sh` now also builds `SystemBar.app/Contents/PlugIns/Disk.bundle`; a fresh `plugins.json` already names `Disk.bundle`, so the running app finds it there.

- [ ] **Step 10: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Plugins/Disk/Info.plist Plugins/Disk/Sources/DiskModels.swift Plugins/Disk/Sources/DiskPlugin.swift Plugins/Disk/Tests/DiskTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Move the Disk tab into its own bundle" -m "The volume read runs as the plugin's collect(), and the du scan keeps its
own queue inside the bundle. Commands go through host.run and the home
directory comes from the host. The monitor, models, sampling plan and
built-in table lose their disk slice.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Plugins/Disk/Info.plist Plugins/Disk/Sources/DiskModels.swift Plugins/Disk/Sources/DiskPlugin.swift Plugins/Disk/Sources/DiskCollector.swift Plugins/Disk/Sources/DiskPanel.swift Plugins/Disk/Tests/DiskTests.swift Sources/Host/UnifiedMonitor+Disk.swift Sources/Host/Views/DiskPanel.swift Sources/Host/UnifiedMonitor.swift Sources/Host/Models.swift Sources/Host/BuiltinTabs.swift SystemBarPerformanceTests.swift SystemBarLoaderTests.swift
```

---

## Task 4: Dev moves out

The capacity model (`Sources/Host/Capacity/`) moves with it: a bundle cannot see host types. Its 24 tests move by `git mv`.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Info.plist`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/CapacityModels.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/DevPlugin.swift`
- Create (git mv): `Sources/Host/Capacity/` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/Capacity/` (five files)
- Create (git mv): `Sources/Host/UnifiedMonitor+Capacity.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/CapacityCollector.swift`
- Create (git mv): `Sources/Host/Views/DeveloperPanel.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/DeveloperPanel.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor.swift`, `Sources/Host/Models.swift`, `Sources/Host/BuiltinTabs.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh`
- Test (git mv): `SystemBarCapacityTests.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Tests/CapacityTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Tests/DevPluginTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift`

- [ ] **Step 1: Move the capacity tests and write the plugin tests**

```bash
mkdir -p /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Tests /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv SystemBarCapacityTests.swift Plugins/Dev/Tests/CapacityTests.swift
sed -i '' -e 's/UnifiedMonitor\./CapacityCollector./g' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Tests/CapacityTests.swift
```

In `CapacityTests.swift`:

- Replace lines 1–5 (`import Foundation`, the doc comment, `struct SystemBarCapacityTests {`) with:

```swift
import Foundation
import SystemBarKit

/// Tests for the per-project capacity ledger: what kind of work a process is, whose project it
/// belongs to, what its load actually measures, and how the machine is graded overall.
/// Main-actor to match the other plugin suites, which construct plugins.
@MainActor
enum CapacityTests {
```

- Add `testListeningPortParsing()` as the last line of `runAll()`.
- Cut `testListeningPortParsing` (originally lines 456–465) out of `SystemBarPerformanceTests.swift` and paste it into `CapacityTests` above `// MARK: - Working directory fallback`, changing `UnifiedMonitor.parseListeningPorts(` to `CapacityCollector.parseListeningPorts(`.

Create `Plugins/Dev/Tests/DevPluginTests.swift`:

```swift
import Foundation
import SystemBarKit

/// The Dev tab as a plugin: what it declares, and whole collect runs through a fake host.
@MainActor
enum DevPluginTests {
    static func runAll() {
        testPluginIdentityMatchesTheOldTab()
        testSamplingIntervalsStayConservative()
        testCollectRunsItsThreeCommandsThroughTheHost()
        testCollectNamesEachCommandThatFailed()
        testPluginPublishesWhatItCollected()
    }

    private static let listenOutput = """
    COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    node    1234 adam   21u  IPv6 0xabc      0t0  TCP *:3000 (LISTEN)
    Python  2345 adam    7u  IPv4 0xdef      0t0  TCP 127.0.0.1:8000 (LISTEN)
    """

    private static let answers = [
        "/bin/ps -eo pid,ppid,pcpu,rss,etime,args": "  PID  PPID %CPU   RSS     ELAPSED ARGS\n    1     0  0.0 20000 10-00:00:00 /sbin/launchd\n",
        "/usr/sbin/lsof -n -P -iTCP -sTCP:LISTEN": listenOutput,
        "/usr/bin/pmset -g therm": "No thermal warning level has been recorded\nNo performance warning level has been recorded\n",
    ]

    private static func busyFeed(_ percent: Double) -> Feed<FastStatsSnapshot> {
        var snapshot = FastStatsSnapshot()
        snapshot.cpuUsagePercent = percent
        return Feed(initial: snapshot)
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = DevPlugin(host: makeHost())
        expect(DevPlugin.identifier == "dev" && plugin.title == "Dev" && plugin.systemImage == "terminal", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.purple, "and its accent")
        expect(plugin.refreshInterval == 60, "and its 60-second interval")
        expect(plugin.sharedFeeds == [.fastStats], "it declares the 1-second feed, because the capacity grade reads its CPU figure")
    }

    private static func testSamplingIntervalsStayConservative() {
        expect(DevSampling.refreshInterval >= 60, "capacity collector should be conservative")
        expect(DevSampling.sampleWindow < DevSampling.refreshInterval, "the rusage sample window must fit inside the refresh interval so ticks never overlap")
    }

    private static func testCollectRunsItsThreeCommandsThroughTheHost() {
        let recorder = LogRecorder()
        let host = makeHost(fastStats: busyFeed(55), runner: recordingRunner(recorder, answers: answers))
        let snapshot = CapacityCollector.collect(using: host, sampleWindow: 0)
        for command in answers.keys {
            expect(recorder.messages.contains(command), "\(command) runs through the host, got \(recorder.messages)")
        }
        expect(snapshot.cpuBusyPercent == 55, "the grade reads the host's 1-second CPU figure, got \(String(describing: snapshot.cpuBusyPercent))")
        expect(snapshot.ports.map(\.port) == ["3000", "8000"], "listening ports come from lsof, got \(snapshot.ports.map(\.port))")
        expect(snapshot.health == .ok && snapshot.status.hasPrefix("Capacity sample OK"), "three good reads are a healthy sample, got \(snapshot.status)")
        expect(snapshot.assessment != nil && snapshot.lastUpdated != nil, "a finished tick carries a grade and a time")
    }

    private static func testCollectNamesEachCommandThatFailed() {
        let host = makeHost(runner: recordingRunner(LogRecorder(), answers: [:]))
        let snapshot = CapacityCollector.collect(using: host, sampleWindow: 0)
        for failure in ["process table unavailable", "lsof listen unavailable", "thermal warnings unavailable"] {
            expect(snapshot.status.contains(failure), "the status names \(failure), got \(snapshot.status)")
        }
        expect(snapshot.health == .degraded, "a failed read is degraded")
    }

    private static func testPluginPublishesWhatItCollected() {
        let plugin = DevPlugin(host: makeHost(fastStats: busyFeed(12), runner: recordingRunner(LogRecorder(), answers: answers)))
        // The real one-second sample window: collect() blocks for it, as it does on the plugin's queue.
        plugin.collect()
        waitUntil(3) { plugin.capacity.lastUpdated != nil }
        expect(plugin.capacity.cpuBusyPercent == 12, "collect() publishes its snapshot for the panel, got \(String(describing: plugin.capacity.cpuBusyPercent))")
    }
}
```

In `SystemBarPerformanceTests.swift`'s `main()`: replace `SystemBarCapacityTests.runAll()` with the two lines below, and delete the `testListeningPortParsing()` call.

```swift
        MainActor.assumeIsolated { CapacityTests.runAll() }
        MainActor.assumeIsolated { DevPluginTests.runAll() }
```

In `testSamplingPlan` delete the `mode: .developer` expect and the two capacity expects (`capacityRefreshInterval >= 60` and the four-line `capacitySampleWindow < capacityRefreshInterval` one). They are now `DevPluginTests.testSamplingIntervalsStayConservative`.

In `test.sh` delete the line `  SystemBarCapacityTests.swift \`: the file is under `Plugins/Dev/Tests/` now, which the `find` on the line above already picks up.

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `build-plugin.sh: no Info.plist at Plugins/Dev//Info.plist`.

- [ ] **Step 3: `Info.plist` and the capacity model**

```bash
sed -e 's/<string>Power<\/string>/<string>Dev<\/string>/g' -e 's/systembar\.power/systembar.dev/' -e 's/SystemBarPowerPlugin/SystemBarDevPlugin/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Power/Info.plist > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Info.plist
for key in CFBundleExecutable CFBundleName CFBundleIdentifier NSPrincipalClass; do /usr/libexec/PlistBuddy -c "Print :$key" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Info.plist; done
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/Capacity Plugins/Dev/Sources/Capacity
```

Expected from the loop: `Dev`, `Dev`, `com.ih8celery.systembar.dev`, `SystemBarDevPlugin`. The five capacity files import only Foundation and SystemBarKit, so they compile in the bundle unchanged.

Create `Plugins/Dev/Sources/CapacityModels.swift`:

```swift
import Foundation

// Move Models.swift lines 179–189 here unchanged: `struct DeveloperPort`, with its comments.

/// How often the Dev tab samples, and how far apart its two rusage reads sit.
enum DevSampling {
    static let refreshInterval: TimeInterval = 60
    /// How far apart the two rusage reads sit. Per-project CPU and disk figures are deltas, so this
    /// is the interval they are measured over — long enough to be meaningful, short enough that the
    /// plugin's own queue is the only thing waiting on it.
    static let sampleWindow: TimeInterval = 1
}
```

Delete `DeveloperPort` (lines 179–189) from `Sources/Host/Models.swift`.

- [ ] **Step 4: `CapacityCollector.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+Capacity.swift Plugins/Dev/Sources/CapacityCollector.swift
```

Replace line 5 (`extension UnifiedMonitor {`) and `collectCapacity` (lines 6–107, its doc comment included) with the block below. What changed: it is a pure function of the host (commands through `host.run`, the home directory from the host, the CPU figure from the host's feed, which is lock-protected so the plugin's queue may read it) that returns its snapshot instead of publishing it, the sample window is a parameter so tests need not sleep, and the `isCollectingCapacity` guard is gone because the scheduler never overlaps a plugin's collects.

```swift
enum CapacityCollector {
    /// One tick of the Dev tab: find the expensive work, trace it to projects, and measure what
    /// it is actually drawing. Blocks for `sampleWindow` between its two rusage reads, which is
    /// why it runs on the plugin's own queue and nowhere else.
    static func collect(using host: HostServices, sampleWindow: TimeInterval = DevSampling.sampleWindow) -> CapacitySnapshot {
        let table = host.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)
        let listen = host.run(path: "/usr/sbin/lsof", arguments: ["-n", "-P", "-iTCP", "-sTCP:LISTEN"])
        let therm = host.run(path: "/usr/bin/pmset", arguments: ["-g", "therm"])

        // Failures decide health and colour the status line as trouble. Notes are things worth
        // saying that are not wrong with the sample — a process ending mid-read is routine.
        var failures: [String] = []
        var notes: [String] = []
        if table.status != 0 { failures.append("process table unavailable") }
        if listen.status != 0 { failures.append("lsof listen unavailable") }
        if therm.status != 0 { failures.append("thermal warnings unavailable") }

        let records = table.status == 0 ? ProcessTable.parse(table.output) : [:]
        let ports = listen.status == 0 ? Self.parseListeningPorts(listen.output) : []
        let warnings = therm.status == 0
            ? Self.parseThermalWarnings(therm.output)
            : (hasThermalWarning: false, hasPerformanceWarning: false)

        let resolver = ProjectResolver(homeDirectory: host.homeDirectory)
        let work = Self.categorizedProcesses(in: records, resolver: resolver)
        let attributedPorts = Self.attributedPorts(Array(ports.prefix(24)), records: records, resolver: resolver)

        // Two reads a known interval apart: the figures are deltas, so a single read could only
        // produce lifetime averages, which is exactly the kind of number this panel must not show.
        let pids = work.map(\.pid)
        let before = Self.rusageSamples(for: pids)
        let startedAt = Date()
        Thread.sleep(forTimeInterval: sampleWindow)
        let after = Self.rusageSamples(for: pids)
        let elapsed = Date().timeIntervalSince(startedAt)

        // Busyness is decided from the measurement, not before it: every categorized process is
        // sampled, then the ones that consumed no CPU over the interval drop out. That also keeps
        // idle simulator daemons from inflating the heat-heavy count behind the capacity grade.
        let measured = ProjectLoadRollup.evidence(
            processes: work,
            first: before,
            second: after,
            elapsed: elapsed
        )

        // Second attribution pass, over only the work believed to be running. A build's arguments
        // carry relative paths and name nothing, but its working directory is the repository — so
        // this is what turns anonymous load into a named row. Idle processes never get here, which
        // is what keeps the ask to a handful of pids.
        let unnamed = Self.workingDirectoryLookupPIDs(for: measured.allWorking)
        let skipped = measured.allWorking.filter { $0.project == nil }.count - unnamed.count
        if skipped > 0 {
            notes.append("\(skipped) more could not be traced to a project this tick")
        }
        let directories = Self.workingDirectories(for: unnamed, using: host)
        let evidence = measured.reattributed {
            Self.attributed($0, workingDirectories: directories, resolver: resolver)
        }

        if evidence.unnamedUnmeasuredCount > 0 {
            let count = evidence.unnamedUnmeasuredCount
            notes.append("\(count) unnamed process\(count == 1 ? "" : "es") could not be measured")
        }
        let rows = ProjectLoadRollup.rows(
            processes: evidence.ledgerProcesses,
            first: before,
            second: after,
            elapsed: elapsed,
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )
        let thermalState = ProcessInfo.processInfo.thermalState
        let cpuBusy = host.fastStats.value.cpuUsagePercent

        return CapacitySnapshot(
            assessment: CapacityGrade.assess(CapacityInputs(
                cpuBusyPercent: cpuBusy,
                heatHeavyCount: evidence.heatHeavyCount,
                thermalState: thermalState,
                hasThermalWarning: warnings.hasThermalWarning,
                hasPerformanceWarning: warnings.hasPerformanceWarning,
                cpuTemperatureCelsius: nil
            )),
            rows: rows,
            ports: attributedPorts,
            cpuBusyPercent: cpuBusy,
            thermalState: thermalStateLabel(thermalState),
            status: Self.statusText(failures: failures, notes: notes),
            health: SampleHealth(isOK: failures.isEmpty),
            lastUpdated: Date()
        )
    }
```

Then, in the same file:

- `workingDirectories(for:)` (old lines 167–180) becomes:

```swift
    /// One `lsof` call for every pid at once. Real Swift builds pass relative source paths, so their
    /// arguments name no project — but the build's working directory is the repository itself, which
    /// is the only way a build becomes a named row rather than anonymous load.
    static func workingDirectories(for pids: [Int32], using host: HostServices) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }

        let result = host.run(
            path: "/usr/sbin/lsof",
            arguments: ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]
        )
        // lsof reports a non-zero status when it could not read some of the pids it was given, and
        // still prints the ones it could, so the output is worth parsing either way.
        return parseWorkingDirectories(result.output)
    }
```

- Add, just before the file's final closing brace, a copy of `UnifiedMonitor+Network.swift` lines 239–244 (`port(from:)`), with this comment above it:

```swift
    /// The port after the last colon of an lsof endpoint. The Network bundle has the same helper;
    /// two bundles cannot share code outside the SDK, and six lines do not earn an SDK entry.
```

- Every other static function in the file (`statusText`, `categorizedProcesses`, `attributedPorts`, `maximumWorkingDirectoryLookups`, `workingDirectoryLookupPIDs`, `parseWorkingDirectories`, `attributed`, `parseThermalWarnings`, `rusageSamples`, `rusageSample`, `parseListeningPorts`) is unchanged.

- [ ] **Step 5: `DevPlugin.swift`**

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

@objc(SystemBarDevPlugin)
public final class DevPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "dev"
    public let title = "Dev"
    public let systemImage = "terminal"
    public let accent = Palette.purple
    public let refreshInterval: TimeInterval = DevSampling.refreshInterval
    /// The capacity grade reads the 1-second CPU figure. That sampler runs for every visible tab
    /// anyway, but the declaration says what this tab depends on.
    public let sharedFeeds: Set<SharedFeed> = [.fastStats]

    @Published private(set) var capacity = CapacitySnapshot()
    private let host: HostServices

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
    }

    public func collect() {
        let next = CapacityCollector.collect(using: host)
        DispatchQueue.main.async { [weak self] in
            self?.capacity = next
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(DeveloperPanel(plugin: self))
    }
}
```

- [ ] **Step 6: `DeveloperPanel.swift` observes the plugin**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/Views/DeveloperPanel.swift Plugins/Dev/Sources/DeveloperPanel.swift
sed -i '' -e 's/@ObservedObject var monitor: UnifiedMonitor/@ObservedObject var plugin: DevPlugin/' -e 's/private var capacity: CapacitySnapshot { monitor.capacity }/private var capacity: CapacitySnapshot { plugin.capacity }/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/DeveloperPanel.swift
grep -n "monitor" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Dev/Sources/DeveloperPanel.swift
```

Expected: no output.

- [ ] **Step 7: Delete Dev's slice of the host**

`Sources/Host/UnifiedMonitor.swift` — delete:

```
    @Published var capacitySnapshot = CapacitySnapshot()
    private let developerQueue = DispatchQueue(label: "systembar.monitor.developer", qos: .utility)
    var isCollectingCapacity = false
    var capacity: CapacitySnapshot { capacitySnapshot }
            makeTimer(every: MonitorSamplingPlan.capacityRefreshInterval, leeway: .seconds(10), job: .capacity),
        case .capacity: developerQueue.async { [weak self] in self?.collectCapacity() }
```

`Sources/Host/Models.swift` — in `MonitorMode` delete `case developer = "Dev"` and `case .developer: return "terminal"`; in `MonitorJob` delete `case capacity`; in `MonitorSamplingPlan` delete `capacityRefreshInterval`, `capacitySampleWindow` (with its three comment lines) and the `case .developer:` branch (its two comment lines and `return [.capacity]`).

`Sources/Host/BuiltinTabs.swift` — delete the row `("Dev.bundle", DevTab.self),` and the whole `final class DevTab`.

```bash
grep -rn "Capacity\|capacity\|developer\|DevTab\|DeveloperPort" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host
```

Expected: no output.

- [ ] **Step 8: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`. The run takes about a second longer than before: `testPluginPublishesWhatItCollected` waits out the real sample window once.

- [ ] **Step 9: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Plugins/Dev/Info.plist Plugins/Dev/Sources/CapacityModels.swift Plugins/Dev/Sources/DevPlugin.swift Plugins/Dev/Tests/DevPluginTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Move the Dev tab and its capacity model into their own bundle" -m "The capacity collector becomes a function of the host: its commands go
through host.run, the home directory and the CPU figure come from the host,
and it returns the snapshot for the plugin to publish. The capacity model and
its 24 tests move with it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Plugins/Dev Sources/Host/Capacity Sources/Host/UnifiedMonitor+Capacity.swift Sources/Host/Views/DeveloperPanel.swift Sources/Host/UnifiedMonitor.swift Sources/Host/Models.swift Sources/Host/BuiltinTabs.swift SystemBarCapacityTests.swift SystemBarPerformanceTests.swift test.sh
```

---

## Task 5: Memory moves out

Memory reads the process feed (it already declares `.processes`) and samples the kernel's memory figures itself, with memory_pressure and ioreg cached for 30 seconds as today.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Info.plist`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryModels.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryFormatting.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryPlugin.swift`
- Create (git mv): `Sources/Host/UnifiedMonitor+Memory.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryCollector.swift`
- Create (git mv): `Sources/Host/Views/MemoryPanel.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryPanel.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor.swift`, `Sources/Host/UnifiedMonitor+SpeedTest.swift`, `Sources/Host/Models.swift`, `Sources/Host/BuiltinTabs.swift`, `Sources/Host/Views/HostFormatting.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Tests/MemoryTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift`, `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarLoaderTests.swift`

- [ ] **Step 1: Move the memory tests and write the new ones**

Create `Plugins/Memory/Tests/MemoryTests.swift` with the content below. At the marked place, paste `testSwapStatText` and `testMemorySegmentsMatchEveryBarSegment` cut from `SystemBarPerformanceTests.swift` (originally lines 539–567), unchanged: they call free functions that move with the panel.

```swift
import Darwin
import Foundation
import SystemBarKit

/// The Memory tab: its formatting, its sampler's cadence, and the plugin that follows the
/// process feed.
@MainActor
enum MemoryTests {
    static func runAll() {
        testSwapStatText()
        testMemorySegmentsMatchEveryBarSegment()
        testMemorySnapshotDoesNotLeakHostPortRights()
        testPressureAndGPUAreReadEveryThirtySeconds()
        testPressureHistoryIsBounded()
        testPluginPublishesWhatItCollected()
        testProcessesFollowTheFeed()
        testPluginIdentityMatchesTheOldTab()
    }

    // Paste testSwapStatText and testMemorySegmentsMatchEveryBarSegment here, unchanged.

    private static let pressureOutput = """
    The system has 17179869184 (1048576 pages with a page size of 16384).
    System-wide memory free percentage: 63%
    """

    private static let ioregOutput = """
    +-o AGXAcceleratorG14X  <class AGXAcceleratorG14X, id 0x100000abc, registered, matched, active>
        "PerformanceStatistics" = {"In use system memory"=123456789,"Device Utilization %"=12}
    """

    private static let answers = [
        "/usr/bin/memory_pressure": pressureOutput,
        "/usr/sbin/ioreg -r -c AGXAccelerator -d 2": ioregOutput,
    ]

    private static func testMemorySnapshotDoesNotLeakHostPortRights() {
        // mach_host_self() hands back a send right and bumps its user-reference count; the
        // caller owns that reference. A sampler that never deallocates it leaks one per call,
        // unbounded, in a process that runs for weeks.
        let probePort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, probePort) }

        var before: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, probePort, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before)
        for _ in 0..<50 {
            _ = MemoryCollector.collectMemorySnapshot()
        }
        var after: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, probePort, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after)

        expect(after <= before + 5, "host port send-right refs should not grow with repeated sampling: before=\(before) after=\(after)")
    }

    private static func testPressureAndGPUAreReadEveryThirtySeconds() {
        let recorder = LogRecorder()
        let collector = MemoryCollector(host: makeHost(runner: recordingRunner(recorder, answers: answers)))
        let start = Date(timeIntervalSince1970: 10_000)

        let first = collector.sample(at: start)
        let soon = collector.sample(at: start.addingTimeInterval(3))
        _ = collector.sample(at: start.addingTimeInterval(31))

        expect(first.pressure == 37, "63% free is 37% pressure, got \(String(describing: first.pressure))")
        expect(first.gpu.deviceUtilization == 12 && first.gpu.inUseMemory == 123_456_789, "the GPU figures come from ioreg, got \(first.gpu)")
        expect(soon.pressure == 37 && soon.gpu.deviceUtilization == 12, "between refreshes the cached figures stand")
        expect(recorder.messages.filter { $0 == "/usr/bin/memory_pressure" }.count == 2, "memory_pressure runs at the first sample and again once 30 seconds have passed, not every 3 seconds, got \(recorder.messages)")
        expect(recorder.messages.filter { $0.hasPrefix("/usr/sbin/ioreg ") }.count == 2, "and so does ioreg, got \(recorder.messages)")
    }

    private static func testPressureHistoryIsBounded() {
        let reading = MemoryReading(memory: MemorySnapshot(), gpu: GPUSnapshot(), pressure: 50, sampledAt: Date(timeIntervalSince1970: 0))
        let stats = (0..<100).reduce(MemoryStatsSnapshot()) { stats, _ in stats.recording(reading) }
        expect(stats.pressureHistory.count == MemorySampling.pressureHistoryLimit, "the pressure history keeps the last \(MemorySampling.pressureHistoryLimit) readings, got \(stats.pressureHistory.count)")

        let unknownAt = Date(timeIntervalSince1970: 1)
        let unknown = stats.recording(MemoryReading(memory: MemorySnapshot(), gpu: GPUSnapshot(), pressure: nil, sampledAt: unknownAt))
        expect(unknown.pressure == nil && unknown.lastUpdated == unknownAt, "an unknown pressure shows as unknown, and the sample is still dated")
        expect(unknown.pressureHistory.count == MemorySampling.pressureHistoryLimit, "and it adds nothing to the history")
    }

    private static func testPluginPublishesWhatItCollected() {
        let plugin = MemoryPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)))
        plugin.collect()
        waitUntil { plugin.stats.lastUpdated != nil }
        expect(plugin.stats.pressure == 37 && plugin.stats.pressureHistory == [37], "collect() publishes the reading for the panel, got \(plugin.stats.pressureHistory)")
        expect(plugin.stats.memory.total > 0, "the kernel's memory figures are read directly, got total \(plugin.stats.memory.total)")
    }

    private static func testProcessesFollowTheFeed() {
        let first = ProcessSnapshot(name: "Safari", count: 1, physical: 2_000, virtualSize: 0, cpu: 1)
        let feed = Feed(initial: ProcessSummary(rows: [first], limit: 1))
        let plugin = MemoryPlugin(host: makeHost(processes: feed))
        expect(plugin.processes.topMemory.map(\.name) == ["Safari"], "a new plugin starts from the feed's latest reading")

        let next = ProcessSnapshot(name: "Xcode", count: 1, physical: 4_000, virtualSize: 0, cpu: 1)
        feed.send(ProcessSummary(rows: [next], limit: 1))
        waitUntil { plugin.processes.topMemory.first?.name == "Xcode" }
        expect(plugin.processes.topMemory.map(\.name) == ["Xcode"], "and follows every reading after, got \(plugin.processes.topMemory.map(\.name))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = MemoryPlugin(host: makeHost())
        expect(MemoryPlugin.identifier == "memory" && plugin.title == "Memory" && plugin.systemImage == "memorychip", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.good, "and its accent")
        expect(plugin.refreshInterval == 3 && plugin.sharedFeeds == [.processes], "and its 3-second interval and its need for the process feed")
        expect(MemorySampling.pressureRefreshInterval == 30, "memory_pressure and ioreg stay on their 30-second cache")
    }
}
```

In `SystemBarPerformanceTests.swift`:

- In `main()`, replace the two lines `testSwapStatText()` and `testMemorySegmentsMatchEveryBarSegment()` with `MainActor.assumeIsolated { MemoryTests.runAll() }`.
- Delete the two functions you pasted into `MemoryTests`.
- In `testCollectorsDoNotLeakHostPortRights`, delete `_ = UnifiedMonitor.collectMemorySnapshot()` (the memory half is `MemoryTests.testMemorySnapshotDoesNotLeakHostPortRights` now).
- In `testSamplingPlan`, delete the `mode: .memory) == [.memory]` expect.

In `SystemBarLoaderTests.swift`, `testHostSourcePrefersABundleOverTheCompiledInTab`: Memory is no longer compiled in, so the fallback line uses the one tab that stays compiled in the longest. Change `(try? source.resolve(entry("Memory.bundle")))?.identifier == "memory"` to `(try? source.resolve(entry("Network.bundle")))?.identifier == "network"`.

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `build-plugin.sh: no Info.plist at Plugins/Memory//Info.plist`.

- [ ] **Step 3: `Info.plist` and `MemoryModels.swift`**

```bash
mkdir -p /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources
sed -e 's/<string>Power<\/string>/<string>Memory<\/string>/g' -e 's/systembar\.power/systembar.memory/' -e 's/SystemBarPowerPlugin/SystemBarMemoryPlugin/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Power/Info.plist > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Info.plist
for key in CFBundleExecutable CFBundleName CFBundleIdentifier NSPrincipalClass; do /usr/libexec/PlistBuddy -c "Print :$key" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Info.plist; done
```

Expected: `Memory`, `Memory`, `com.ih8celery.systembar.memory`, `SystemBarMemoryPlugin`.

`Plugins/Memory/Sources/MemoryModels.swift`:

```swift
import Foundation
import SystemBarKit

// Move these from Sources/Host/Models.swift unchanged: `struct MemorySnapshot` (original
// lines 27–39), `struct GPUSnapshot` (150–153) and `struct MemoryStatsSnapshot` (348–354).

/// How often the Memory tab samples.
enum MemorySampling {
    static let refreshInterval: TimeInterval = 3
    /// memory_pressure and ioreg are subprocesses whose answers change slowly, so they are read
    /// this often and cached in between.
    static let pressureRefreshInterval: TimeInterval = 30
    /// Eighty readings: four minutes of history at the 3-second interval.
    static let pressureHistoryLimit = 80
}

/// One collect's worth of readings.
struct MemoryReading {
    let memory: MemorySnapshot
    let gpu: GPUSnapshot
    let pressure: Double?
    let sampledAt: Date
}

extension MemoryStatsSnapshot {
    /// A copy with one reading applied. An unknown pressure shows as unknown and adds nothing to
    /// the history.
    func recording(_ reading: MemoryReading) -> MemoryStatsSnapshot {
        var next = self
        next.memory = reading.memory
        next.gpu = reading.gpu
        next.pressure = reading.pressure
        if let pressure = reading.pressure {
            BoundedHistory.append(pressure, to: &next.pressureHistory, limit: MemorySampling.pressureHistoryLimit)
        }
        next.lastUpdated = reading.sampledAt
        return next
    }
}
```

Delete `MemorySnapshot`, `GPUSnapshot` and `MemoryStatsSnapshot` from `Sources/Host/Models.swift`.

- [ ] **Step 4: `MemoryCollector.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+Memory.swift Plugins/Memory/Sources/MemoryCollector.swift
```

Rewrite the file as below. `collectMemorySnapshot` is old lines 40–86 unchanged; the three `in:key:` helpers are `UnifiedMonitor+SpeedTest.swift` lines 160–187 unchanged (they were in the speed-test file but only Memory ever used them).

```swift
import Darwin
import Foundation
import SystemBarKit

/// The Memory tab's sampler. The kernel's memory figures are read on every collect (every 3
/// seconds); memory_pressure and ioreg are slower subprocesses, so their answers are cached and
/// refreshed every 30 seconds. Only the plugin's queue calls `sample`, which is what makes the
/// unlocked cache safe.
final class MemoryCollector: @unchecked Sendable {
    private let host: HostServices
    private var lastPressureRefresh = Date.distantPast
    private var cachedPressure: Double?
    private var cachedGPU = GPUSnapshot()

    init(host: HostServices) {
        self.host = host
    }

    func sample(at date: Date = Date()) -> MemoryReading {
        let memory = Self.collectMemorySnapshot()
        if date.timeIntervalSince(lastPressureRefresh) >= MemorySampling.pressureRefreshInterval {
            lastPressureRefresh = date
            cachedPressure = collectMemoryPressure()
            cachedGPU = collectGPUSnapshot()
        }
        return MemoryReading(memory: memory, gpu: cachedGPU, pressure: cachedPressure, sampledAt: date)
    }

    // Move old lines 40–86 here unchanged: `static func collectMemorySnapshot() -> MemorySnapshot`.

    func collectMemoryPressure() -> Double? {
        let result = host.run(path: "/usr/bin/memory_pressure", arguments: [])
        guard result.status == 0 else { return nil }

        for line in result.output.split(whereSeparator: \.isNewline) {
            guard line.contains("System-wide memory free percentage") else { continue }
            let digits = line.filter(\.isNumber)
            guard let freePercent = Double(String(digits)) else { return nil }
            return max(0, min(100, 100 - freePercent))
        }

        return nil
    }

    func collectGPUSnapshot() -> GPUSnapshot {
        let result = host.run(path: "/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXAccelerator", "-d", "2"])
        guard result.status == 0, result.output.contains("AGXAccelerator") else {
            return GPUSnapshot()
        }

        return GPUSnapshot(
            deviceUtilization: Self.doubleValue(in: result.output, key: "Device Utilization %") ?? 0,
            inUseMemory: Self.uint64Value(in: result.output, key: "In use system memory") ?? 0
        )
    }

    // Move UnifiedMonitor+SpeedTest.swift lines 160–187 here unchanged:
    // `static func stringValue(in:key:)`, `static func doubleValue(in:key:)`, `static func uint64Value(in:key:)`.
}
```

Delete lines 160–187 from `Sources/Host/UnifiedMonitor+SpeedTest.swift`.

- [ ] **Step 5: `MemoryFormatting.swift` and `MemoryPlugin.swift`**

`Plugins/Memory/Sources/MemoryFormatting.swift` (moved from `Sources/Host/Views/HostFormatting.swift` lines 7–9, which you delete there):

```swift
import Foundation
import SystemBarKit

/// "used / total" for the Swap pill. Both sides always show, so an empty swap reads "0 B / 0 B".
func swapStatText(used: UInt64, total: UInt64) -> String {
    "\(byteString(used)) / \(byteString(total))"
}
```

`Plugins/Memory/Sources/MemoryPlugin.swift`:

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

@objc(SystemBarMemoryPlugin)
public final class MemoryPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "memory"
    public let title = "Memory"
    public let systemImage = "memorychip"
    public let accent = Palette.good
    public let refreshInterval: TimeInterval = MemorySampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.processes]

    @Published private(set) var stats = MemoryStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    private let collector: MemoryCollector
    private var feedSubscription: AnyCancellable?

    @MainActor public init(host: HostServices) {
        collector = MemoryCollector(host: host)
        super.init()
        processes = host.processes.value
        feedSubscription = host.processes.publisher.sink { [weak self] summary in
            self?.processes = summary
        }
    }

    public func collect() {
        let reading = collector.sample()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats = self.stats.recording(reading)
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(MemoryPanel(plugin: self))
    }
}
```

- [ ] **Step 6: `MemoryPanel.swift` observes the plugin**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/Views/MemoryPanel.swift Plugins/Memory/Sources/MemoryPanel.swift
sed -i '' \
  -e 's/@ObservedObject var monitor: UnifiedMonitor/@ObservedObject var plugin: MemoryPlugin/' \
  -e 's/monitor\.pressureHistory/plugin.stats.pressureHistory/g' \
  -e 's/monitor\.memory/plugin.stats.memory/g' \
  -e 's/monitor\.gpu/plugin.stats.gpu/g' \
  -e 's/monitor\.pressure/plugin.stats.pressure/g' \
  -e 's/monitor\.lastUpdated/plugin.stats.lastUpdated/g' \
  -e 's/monitor\.topMemoryProcesses/plugin.processes.topMemory/g' \
  -e 's/monitor\.maxPhysicalProcessMemory/plugin.processes.maxPhysical/g' \
  /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryPanel.swift
grep -n "monitor" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Memory/Sources/MemoryPanel.swift
```

Expected: no output. (`pressureHistory` is replaced before `pressure` so the shorter pattern cannot cut the longer name in half.)

- [ ] **Step 7: Delete Memory's slice of the host**

`Sources/Host/UnifiedMonitor.swift` — delete:

```
    @Published var memoryStats = MemoryStatsSnapshot()
    private let memoryQueue = DispatchQueue(label: "systembar.monitor.memory", qos: .utility)
    var isCollectingMemory = false
    var lastPressureRefresh = Date.distantPast
    var cachedPressure: Double?
    var cachedGPU = GPUSnapshot()
    var memory: MemorySnapshot { memoryStats.memory }
    var gpu: GPUSnapshot { memoryStats.gpu }
    var pressure: Double? { memoryStats.pressure }
    var pressureHistory: [Double] { memoryStats.pressureHistory }
    var lastUpdated: Date? { memoryStats.lastUpdated }
    var topMemoryProcesses: [ProcessSnapshot] { processSummary.topMemory }
    var maxPhysicalProcessMemory: UInt64 { processSummary.maxPhysical }
            makeTimer(every: MonitorSamplingPlan.memoryRefreshInterval, leeway: .seconds(1), job: .memory),
        case .memory: memoryQueue.async { [weak self] in self?.collectMemory() }
```

`Sources/Host/Models.swift` — in `MonitorMode` delete `case memory = "Memory"` and `case .memory: return "memorychip"`; in `MonitorJob` delete `case memory`; in `MonitorSamplingPlan` delete `memoryRefreshInterval`, `pressureRefreshInterval` and the two lines `case .memory:` / `return [.memory]`.

`Sources/Host/BuiltinTabs.swift` — delete the row `("Memory.bundle", MemoryTab.self),` and the whole `final class MemoryTab`.

```bash
grep -rn "memoryStats\|MemoryTab\|case memory\|case .memory\|swapStatText\|memoryRefresh\|pressureRefresh\|Value(in:" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host
```

Expected: no output.

- [ ] **Step 8: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`.

- [ ] **Step 9: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Plugins/Memory/Info.plist Plugins/Memory/Sources/MemoryModels.swift Plugins/Memory/Sources/MemoryFormatting.swift Plugins/Memory/Sources/MemoryPlugin.swift Plugins/Memory/Tests/MemoryTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Move the Memory tab into its own bundle" -m "The plugin samples the kernel's memory figures on its own queue, keeps
memory_pressure and ioreg on their 30-second cache, and follows the host's
process feed for its top-memory list.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Plugins/Memory Sources/Host/UnifiedMonitor+Memory.swift Sources/Host/Views/MemoryPanel.swift Sources/Host/UnifiedMonitor.swift Sources/Host/UnifiedMonitor+SpeedTest.swift Sources/Host/Models.swift Sources/Host/BuiltinTabs.swift Sources/Host/Views/HostFormatting.swift SystemBarPerformanceTests.swift SystemBarLoaderTests.swift
```

---

## Task 6: CPU moves out

Everything CPU shows comes from the two shared feeds, so its `collect()` does nothing; its one command is the drill-in `ps` when a row is tapped.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Info.plist`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources/ProcessClassifier.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources/CPUPlugin.swift`
- Create (git mv): `Sources/Host/UnifiedMonitor+Processes.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources/ProcessDetail.swift`
- Create (git mv): `Sources/Host/Views/CPUPanel.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources/CPUPanel.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/UnifiedMonitor.swift`, `Sources/Host/Models.swift`, `Sources/Host/BuiltinTabs.swift`, `Sources/Host/App.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Tests/CPUTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift`

- [ ] **Step 1: Move the drill-in tests and write the new ones**

Create `Plugins/CPU/Tests/CPUTests.swift` with the content below. At the marked place paste, cut from `SystemBarPerformanceTests.swift`: `testParentChainWalk` and `testGroupDetailRows` (originally lines 374–400), the `detail(...)` helper and `testProcessClassifier` (originally lines 402–454). In the pasted code change `UnifiedMonitor.parentChain(` to `ProcessDetail.parentChain(` and `UnifiedMonitor.groupDetail(` to `ProcessDetail.groupDetail(` (the `ProcessTable.parse` calls are already right from Task 1). Leave `psSample` and `testProcessTableParsing` in the performance tests, which still use them; `CPUTests` has its own copy of the sample below.

```swift
import Foundation
import SystemBarKit

/// The CPU tab: the tap-to-explain drill-in, and the plugin that follows both shared feeds.
@MainActor
enum CPUTests {
    static func runAll() {
        testParentChainWalk()
        testGroupDetailRows()
        testProcessClassifier()
        testGroupDetailRunsPsThroughTheHost()
        testPluginFollowsBothFeeds()
        testPluginIdentityMatchesTheOldTab()
    }

    // A `ps -eo pid,ppid,pcpu,rss,etime,args` sample. Leading fields are
    // space-free; args is the whole trailing remainder (spaces preserved).
    // A copy of the one in SystemBarPerformanceTests, which tests the SDK parser with it.
    private static let psSample = """
    PID  PPID %CPU   RSS     ELAPSED ARGS
      1     0  0.0  20000 10-00:00:00 /sbin/launchd
    100     1  1.5   5000    01:00:00 /usr/bin/ssh-agent -l
    200   100 50.0  40000    00:10:00 /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c foo.c
    201   200 40.0  30000    00:05:00 /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x c bar.c
    """

    // Paste testParentChainWalk, testGroupDetailRows, detail(...) and testProcessClassifier here.

    private static func testGroupDetailRunsPsThroughTheHost() {
        let recorder = LogRecorder()
        let command = "/bin/ps -eo pid,ppid,pcpu,rss,etime,args"
        let plugin = CPUPlugin(host: makeHost(runner: recordingRunner(recorder, answers: [command: psSample])))
        let rows = plugin.groupDetail(named: "clang")
        expect(rows.map(\.pid).sorted() == [200, 201], "a tap lists every process in the group, got \(rows.map(\.pid))")
        expect(recorder.messages == [command], "one ps, through the host, by explicit path, got \(recorder.messages)")

        let failing = CPUPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.groupDetail(named: "clang").isEmpty, "a ps that fails gives an empty drill-in rather than a guess")
    }

    private static func testPluginFollowsBothFeeds() {
        var start = FastStatsSnapshot()
        start.cpuUsagePercent = 10
        let fastStats = Feed(initial: start)
        let processes = Feed(initial: ProcessSummary())
        let plugin = CPUPlugin(host: makeHost(processes: processes, fastStats: fastStats))
        expect(plugin.fastStats.cpuUsagePercent == 10, "a new plugin starts from the feed's latest reading")

        var busy = FastStatsSnapshot()
        busy.cpuUsagePercent = 73
        busy.cpuHistory = [10, 73]
        fastStats.send(busy)
        let row = ProcessSnapshot(name: "swift-frontend", count: 3, physical: 1, virtualSize: 0, cpu: 250)
        processes.send(ProcessSummary(rows: [row], limit: 1))

        waitUntil { plugin.fastStats.cpuUsagePercent == 73 && !plugin.processes.topCPU.isEmpty }
        expect(plugin.fastStats.cpuHistory == [10, 73], "the headline and graph follow the 1-second feed, got \(plugin.fastStats.cpuHistory)")
        expect(plugin.processes.topCPU.map(\.name) == ["swift-frontend"] && plugin.processes.totalCount == 1, "the list and count follow the process feed")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = CPUPlugin(host: makeHost())
        expect(CPUPlugin.identifier == "cpu" && plugin.title == "CPU" && plugin.systemImage == "cpu", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.warning, "and its accent")
        expect(plugin.sharedFeeds == [.processes, .fastStats], "it needs both shared feeds")
        expect(plugin.refreshInterval == PluginScheduler.maximumRefreshInterval, "its collect() does nothing, so it asks to be called as rarely as the host allows, got \(plugin.refreshInterval)")
    }
}
```

In `SystemBarPerformanceTests.swift`'s `main()`, replace the three lines `testParentChainWalk()`, `testGroupDetailRows()` and `testProcessClassifier()` with `MainActor.assumeIsolated { CPUTests.runAll() }`, and delete the four pasted functions from that file.

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `build-plugin.sh: no Info.plist at Plugins/CPU//Info.plist`.

- [ ] **Step 3: `Info.plist`**

```bash
mkdir -p /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources
sed -e 's/<string>Power<\/string>/<string>CPU<\/string>/g' -e 's/systembar\.power/systembar.cpu/' -e 's/SystemBarPowerPlugin/SystemBarCPUPlugin/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Power/Info.plist > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Info.plist
for key in CFBundleExecutable CFBundleName CFBundleIdentifier NSPrincipalClass; do /usr/libexec/PlistBuddy -c "Print :$key" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Info.plist; done
```

Expected: `CPU`, `CPU`, `com.ih8celery.systembar.cpu`, `SystemBarCPUPlugin`.

- [ ] **Step 4: `ProcessDetail.swift` and `ProcessClassifier.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+Processes.swift Plugins/CPU/Sources/ProcessDetail.swift
```

After Tasks 1 and 2 this file holds only the imports, `extension UnifiedMonitor {`, the `// MARK: - On-demand process drill-in` line, `parentChain`, `groupDetail` and `fetchGroupDetail`. Change it as follows:

- Between the imports and the extension, paste `struct ProcessDetail` (with its doc comment) cut from `Sources/Host/Models.swift` (originally lines 53–65), unchanged.
- `extension UnifiedMonitor {` becomes `extension ProcessDetail {`.
- `parentChain` and `groupDetail`: unchanged.
- Replace `fetchGroupDetail(name:)` with:

```swift
    /// Runs the on-demand `ps` snapshot through the host and returns the tapped group's rows.
    /// Called on tap only — no cost to the idle sampling loop.
    static func fetchGroupDetail(name: String, using host: HostServices) -> [ProcessDetail] {
        let result = host.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)
        guard result.status == 0 else { return [] }
        let map = ProcessTable.parse(result.output)
        return groupDetail(name: name, in: map, coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }
```

Create `Plugins/CPU/Sources/ProcessClassifier.swift`: `import Foundation`, a blank line, then `enum ProcessClassifier` with its doc comment cut from `Sources/Host/Models.swift` (originally lines 67–148), unchanged.

- [ ] **Step 5: `CPUPlugin.swift`**

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

@objc(SystemBarCPUPlugin)
public final class CPUPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "cpu"
    public let title = "CPU"
    public let systemImage = "cpu"
    public let accent = Palette.warning
    /// A day: the longest the host allows (PluginScheduler.maximumRefreshInterval, which a
    /// bundle cannot name). collect() has nothing to do, so the less often it is called the better.
    public let refreshInterval: TimeInterval = 86_400
    public let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]

    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    private let host: HostServices
    private var feedSubscriptions: [AnyCancellable] = []

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
        fastStats = host.fastStats.value
        processes = host.processes.value
        feedSubscriptions = [
            host.fastStats.publisher.sink { [weak self] snapshot in self?.fastStats = snapshot },
            host.processes.publisher.sink { [weak self] summary in self?.processes = summary },
        ]
    }

    /// Everything this tab shows comes from the two shared feeds, which the host samples while
    /// the tab is visible, so there is nothing of its own to sample.
    public func collect() {}

    /// The tapped group's processes, from a fresh `ps`. Blocking: the panel calls it off main.
    func groupDetail(named name: String) -> [ProcessDetail] {
        ProcessDetail.fetchGroupDetail(name: name, using: host)
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(CPUPanel(plugin: self))
    }
}
```

- [ ] **Step 6: `CPUPanel.swift` observes the plugin**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/Views/CPUPanel.swift Plugins/CPU/Sources/CPUPanel.swift
sed -i '' \
  -e 's/@ObservedObject var monitor: UnifiedMonitor/@ObservedObject var plugin: CPUPlugin/' \
  -e 's/monitor\.topCPUProcesses/plugin.processes.topCPU/g' \
  -e 's/monitor\.cpuUsagePercent/plugin.fastStats.cpuUsagePercent/g' \
  -e 's/monitor\.totalProcessCount/plugin.processes.totalCount/g' \
  -e 's/monitor\.cpuHistory/plugin.fastStats.cpuHistory/g' \
  -e 's/UnifiedMonitor\.fetchGroupDetail(name: row\.name)/plugin.groupDetail(named: row.name)/' \
  -e 's/(see UnifiedMonitor\.fetchGroupDetail)/(see ProcessDetail.fetchGroupDetail)/' \
  /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources/CPUPanel.swift
grep -n "monitor\|UnifiedMonitor" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/CPU/Sources/CPUPanel.swift
```

Expected: no output.

- [ ] **Step 7: Delete CPU's slice of the host**

`Sources/Host/UnifiedMonitor.swift` — delete `@Published var processSummary = ProcessSummary()` and the forwarders `cpuUsagePercent`, `cpuHistory`, `topCPUProcesses` and `totalProcessCount`. Only the Network panel is left reading the monitor, and it needs only the 1-second feed, so replace `follow(processes:fastStats:)` with:

```swift
    /// The Network panel, the last one compiled in, reads the host's 1-second feed through here
    /// until it moves into its bundle.
    func follow(fastStats: Feed<FastStatsSnapshot>) {
        self.fastStats = fastStats.value
        feedSinks = [fastStats.publisher.sink { [weak self] in self?.fastStats = $0 }]
    }
```

`Sources/Host/App.swift` — `UnifiedMonitor.shared.follow(processes: processes, fastStats: fastStats)` becomes `UnifiedMonitor.shared.follow(fastStats: fastStats)`.

`Sources/Host/Models.swift` — `ProcessDetail` and `ProcessClassifier` are gone already (Step 4); in `MonitorMode` delete `case cpu = "CPU"` and `case .cpu: return "cpu"`; in `MonitorSamplingPlan.jobs` delete the two lines `case .cpu:` / `return []`.

`Sources/Host/BuiltinTabs.swift` — delete the row `("CPU.bundle", CPUTab.self),` and the whole `final class CPUTab`.

```bash
grep -rn "processSummary\|CPUTab\|case cpu\|case .cpu\|ProcessDetail\|ProcessClassifier\|fetchGroupDetail" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host
```

Expected: no output.

- [ ] **Step 8: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`.

- [ ] **Step 9: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Plugins/CPU/Info.plist Plugins/CPU/Sources/ProcessClassifier.swift Plugins/CPU/Sources/CPUPlugin.swift Plugins/CPU/Tests/CPUTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Move the CPU tab into its own bundle" -m "Everything CPU shows comes from the host's two shared feeds, so its
collect() is empty and it asks for the longest interval the host allows. The
drill-in runs its ps through host.run and parses it with the SDK.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Plugins/CPU Sources/Host/UnifiedMonitor+Processes.swift Sources/Host/Views/CPUPanel.swift Sources/Host/UnifiedMonitor.swift Sources/Host/Models.swift Sources/Host/BuiltinTabs.swift Sources/Host/App.swift SystemBarPerformanceTests.swift
```

---

## Task 7: Network moves out, and the compiled-in machinery goes with it

Network is the last compiled-in tab. Once it leaves, `MonitorMode` would have no cases, and Swift refuses an enum with a raw type and no cases, so this task also deletes everything that existed only to key sampling by mode: `MonitorMode`, `MonitorJob`, `MonitorSamplingPlan`, `Models.swift`, `MonitorBackedTab`, `BuiltinTabSource`, `HostTabSource.swift`, `HostFormatting.swift` and `UnifiedMonitor*`. The app loads every tab through `BundleTabSource.standard()`, and the loader tests that exercised the built-in table are rewritten against `MapTabSource`.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Info.plist`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkModels.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkFormatting.swift`
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkPlugin.swift`
- Create (git mv): `Sources/Host/UnifiedMonitor+Network.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkCollector.swift`
- Create (git mv): `Sources/Host/UnifiedMonitor+SpeedTest.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/SpeedTest.swift`
- Create (git mv): `Sources/Host/Views/NetworkPanel.swift` -> `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkPanel.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/TabLoader.swift` (gains `DefaultPlugins`)
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/App.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Views/RootView.swift`
- Delete: `Sources/Host/UnifiedMonitor.swift`, `Sources/Host/UnifiedMonitor+ProcessRunner.swift`, `Sources/Host/Models.swift`, `Sources/Host/BuiltinTabs.swift`, `Sources/Host/HostTabSource.swift`, `Sources/Host/Views/HostFormatting.swift` (all under `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/`)
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Tests/NetworkTests.swift`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift`, `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarLoaderTests.swift`

- [ ] **Step 1: Move the network tests and write the new ones**

The seven network tests sit together in the performance tests, from `private static func testHostnameCacheEntryExpiry() {` to the closing brace of `testParseNetworkQualitySummary()` (originally lines 585–701). Find the two ends in today's file:

```bash
grep -n "private static func testHostnameCacheEntryExpiry\|private static func testSampleHealthFromIsOK" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
```

Call the first line number `A` and the second `B`. The block to move is `A` to `B-2` (line `B-1` is blank). Check both ends before cutting:

```bash
sed -n "${A}p;$((B-2))p" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
```

Expected: `    private static func testHostnameCacheEntryExpiry() {` then `    }`.

Build `NetworkTests.swift` from a header, the moved block (with `UnifiedMonitor.parseNetworkQuality…` renamed to `SpeedTest.parseNetworkQuality…` and every other `UnifiedMonitor.` to `NetworkCollector.`), and the new tests. Set `A` and `B` in the same shell first:

```bash
A=<first line number>; B=<second line number>
mkdir -p /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Tests /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources
{
cat <<'SWIFT'
import Foundation
import SystemBarKit

/// The Network tab: nettop and lsof parsing, the hostname cache, the speed test, and the plugin
/// that runs them and follows the 1-second feed.
@MainActor
enum NetworkTests {
    static func runAll() {
        testHostnameCacheEntryExpiry()
        testParseCSVLine()
        testParseNettopCSV()
        testParseLsofTCP()
        testIsLANAddress()
        testParseNetworkQualityJSON()
        testParseNetworkQualitySummary()
        testSampleRunsNettopAndLsofThroughTheHost()
        testSampleSaysWhichCommandFailed()
        testSummaryKeepsResolvedNamesAcrossSamples()
        testSpeedTestRunsNetworkQualityThroughTheHost()
        testSpeedTestStateShowsEachStage()
        testPluginRunsTheSpeedTestOffTheMainThread()
        testPluginPublishesWhatItCollected()
        testPluginFollowsTheFastFeed()
        testPluginIdentityMatchesTheOldTab()
    }

SWIFT
sed -n "${A},$((B-2))p" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift | sed -e 's/UnifiedMonitor\.parseNetworkQuality/SpeedTest.parseNetworkQuality/g' -e 's/UnifiedMonitor\./NetworkCollector./g'
cat <<'SWIFT'

    private static let nettopCommand = "/usr/bin/nettop -d -P -L 2 -s 1 -x -n -J bytes_in,bytes_out"
    private static let lsofCommand = "/usr/sbin/lsof -n -P -iTCP"
    private static let speedTestCommand = "/usr/bin/networkQuality -c -M 20"

    private static let nettopOutput = """
    Name,bytes_in,bytes_out
    Safari.501,1000,500
    Chrome.502,2000,800
    Name,bytes_in,bytes_out
    Safari.501,50,20
    Chrome.502,80,40
    """

    private static let lsofOutput = """
    COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    Safari   1234  adamu   50u  IPv4 0x1  0t0  TCP 192.168.1.5:54321->17.253.144.10:443 (ESTABLISHED)
    Terminal 5555  adamu   12u  IPv4 0x4  0t0  TCP 192.168.1.5:60000->192.168.1.10:22 (ESTABLISHED)
    """

    /// Only a LAN connection, so a plugin test never starts a real reverse-DNS lookup.
    private static let lanOnlyLsofOutput = """
    COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    Terminal 5555  adamu   12u  IPv4 0x4  0t0  TCP 192.168.1.5:60000->192.168.1.10:22 (ESTABLISHED)
    """

    private static let speedTestJSON = """
    {"dl_throughput": 150000000, "ul_throughput": 20000000, "base_rtt": 12.5, "interface_name": "en0", "test_endpoint": "https://mensura.cdn-apple.com"}
    """

    private static func testSampleRunsNettopAndLsofThroughTheHost() {
        let recorder = LogRecorder()
        let collector = NetworkCollector(host: makeHost(runner: recordingRunner(recorder, answers: [nettopCommand: nettopOutput, lsofCommand: lsofOutput])))
        let reading = collector.sample()
        expect(Set(recorder.messages) == [nettopCommand, lsofCommand], "nettop and lsof run through the host by explicit path, got \(recorder.messages)")
        expect(reading.processes.map(\.name) == ["Chrome", "Safari"], "busiest first, by combined rate, got \(reading.processes.map(\.name))")
        expect(reading.destinations.map(\.remoteAddress) == ["17.253.144.10"], "only internet destinations are listed, got \(reading.destinations.map(\.remoteAddress))")
        expect(reading.status == "Network sample OK" && reading.health == .ok, "two good reads are a healthy sample, got \(reading.status)")
    }

    private static func testSampleSaysWhichCommandFailed() {
        let collector = NetworkCollector(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        let reading = collector.sample()
        expect(reading.status == "nettop unavailable, lsof unavailable" && reading.health == .degraded, "each failed command is named, got \(reading.status)")
        expect(reading.processes.isEmpty && reading.destinations.isEmpty, "and nothing is invented")
    }

    private static func testSummaryKeepsResolvedNamesAcrossSamples() {
        let named = NetworkSummary().resolving("17.253.144.10", to: "apple.com")
        expect(named.resolvedHostnames == ["17.253.144.10": "apple.com"], "a finished lookup is recorded by address")
        let next = named.applying(NetworkReading(processes: [], destinations: [], status: "Network sample OK", health: .ok))
        expect(next.resolvedHostnames["17.253.144.10"] == "apple.com", "a new sample keeps the names already resolved")
        expect(next.status == "Network sample OK" && next.health == .ok, "and takes the new status")
    }

    private static func testSpeedTestRunsNetworkQualityThroughTheHost() {
        let recorder = LogRecorder()
        let outcome = SpeedTest.measure(using: makeHost(runner: recordingRunner(recorder, answers: [speedTestCommand: speedTestJSON])), startedAt: Date())
        expect(recorder.messages == [speedTestCommand], "networkQuality runs through the host by explicit path, got \(recorder.messages)")
        expect(outcome.result?.downloadMbps == 150 && outcome.result?.uploadMbps == 20, "its JSON is read, got \(String(describing: outcome.result))")

        let failing = makeHost(runner: { _, _, _, _ in
            CommandOutput(output: "", error: "no network\nsecond line", status: 1, didTimeout: false)
        })
        let failed = SpeedTest.measure(using: failing, startedAt: Date())
        expect(failed.result == nil && failed.failure == "Failed: no network", "a failed run says why in one line, got \(failed.failure)")
    }

    private static func testSpeedTestStateShowsEachStage() {
        let idle = SpeedTestState()
        expect(!idle.isRunning && idle.status == "Ready" && idle.health == .ok && idle.result == nil, "a fresh tab is ready")
        let running = idle.started()
        expect(running.isRunning && running.status == "Testing", "pressing the button shows it testing")

        let result = SpeedTestResult(downloadMbps: 100, uploadMbps: 10, latencyMS: 9, interfaceName: "en0", endpoint: "x", measuredAt: Date(timeIntervalSince1970: 0), duration: 12)
        let done = running.finished(with: SpeedTestOutcome(result: result, failure: "unused"))
        expect(!done.isRunning && done.result?.downloadMbps == 100 && done.health == .ok, "a good run shows its result")
        expect(done.status.hasPrefix("Last run "), "and when it ran, got \(done.status)")

        let failed = done.started().finished(with: SpeedTestOutcome(result: nil, failure: "Failed: offline"))
        expect(failed.status == "Failed: offline" && failed.health == .degraded, "a failed run says why")
        expect(failed.result?.downloadMbps == 100, "and keeps the last good result on screen")
    }

    private static func testPluginRunsTheSpeedTestOffTheMainThread() {
        let plugin = NetworkPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: [speedTestCommand: speedTestJSON])))
        plugin.runSpeedTest()
        expect(plugin.speedTest.isRunning, "the button shows the test running at once, before networkQuality answers")
        waitUntil(2) { !plugin.speedTest.isRunning }
        expect(plugin.speedTest.result?.downloadMbps == 150, "the result lands on main when the run finishes, got \(String(describing: plugin.speedTest.result))")
    }

    private static func testPluginPublishesWhatItCollected() {
        let answers = [nettopCommand: nettopOutput, lsofCommand: lanOnlyLsofOutput]
        let plugin = NetworkPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)))
        plugin.collect()
        waitUntil { !plugin.summary.processes.isEmpty }
        expect(plugin.summary.processes.map(\.name) == ["Chrome", "Safari"], "collect() publishes the sample for the panel, got \(plugin.summary.processes.map(\.name))")
        expect(plugin.summary.destinations.isEmpty && plugin.summary.status == "Network sample OK", "a LAN-only connection lists no destination")
    }

    private static func testPluginFollowsTheFastFeed() {
        var start = FastStatsSnapshot()
        start.currentDownloadRate = 5
        let feed = Feed(initial: start)
        let plugin = NetworkPlugin(host: makeHost(fastStats: feed))
        expect(plugin.fastStats.currentDownloadRate == 5, "a new plugin starts from the feed's latest reading")

        var next = FastStatsSnapshot()
        next.currentDownloadRate = 2_048
        next.downloadHistory = [5, 2_048]
        feed.send(next)
        waitUntil { plugin.fastStats.currentDownloadRate == 2_048 }
        expect(plugin.fastStats.downloadHistory == [5, 2_048], "the rate cards and graph follow the 1-second feed, got \(plugin.fastStats.downloadHistory)")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = NetworkPlugin(host: makeHost())
        expect(NetworkPlugin.identifier == "network" && plugin.title == "Network" && plugin.systemImage == "arrow.up.arrow.down", "the bundle keeps the tab's id, title and icon")
        expect(plugin.accent == Palette.blue, "and its accent")
        expect(plugin.refreshInterval == 30, "network refresh interval should protect idle CPU")
        expect(plugin.sharedFeeds == [.fastStats], "it reads the 1-second feed for its rates and graph")
        expect(NetworkCollector.negativeHostnameCacheTTL == 60, "a failed reverse lookup is retried after a minute")
    }
}
SWIFT
} > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Tests/NetworkTests.swift
```

Then take the block out of the performance tests (with the blank line after it), and remove the last of the sampling-plan test:

```bash
sed -i '' -e "${A},$((B-1))d" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
```

In `SystemBarPerformanceTests.swift`:

- In `main()`, delete `testSamplingPlan()` and replace the seven lines `testHostnameCacheEntryExpiry()` … `testParseNetworkQualitySummary()` with `MainActor.assumeIsolated { NetworkTests.runAll() }`.
- Delete `private static func testSamplingPlan() { ... }`. What it checked now lives in each plugin's identity and interval tests, and in the `HostSamplers` tests.

```bash
grep -n "MonitorSamplingPlan\|UnifiedMonitor\|runAll" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarPerformanceTests.swift
```

Expected: only `runAll()` lines — Power, Disk, Capacity, DevPlugin, Memory, CPU, Network, Config, Loader, Scheduler.

Rewrite the loader tests that used the built-in table, in `SystemBarLoaderTests.swift`:

- In `runAll()`: rename `testLoaderWritesTheDefaultAndLoadsWhatTheSourceKnowsOnFirstRun()` to `testLoaderWritesTheDefaultListAndResolvesEveryEntryOnFirstRun()`; rename `testEveryCompiledInTabIsInTheDefaultList()` to `testDefaultListNamesSixBundles()`; delete `testBuiltinsHaveDistinctIdentifiersAndMatchTheirMonitorMode()`, `testBuiltinSourceNamesTheUnknownTab()`, `testBuiltinSourceDoesNotTakePaths()` and `testHostSourcePrefersABundleOverTheCompiledInTab()`.
- Replace the first-run test with:

```swift
    private static func testLoaderWritesTheDefaultListAndResolvesEveryEntryOnFirstRun() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PluginConfigStore(fileURL: directory.appendingPathComponent("plugins.json"))
        let source = MapTabSource(types: ["Power.bundle": FakeTab.self, "CPU.bundle": OtherFakeTab.self])
        let loaded = TabLoader.load(store: store, source: source, host: makeHost())
        expect(loaded.map(\.title) == ["Fake", "Error", "Error", "Error", "Error", "Other"],
               "a fresh file lists all six defaults in order, each resolved through the source: the two it knows load and the four it does not are error tabs in their places, got \(loaded.map(\.title))")
        if case let .failed(location, _)? = loaded.dropFirst().first {
            expect(location == "Dev.bundle", "an error tab names its entry, got \(location)")
        }
        expect(FileManager.default.fileExists(atPath: store.fileURL.path), "and the default file is written")
        if case .success(let written) = store.loadOrCreate(default: PluginConfig(plugins: [])) {
            expect(written == .builtins(named: DefaultPlugins.names), "the file written is the default list, got \(written)")
        } else {
            expect(false, "the file written must read back")
        }
    }
```

- In `testLoaderTurnsAnUnparseableFileIntoOneErrorTab` and `testLoaderReportsNothingForAnEmptyList`, change `source: BuiltinTabSource()` to `source: MapTabSource(types: [:])`. Neither depends on what the source knows.
- Change `// MARK: - Built-in tabs` to `// MARK: - Default list`, and replace `testEveryCompiledInTabIsInTheDefaultList` with:

```swift
    private static func testDefaultListNamesSixBundles() {
        expect(DefaultPlugins.names.count == 6 && Set(DefaultPlugins.names).count == 6, "six distinct default names")
        expect(DefaultPlugins.names.allSatisfy { $0.hasSuffix(".bundle") }, "every default is a bundle in the app's PlugIns")
    }
```

- Delete the four functions whose calls you removed from `runAll()`.
- Fix the doc comment at the top of the struct: "the compiled-in tabs" becomes "the default list".

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `build-plugin.sh: no Info.plist at Plugins/Network//Info.plist`.

- [ ] **Step 3: `Info.plist` and `NetworkModels.swift`**

```bash
sed -e 's/<string>Power<\/string>/<string>Network<\/string>/g' -e 's/systembar\.power/systembar.network/' -e 's/SystemBarPowerPlugin/SystemBarNetworkPlugin/' /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Power/Info.plist > /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Info.plist
for key in CFBundleExecutable CFBundleName CFBundleIdentifier NSPrincipalClass; do /usr/libexec/PlistBuddy -c "Print :$key" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Info.plist; done
```

Expected: `Network`, `Network`, `com.ih8celery.systembar.network`, `SystemBarNetworkPlugin`.

`Plugins/Network/Sources/NetworkModels.swift`:

```swift
import Foundation
import SystemBarKit

// Move these from Sources/Host/Models.swift unchanged: `struct NetworkProcessSnapshot`
// (original lines 155–164), `struct NetworkDestination` (166–172), `struct HostnameCacheEntry`
// (174–177), `struct NetworkSummary` (356–383), `struct SpeedTestResult` (385–393) and
// `struct TCPConnection` (423–433).

/// How often the Network tab samples.
enum NetworkSampling {
    /// nettop alone takes about a second by design, so this stays far from the 1-second feed.
    static let refreshInterval: TimeInterval = 30
}

/// What one nettop and lsof sample found.
struct NetworkReading {
    let processes: [NetworkProcessSnapshot]
    let destinations: [NetworkDestination]
    let status: String
    let health: SampleHealth
}

extension NetworkSummary {
    /// A copy showing a new sample. Hostnames already resolved are kept: lookups outlive samples.
    func applying(_ reading: NetworkReading) -> NetworkSummary {
        NetworkSummary(
            processes: reading.processes,
            destinations: reading.destinations,
            resolvedHostnames: resolvedHostnames,
            status: reading.status,
            health: reading.health
        )
    }

    /// A copy with one finished reverse lookup recorded by address.
    func resolving(_ address: String, to hostname: String) -> NetworkSummary {
        var next = self
        next.resolvedHostnames[address] = hostname
        return next
    }
}

/// One networkQuality run: a result, or the one-line reason there is none.
struct SpeedTestOutcome {
    let result: SpeedTestResult?
    let failure: String
}

/// The speed test as the panel shows it.
struct SpeedTestState {
    var isRunning = false
    var status = "Ready"
    var health = SampleHealth.ok
    var result: SpeedTestResult?

    func started() -> SpeedTestState {
        var next = self
        next.isRunning = true
        next.status = "Testing"
        next.health = .ok
        return next
    }

    /// A failed run says why and keeps the last good result on screen.
    func finished(with outcome: SpeedTestOutcome) -> SpeedTestState {
        var next = self
        next.isRunning = false
        if let result = outcome.result {
            next.result = result
            next.status = "Last run \(SpeedTest.shortTimeString(result.measuredAt))"
            next.health = .ok
        } else {
            next.status = outcome.failure
            next.health = .degraded
        }
        return next
    }
}
```

- [ ] **Step 4: `NetworkCollector.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+Network.swift Plugins/Network/Sources/NetworkCollector.swift
```

Replace lines 1–84 (the imports, `extension UnifiedMonitor {`, `collectNetwork`, `resolveHostnames`, `negativeHostnameCacheTTL`, `isHostnameCacheEntryValid` and `setResolvedHostname`) with the block below. `negativeHostnameCacheTTL` and `isHostnameCacheEntryValid` are old lines 69–78 unchanged; `setResolvedHostname` is gone because the plugin records a resolved name itself. Everything after old line 84 (`parseNettopCSV` through `networkStatus`) is unchanged, and the file's final `}` now closes the class.

```swift
import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemBarKit

/// The Network tab's sampler: nettop for per-process throughput and lsof for who is talking to
/// where, every 30 seconds on the plugin's queue; and reverse DNS for the destinations, on its
/// own queue. The hostname cache and the in-flight set are touched only on the main thread.
final class NetworkCollector: @unchecked Sendable {
    private let host: HostServices
    private let dnsQueue = DispatchQueue(label: "systembar.network.dns", qos: .utility)
    private var hostnameCache: [String: HostnameCacheEntry] = [:]
    private var hostnameLookupsInFlight = Set<String>()

    init(host: HostServices) {
        self.host = host
    }

    func sample() -> NetworkReading {
        let nettop = host.run(path: "/usr/bin/nettop", arguments: [
            "-d", "-P", "-L", "2", "-s", "1", "-x", "-n", "-J", "bytes_in,bytes_out"
        ])
        let lsof = host.run(path: "/usr/sbin/lsof", arguments: ["-n", "-P", "-iTCP"])
        let rows = Self.parseNettopCSV(nettop.output)
            .filter { $0.downloadRate > 0 || $0.uploadRate > 0 }
            .sorted {
                if $0.combinedRate == $1.combinedRate {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.combinedRate > $1.combinedRate
            }
        let connections = lsof.status == 0 ? Self.parseLsofTCP(lsof.output) : []
        let internet = connections.filter(\.isInternet)
        return NetworkReading(
            processes: rows,
            destinations: Self.summarizeDestinations(internet),
            status: Self.networkStatus(nettop: nettop, lsof: lsof),
            health: SampleHealth(isOK: nettop.status == 0 && lsof.status == 0)
        )
    }

    /// Main thread. Hands each destination's hostname to `resolved`, on the main thread: at once
    /// from the cache, or after a lookup on the DNS queue. An address already being looked up is
    /// not asked twice.
    func resolveHostnames(for destinations: [NetworkDestination], resolved: @escaping (String, String) -> Void) {
        let now = Date()
        for address in Set(destinations.map(\.remoteAddress)) {
            let normalized = Self.normalizedIPAddress(address)
            if let entry = hostnameCache[normalized], Self.isHostnameCacheEntryValid(entry, now: now, ttl: Self.negativeHostnameCacheTTL) {
                resolved(normalized, entry.hostname)
                continue
            }

            guard !hostnameLookupsInFlight.contains(normalized) else { continue }
            hostnameLookupsInFlight.insert(normalized)

            dnsQueue.async { [weak self] in
                let hostname = Self.reverseLookup(ipAddress: normalized)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hostnameLookupsInFlight.remove(normalized)
                    self.hostnameCache[normalized] = HostnameCacheEntry(hostname: hostname, cachedAt: Date())
                    resolved(normalized, hostname)
                }
            }
        }
    }

    /// Failed lookups (empty hostname) are a negative cache: DNS or network
    /// conditions can change, so a transient miss shouldn't pin a destination
    /// to its raw IP forever. Successful lookups don't expire — hostnames
    /// rarely change and re-querying them buys nothing.
    static let negativeHostnameCacheTTL: TimeInterval = 60

    static func isHostnameCacheEntryValid(_ entry: HostnameCacheEntry, now: Date, ttl: TimeInterval) -> Bool {
        guard entry.hostname.isEmpty else { return true }
        return now.timeIntervalSince(entry.cachedAt) < ttl
    }
```

- [ ] **Step 5: `SpeedTest.swift` and `NetworkFormatting.swift`**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/UnifiedMonitor+SpeedTest.swift Plugins/Network/Sources/SpeedTest.swift
```

Replace lines 1–42 (the imports, `extension UnifiedMonitor {` and `runSpeedTest`; line 43 is `private static func parseNetworkQualityOutput`) with the block below; the rest of the file (`parseNetworkQualityOutput` through `shortTimeString`) is unchanged except that `private static func shortTimeString` loses `private`, because `SpeedTestState` uses it. The final `}` now closes the enum. (The three `in:key:` helpers left in Task 5.)

```swift
import Foundation
import SystemBarKit

/// Apple's networkQuality, run only when the button is pressed, and what its output means.
enum SpeedTest {
    /// -M 20 caps the test itself at about 20 seconds; this leaves room to start up and report.
    static let timeout: TimeInterval = 30

    /// Blocks for up to `timeout`, so the plugin calls it on its speed-test queue.
    static func measure(using host: HostServices, startedAt: Date) -> SpeedTestOutcome {
        let output = host.run(path: "/usr/bin/networkQuality", arguments: ["-c", "-M", "20"], timeout: timeout)
        let finishedAt = Date()
        let parsed = output.status == 0 ? parseNetworkQualityOutput(
            output.output,
            measuredAt: finishedAt,
            duration: finishedAt.timeIntervalSince(startedAt)
        ) : nil
        return SpeedTestOutcome(result: parsed, failure: speedTestFailureMessage(output))
    }

```

`Plugins/Network/Sources/NetworkFormatting.swift` holds `speedTestRateText` and `speedTestLatencyText`, moved unchanged from `Sources/Host/Views/HostFormatting.swift` (originally lines 11–19):

```swift
import Foundation

/// The speed-test card's formatters. Only this panel uses them.

func speedTestRateText(_ megabitsPerSecond: Double?) -> String {
    guard let megabitsPerSecond else { return "-- Mbps" }
    return String(format: megabitsPerSecond >= 100 ? "%.0f Mbps" : "%.1f Mbps", max(0, megabitsPerSecond))
}

func speedTestLatencyText(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "-- ms" }
    return String(format: milliseconds >= 10 ? "%.0f ms" : "%.1f ms", max(0, milliseconds))
}
```

- [ ] **Step 6: `NetworkPlugin.swift`**

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

@objc(SystemBarNetworkPlugin)
public final class NetworkPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "network"
    public let title = "Network"
    public let systemImage = "arrow.up.arrow.down"
    public let accent = Palette.blue
    public let refreshInterval: TimeInterval = NetworkSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.fastStats]

    @Published private(set) var summary = NetworkSummary()
    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var speedTest = SpeedTestState()
    private let host: HostServices
    private let collector: NetworkCollector
    /// A speed test runs for up to 30 seconds, so it gets its own queue rather than holding up
    /// the plugin's collects.
    private let speedTestQueue = DispatchQueue(label: "systembar.network.speedtest", qos: .utility)
    private var feedSubscription: AnyCancellable?

    @MainActor public init(host: HostServices) {
        self.host = host
        collector = NetworkCollector(host: host)
        super.init()
        fastStats = host.fastStats.value
        feedSubscription = host.fastStats.publisher.sink { [weak self] snapshot in
            self?.fastStats = snapshot
        }
    }

    public func collect() {
        let reading = collector.sample()
        DispatchQueue.main.async { [weak self] in
            self?.show(reading)
        }
    }

    /// Main thread: the panel's button. Does nothing while a test is already running.
    func runSpeedTest() {
        guard !speedTest.isRunning else { return }
        speedTest = speedTest.started()
        let host = self.host
        let startedAt = Date()
        speedTestQueue.async { [weak self] in
            let outcome = SpeedTest.measure(using: host, startedAt: startedAt)
            DispatchQueue.main.async {
                guard let self else { return }
                self.speedTest = self.speedTest.finished(with: outcome)
            }
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(NetworkPanel(plugin: self))
    }

    /// Main thread: shows a sample, then asks for the names of its destinations.
    private func show(_ reading: NetworkReading) {
        summary = summary.applying(reading)
        collector.resolveHostnames(for: reading.destinations) { [weak self] address, hostname in
            guard let self else { return }
            self.summary = self.summary.resolving(address, to: hostname)
        }
    }
}
```

- [ ] **Step 7: `NetworkPanel.swift` observes the plugin**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 mv Sources/Host/Views/NetworkPanel.swift Plugins/Network/Sources/NetworkPanel.swift
sed -i '' \
  -e 's/@ObservedObject var monitor: UnifiedMonitor/@ObservedObject var plugin: NetworkPlugin/' \
  -e 's/monitor\.currentDownloadRate/plugin.fastStats.currentDownloadRate/g' \
  -e 's/monitor\.currentUploadRate/plugin.fastStats.currentUploadRate/g' \
  -e 's/monitor\.downloadHistory/plugin.fastStats.downloadHistory/g' \
  -e 's/monitor\.uploadHistory/plugin.fastStats.uploadHistory/g' \
  -e 's/monitor\.speedTestStatus/plugin.speedTest.status/g' \
  -e 's/monitor\.speedTestHealth/plugin.speedTest.health/g' \
  -e 's/monitor\.speedTestResult/plugin.speedTest.result/g' \
  -e 's/monitor\.isSpeedTestRunning/plugin.speedTest.isRunning/g' \
  -e 's/monitor\.runSpeedTest()/plugin.runSpeedTest()/g' \
  -e 's/monitor\.destinations/plugin.summary.destinations/g' \
  -e 's/monitor\.networkStatus/plugin.summary.status/g' \
  -e 's/monitor\.networkHealth/plugin.summary.health/g' \
  -e 's/monitor\.networkProcessCount/plugin.summary.totalProcessCount/g' \
  -e 's/monitor\.networkProcesses/plugin.summary.processes/g' \
  -e 's/monitor\.networkMaxCombinedRate/plugin.summary.maxCombinedRate/g' \
  -e 's/monitor\.resolvedHostnames/plugin.summary.resolvedHostnames/g' \
  -e 's/UnifiedMonitor\.serviceLabel/NetworkCollector.serviceLabel/g' \
  /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkPanel.swift
grep -n "monitor\|UnifiedMonitor" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins/Network/Sources/NetworkPanel.swift
```

Expected: no output.

- [ ] **Step 8: The host loads only bundles**

`Sources/Host/TabLoader.swift` — add, above `enum TabLoader`, `DefaultPlugins` moved from `BuiltinTabs.swift` lines 5–9 with its list unchanged and its comment brought up to date:

```swift
/// What a fresh plugins.json lists, in the tab order the app has always had. Each is a bundle in
/// the app's Contents/PlugIns. This is the default file's content, not a list the host treats
/// specially: a tab removed from plugins.json is gone, like any other.
enum DefaultPlugins {
    static let names = ["Power.bundle", "Dev.bundle", "Memory.bundle", "Disk.bundle", "Network.bundle", "CPU.bundle"]
}
```

`Sources/Host/App.swift`:

- `let source = HostTabSource(bundles: .standard(), builtins: BuiltinTabSource())` becomes `let source = BundleTabSource.standard()`.
- Delete `UnifiedMonitor.shared.follow(fastStats: fastStats)`.
- In `body`, delete the comment `// UnifiedMonitor.shared starts its timers when first created, so nothing else starts it.` and change the `RootView(...)` line to `RootView(tabs: tabs, configPath: configPath, scheduler: scheduler, samplers: samplers)`.

`Sources/Host/Views/RootView.swift`: delete the comment `// Not observed: the panels observe the monitor themselves; RootView only tells it what is visible.` and `let monitor: UnifiedMonitor`, and replace `present(index:isVisible:)` with:

```swift
    /// Tells the scheduler and the host samplers what the selected tab needs. An error tab or an
    /// empty list needs nothing.
    private func present(index: Int, isVisible: Bool) {
        let plugin = loadedPlugin(at: index)
        plugin?.visibilityChanged(isVisible: isVisible)
        if isVisible, let plugin {
            scheduler.show(plugin)
        } else {
            scheduler.hide()
        }
        samplers.update(isVisible: isVisible && plugin != nil, feeds: plugin?.sharedFeeds ?? [])
    }
```

Move out the last models, then delete what is left:

- Cut the six network structs named in Step 3 from `Sources/Host/Models.swift` into `NetworkModels.swift`, and the two speed-test formatters from `Sources/Host/Views/HostFormatting.swift` into `NetworkFormatting.swift`.
- Check what remains in `Models.swift`: `grep -n "^struct\|^enum\|^final class" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Models.swift` should print exactly `enum MonitorMode`, `enum MonitorJob` and `struct MonitorSamplingPlan`. Check `HostFormatting.swift` holds only its imports and header comment.

`Models.swift` and `HostFormatting.swift` carry unstaged edits from the cuts above, and `git rm` refuses those without `-f`; the content that mattered has already moved, so they take `-f` and the rest do not:

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 rm -q Sources/Host/UnifiedMonitor.swift Sources/Host/UnifiedMonitor+ProcessRunner.swift Sources/Host/BuiltinTabs.swift Sources/Host/HostTabSource.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 rm -q -f Sources/Host/Models.swift Sources/Host/Views/HostFormatting.swift
grep -rn "UnifiedMonitor\|MonitorMode\|MonitorSamplingPlan\|MonitorBackedTab\|BuiltinTabSource\|HostTabSource" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins /Users/adamu/proj/swift-ui-system-monitor-2ik.3/*.swift /Users/adamu/proj/swift-ui-system-monitor-2ik.3/*.sh
```

Expected: no output.

- [ ] **Step 9: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`.

- [ ] **Step 10: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Plugins/Network/Info.plist Plugins/Network/Sources/NetworkModels.swift Plugins/Network/Sources/NetworkFormatting.swift Plugins/Network/Sources/NetworkPlugin.swift Plugins/Network/Tests/NetworkTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Move the Network tab into its own bundle and delete UnifiedMonitor" -m "Network was the last tab compiled into the app, so the machinery that keyed
sampling by tab goes with it: UnifiedMonitor, MonitorMode, MonitorJob,
MonitorSamplingPlan, the built-in table and the source that fell back to it.
The app now loads every tab through BundleTabSource, and the loader tests use
MapTabSource.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Plugins/Network Sources/Host/UnifiedMonitor+Network.swift Sources/Host/UnifiedMonitor+SpeedTest.swift Sources/Host/Views/NetworkPanel.swift Sources/Host/UnifiedMonitor.swift Sources/Host/UnifiedMonitor+ProcessRunner.swift Sources/Host/Models.swift Sources/Host/BuiltinTabs.swift Sources/Host/HostTabSource.swift Sources/Host/Views/HostFormatting.swift Sources/Host/TabLoader.swift Sources/Host/App.swift Sources/Host/Views/RootView.swift SystemBarPerformanceTests.swift SystemBarLoaderTests.swift
```

---

## Task 8: `TabPresenter`, the fresh-file check, and the name check

`RootView` still decides what the scheduler and the samplers hear. This task moves that into `TabPresenter`, the one place that tells the tab, the scheduler and the samplers what is showing, and tests the rules issue 2ik.4 asks for: a closed window runs nothing, and a tab switch runs only the new tab's samplers. Then `test.sh` checks that a fresh `plugins.json` loads all six tabs from the app's bundles, and a grep checks that nothing in `Sources/Host` names a tab.

**Files:**
- Create: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/TabPresenter.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Views/RootView.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/App.swift`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh`
- Test: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarSchedulerTests.swift`

- [ ] **Step 1: Write the failing presenter tests**

In `SystemBarSchedulerTests.swift`, change the doc comment above the struct to end "…calls its collect(), the host's two shared samplers, and the presenter that tells them what is showing." Add to the end of `runAll()`:

```swift
        testPresenterRunsNothingWhileTheWindowIsClosed()
        testPresenterSwitchRunsOnlyTheShownTabsSamplers()
        testPresenterPausesEverythingForAnErrorTab()
        testPresenterStopsEverythingWhenTheWindowCloses()
```

Add inside the struct, after the sampler tests:

```swift
    // MARK: - Presenter

    /// A presenter over a fast scheduler and fast samplers, whose collectors count their calls.
    private static func makeTestPresenter(fast: CallCounter, processes: CallCounter) -> (TabPresenter, HostSamplers) {
        let samplers = makeTestSamplers(fast: fast, processes: processes)
        return (TabPresenter(scheduler: makeTestScheduler(), samplers: samplers), samplers)
    }

    private static func testPresenterRunsNothingWhileTheWindowIsClosed() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes, .fastStats])
        presenter.present(plugin: tab, isVisible: false)
        spinRunLoop(for: 0.2)
        expect(tab.count == 0 && fast.count == 0 && processes.count == 0,
               "a closed window collects nothing and samples nothing, got collect \(tab.count) fast \(fast.count) processes \(processes.count)")
        expect(samplers.running.isEmpty, "and no sampler is left running, got \(samplers.running)")
        expect(tab.visibility == [false], "the tab is told it is hidden, got \(tab.visibility)")
    }

    private static func testPresenterSwitchRunsOnlyTheShownTabsSamplers() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let first = DeclaringTab(feeds: [.processes])
        let second = DeclaringTab(feeds: [])

        presenter.present(plugin: first, isVisible: true)
        waitUntil { first.count >= 1 && processes.count >= 1 }
        expect(samplers.running == [.fastStats, .processes], "a tab that declares the process feed gets both samplers, got \(samplers.running)")

        presenter.switching(from: first, to: second)
        expect(samplers.running == [.fastStats], "switching to a tab that declares nothing stops ps and keeps the 1-second sampler, got \(samplers.running)")
        expect(first.visibility == [true, false] && second.visibility == [true], "each tab is told when it is shown and hidden, got \(first.visibility) and \(second.visibility)")
        waitUntil { second.count >= 1 }
        spinRunLoop(for: 0.1)
        let firstAfter = first.count
        let processesAfter = processes.count
        spinRunLoop(for: 0.2)
        expect(first.count == firstAfter, "the tab switched away from is no longer collected, got \(first.count - firstAfter) more")
        expect(processes.count == processesAfter, "and ps no longer runs, got \(processes.count - processesAfter) more")
        expect(second.count >= 2, "the shown tab is collected on its interval, got \(second.count)")
        presenter.present(plugin: second, isVisible: false)
    }

    private static func testPresenterPausesEverythingForAnErrorTab() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes])
        presenter.present(plugin: tab, isVisible: true)
        waitUntil { tab.count >= 1 }

        presenter.switching(from: tab, to: nil)
        expect(samplers.running.isEmpty, "an error tab has nothing to feed, so no sampler runs, got \(samplers.running)")
        spinRunLoop(for: 0.1)
        let collected = tab.count
        spinRunLoop(for: 0.2)
        expect(tab.count == collected, "and the tab switched away from stops, got \(tab.count - collected) more")
        expect(tab.visibility == [true, false], "it is told it is hidden, got \(tab.visibility)")
    }

    private static func testPresenterStopsEverythingWhenTheWindowCloses() {
        let fast = CallCounter()
        let processes = CallCounter()
        let (presenter, samplers) = makeTestPresenter(fast: fast, processes: processes)
        let tab = DeclaringTab(feeds: [.processes])
        presenter.present(plugin: tab, isVisible: true)
        waitUntil { tab.count >= 1 && fast.count >= 1 && processes.count >= 1 }

        presenter.present(plugin: tab, isVisible: false)
        expect(samplers.running.isEmpty, "closing the window stops both samplers, got \(samplers.running)")
        spinRunLoop(for: 0.1)
        let counts = (tab.count, fast.count, processes.count)
        spinRunLoop(for: 0.2)
        expect((tab.count, fast.count, processes.count) == counts, "and nothing runs after it closes, got \((tab.count, fast.count, processes.count)) after \(counts)")
    }
```

Append to the end of the file, after `CallCounter`:

```swift
/// A tab that declares whatever feeds a test gives it, counts its collects, and records each
/// visibility change it is told about, in order.
final class DeclaringTab: TabPlugin {
    static let identifier = "declaring"
    let title = "Declaring"
    let systemImage = "list.bullet"
    let accent = Color.gray
    let refreshInterval: TimeInterval = 0.05
    let sharedFeeds: Set<SharedFeed>
    private let lock = NSLock()
    private var collects = 0
    /// Main thread only: the presenter calls visibilityChanged there.
    private(set) var visibility: [Bool] = []

    init(host: HostServices) {
        sharedFeeds = []
    }

    init(feeds: Set<SharedFeed>) {
        sharedFeeds = feeds
    }

    func collect() {
        lock.withLock { collects += 1 }
    }

    func visibilityChanged(isVisible: Bool) {
        visibility = visibility + [isVisible]
    }

    var count: Int { lock.withLock { collects } }
    @MainActor func makeView() -> AnyView { AnyView(Text("declaring")) }
}
```

- [ ] **Step 2: Run the tests and see them fail**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `error: cannot find 'TabPresenter' in scope`.

- [ ] **Step 3: `TabPresenter.swift`**

```swift
import Foundation
import SystemBarKit

/// The one place that says what is showing. The window opening or closing, and the selection
/// moving, come here; the presenter tells the tab, the scheduler that collects it, and the host's
/// shared samplers. A nil plugin is an error tab or an empty list: it has nothing to collect and
/// nothing to feed, so everything pauses while it is showing.
@MainActor
final class TabPresenter {
    private let scheduler: PluginScheduler
    private let samplers: HostSamplers

    init(scheduler: PluginScheduler, samplers: HostSamplers) {
        self.scheduler = scheduler
        self.samplers = samplers
    }

    /// The window opened (or closed) on `plugin`.
    func present(plugin: TabPlugin?, isVisible: Bool) {
        plugin?.visibilityChanged(isVisible: isVisible)
        if isVisible, let plugin {
            scheduler.show(plugin)
        } else {
            scheduler.hide()
        }
        samplers.update(isVisible: isVisible && plugin != nil, feeds: plugin?.sharedFeeds ?? [])
    }

    /// The selection moved while the window is open. The old tab is told first, so it never
    /// sees the new one shown while it still thinks it is visible.
    func switching(from previous: TabPlugin?, to next: TabPlugin?) {
        previous?.visibilityChanged(isVisible: false)
        present(plugin: next, isVisible: true)
    }
}
```

- [ ] **Step 4: `RootView` and `App` hand the decision to the presenter**

`Sources/Host/Views/RootView.swift`:

- Replace `let scheduler: PluginScheduler` and `let samplers: HostSamplers` with `let presenter: TabPresenter`.
- Replace the three modifiers `.onAppear`, `.onDisappear` and `.onChange(of: selection)` with:

```swift
        .onAppear {
            presenter.present(plugin: loadedPlugin(at: selection), isVisible: true)
        }
        .onDisappear {
            presenter.present(plugin: loadedPlugin(at: selection), isVisible: false)
        }
        .onChange(of: selection) { previous, current in
            presenter.switching(from: loadedPlugin(at: previous), to: loadedPlugin(at: current))
        }
```

- Delete `present(index:isVisible:)` and its doc comment.

`Sources/Host/App.swift`:

- Replace `private let scheduler = PluginScheduler()` and `private let samplers: HostSamplers` with `private let presenter: TabPresenter`.
- Replace `samplers = HostSamplers.standard(processes: processes, fastStats: fastStats)` with:

```swift
        presenter = TabPresenter(
            scheduler: PluginScheduler(),
            samplers: HostSamplers.standard(processes: processes, fastStats: fastStats)
        )
```

- Change the `RootView(...)` line to `RootView(tabs: tabs, configPath: configPath, presenter: presenter)`.

```bash
grep -rn "scheduler\.\|samplers\.\|func present(index" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/Views /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host/App.swift
```

Expected: no output.

- [ ] **Step 5: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed` and `Boundary check passed: ...`. Then `wc -l /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBarSchedulerTests.swift` must be under 800; if it is not, move the `// MARK: - Presenter` section and `DeclaringTab` into a new `SystemBarPresenterTests.swift` (`@MainActor enum SystemBarPresenterTests`, with its own copies of the two `make…` helpers), add it to `test.sh`'s file list, and call its `runAll()` from `SystemBarPerformanceTests.main()`.

- [ ] **Step 6: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 add Sources/Host/TabPresenter.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Tell the tab, scheduler and samplers what is showing from one place" -m "TabPresenter takes the window opening and closing and the selection
moving, and is tested for the rules that matter: a closed window runs
nothing, a switch runs only the shown tab's samplers, and an error tab
pauses everything. RootView only forwards the events.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- Sources/Host/TabPresenter.swift Sources/Host/Views/RootView.swift Sources/Host/App.swift SystemBarSchedulerTests.swift
```

(Add `SystemBarPresenterTests.swift`, `SystemBarPerformanceTests.swift` and `test.sh` to the `git add` and the path list if Step 5 split the file.)

- [ ] **Step 7: See the fresh-file check catch a missing bundle before adding it**

The tests just built `SystemBar.app`. Take one bundle out of it and ask the real loader for a fresh file:

```bash
mkdir -p /private/tmp/claude-501/-Users-adamu-proj-swift-ui-system-monitor/88e0f481-5838-408f-b57f-6274a87f4a43/scratchpad/fresh-check
mv -f /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBar.app/Contents/PlugIns/Dev.bundle /private/tmp/claude-501/-Users-adamu-proj-swift-ui-system-monitor/88e0f481-5838-408f-b57f-6274a87f4a43/scratchpad/fresh-check/Dev.bundle
SYSTEMBAR_PLUGINS_FILE=/private/tmp/claude-501/-Users-adamu-proj-swift-ui-system-monitor/88e0f481-5838-408f-b57f-6274a87f4a43/scratchpad/fresh-check/new/plugins.json /Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBar.app/Contents/MacOS/SystemBar --list-plugins
```

Expected: six lines, the second starting `error Dev.bundle:`. That is the failure the check below exists to catch. The next `test.sh` run rebuilds the app, so `Dev.bundle` comes back; remove the scratch copy with `rm -rf /private/tmp/claude-501/-Users-adamu-proj-swift-ui-system-monitor/88e0f481-5838-408f-b57f-6274a87f4a43/scratchpad/fresh-check`.

- [ ] **Step 8: Add the fresh-file check to `test.sh`**

Append to the end of `test.sh`, after the existing `echo "Boundary check passed: …"`:

```zsh
# A new user's first launch: no plugins.json yet. The app writes the default list, and every
# entry in it loads from a bundle inside the app, in the order a new user sees.
expected_fresh="ok power Power Power.bundle
ok dev Dev Dev.bundle
ok memory Memory Memory.bundle
ok disk Disk Disk.bundle
ok network Network Network.bundle
ok cpu CPU CPU.bundle"
actual_fresh=$(SYSTEMBAR_PLUGINS_FILE="$tmp/fresh/plugins.json" ./SystemBar.app/Contents/MacOS/SystemBar --list-plugins) \
  || { echo "Fresh-file check failed: SystemBar --list-plugins exited $?" >&2; exit 1; }

if [[ "$actual_fresh" != "$expected_fresh" ]]; then
  echo "Fresh-file check failed. Expected:" >&2
  echo "$expected_fresh" >&2
  echo "Got:" >&2
  echo "$actual_fresh" >&2
  exit 1
fi
if [[ ! -f "$tmp/fresh/plugins.json" ]]; then
  echo "Fresh-file check failed: no plugins.json was written at $tmp/fresh/plugins.json" >&2
  exit 1
fi
echo "Fresh-file check passed: a new plugins.json loads all six tabs from the app's bundles"
```

`$tmp` is the folder the boundary check already made and its `trap` already removes, so the real `~/Library/Application Support/SystemBar/` is never touched.

- [ ] **Step 9: Run the tests and see both checks pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed`, `Boundary check passed: ...` and `Fresh-file check passed: a new plugins.json loads all six tabs from the app's bundles`.

- [ ] **Step 10: Check that nothing in the host names a tab**

```bash
grep -rn "UnifiedMonitor\|MonitorMode\|MonitorSamplingPlan\|MonitorBackedTab\|BuiltinTabSource\|HostTabSource" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Plugins /Users/adamu/proj/swift-ui-system-monitor-2ik.3/*.swift /Users/adamu/proj/swift-ui-system-monitor-2ik.3/*.sh
grep -rnE "(CPU|Memory|Disk|Network|Dev|Power)(Plugin|Panel|Tab|Collector|Sampling)[^a-zA-Z]|\"(cpu|memory|disk|network|dev|power)\"" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/Sources/Host | grep -v 'Image(systemName: "power")'
```

Expected: no output from either. The one list of names left in `Sources/Host` is `DefaultPlugins.names` in `TabLoader.swift` (`"Power.bundle"` and so on), which is the default file's content and does not match. The second grep filters out `RootView`'s `Image(systemName: "power")`, which is the Quit button's icon, not the Power tab. If the second grep finds a comment naming a tab, reword the comment; if it finds code, that code belongs in the plugin.

- [ ] **Step 11: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Check that a fresh plugins.json loads all six tabs from the app's bundles" -m "test.sh now also runs --list-plugins against a file that does not exist
yet, as on a new user's first launch, and expects the six default tabs,
each loaded from Contents/PlugIns, in order.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- test.sh
```

(Include any comment rewordings from Step 10 in this commit's path list.)

---

## Task 9: Documentation and the Decision Log

**Files:**
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/README.md`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/AGENTS.md`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/CLAUDE.md`
- Modify: `/Users/adamu/proj/swift-ui-system-monitor-2ik.3/docs/one-page/systembar-tab-plugins.md`

No code changes, so no failing test; the test run at the end checks nothing broke.

- [ ] **Step 1: README**

In `## Writing a plugin`, replace the sentence "The six built-in tabs are being moved to the same shape; `Plugins/Power/` is the first." with:

```markdown
Every tab the app ships is built this way, under `Plugins/`: `Plugins/Power/` is the smallest, and `Plugins/Network/` shows following the 1-second feed and running slow work on a queue of its own.

A plugin says in `sharedFeeds` which of the host's two shared readings it uses, and the host samples only what the showing tab asks for:

| Feed | What it holds | When the host samples it |
|---|---|---|
| `.fastStats` | CPU percent and network rates, with 90 seconds of history | Every second while the window is open, whatever the tab, so the history has no gaps |
| `.processes` | The top processes by CPU and by memory | Every 10 seconds, only while a tab that declares it is showing |

Nothing is sampled while the window is closed.
```

In `## What SystemBar reads from your system`, add this sentence directly above the command table: "Every command below runs only while the window is open, and only while the tab that needs it is showing." In the table, change the `/bin/ps` row's "How often" cell to: "Every 10s while the Power, Memory or CPU tab is showing; also every 60s for the Dev tab, with arguments, to work out which project each process belongs to".

Add a short section `### How often each tab samples` at the end of `## What SystemBar reads from your system`, before `## Test`:

```markdown
### How often each tab samples

Each interval lives in that tab's plugin, next to the code that uses it.

| Tab | Its own sampling | Where the number lives |
|---|---|---|
| Power | `pmset` every 60s | `PowerPlugin.refreshInterval` |
| Dev | `ps`, `lsof` and two usage reads a second apart, every 60s | `DevSampling` in `Plugins/Dev/Sources/CapacityModels.swift` |
| Memory | Kernel counters every 3s; `memory_pressure` and `ioreg` every 30s | `MemorySampling` in `Plugins/Memory/Sources/MemoryModels.swift` |
| Disk | Volumes and `tmutil` every 30s; the `du` scan every 10 min or on demand | `DiskSampling` in `Plugins/Disk/Sources/DiskModels.swift` |
| Network | `nettop` and `lsof` every 30s; `networkQuality` only on the button | `NetworkSampling` in `Plugins/Network/Sources/NetworkModels.swift` |
| CPU | Nothing of its own: everything it shows comes from the two shared feeds | `CPUPlugin.refreshInterval` (one day, so its empty collect almost never runs) |

The shared feeds' intervals are `HostSamplers.fastInterval` and `HostSamplers.processInterval` in `Sources/Host/HostSamplers.swift`.
```

In `## Test`, after the paragraph about the boundary check, add: "It then runs `--list-plugins` once more against a `plugins.json` that does not exist yet, as on a new user's first launch, and expects all six tabs to load from the bundles inside the app, in the default order."

- [ ] **Step 2: AGENTS.md and CLAUDE.md**

The two files are identical apart from the title line; make each change in both.

Replace the two `## Architecture Overview` paragraphs with:

```markdown
SystemBar is a SwiftUI menu bar app: one `MenuBarExtra` icon, and a popover whose tabs are all plugins. `Sources/Kit/` is the SDK: the `TabPlugin` contract, `HostServices` with its `processes` and `fastStats` feeds, `ProcessRunner`, `ProcessTable`, the shared models and the shared views (including `ProcessList`), all public and built as a dylib whose `.swiftinterface` ships in the app. `Sources/Host/` is the app: it reads `~/Library/Application Support/SystemBar/plugins.json` (writing `DefaultPlugins.names` on first run), resolves each entry to a bundle in `Contents/PlugIns/` or at a path, constructs it after the duplicate-id check, and keeps an error tab in the place of an entry that fails. `TabPresenter` is the one place that hears what is showing; it tells the tab, `PluginScheduler` (which runs the tab's `collect()` on its own queue while visible) and `HostSamplers` (the 1-second CPU and network sampler, run whenever the window is open, and the 10-second `ps` sampler, run only while the showing tab declares `.processes`). `RootView` renders the loaded list and never names a tab.

Every tab lives in `Plugins/<Name>/` with its `Info.plist`, `Sources/` and `Tests/`: Power, Dev, Memory, Disk, Network and CPU. Nothing in `Sources/Host/` names one; `test.sh` checks that a fresh `plugins.json` loads all six from the app's bundles.
```

In `## Conventions & Patterns`:

- In the subprocess paragraph, change "(plugins reach it as `HostServices.run`; `UnifiedMonitor.runProcess` is a thin forwarder that goes away with the class)" to "(plugins reach it as `HostServices.run`)".
- Replace the sampling-interval paragraph with: "A tab's sampling intervals live in its plugin: `refreshInterval`, and any slower cadences in its `<Name>Sampling` enum next to its models. The shared feeds' intervals are `HostSamplers.fastInterval` and `HostSamplers.processInterval`. The README documents all of them, so changing one means updating both."
- Add a sentence to the end of the SDK paragraph: "Bundles cannot share code except through the SDK, so something two plugins both need either joins the SDK (as `ProcessTable` and `ProcessList` did) or, when it is a line or two, is copied."

```bash
diff /Users/adamu/proj/swift-ui-system-monitor-2ik.3/AGENTS.md /Users/adamu/proj/swift-ui-system-monitor-2ik.3/CLAUDE.md
grep -n "UnifiedMonitor\|MonitorSamplingPlan\|BuiltinTabs\|compiled in\|compiled-in" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/README.md /Users/adamu/proj/swift-ui-system-monitor-2ik.3/AGENTS.md /Users/adamu/proj/swift-ui-system-monitor-2ik.3/CLAUDE.md
```

Expected: the diff shows only the title line; the grep prints nothing.

- [ ] **Step 3: The spec**

In `docs/one-page/systembar-tab-plugins.md`, find every present-tense mention of the compiled-in tabs:

```bash
grep -n "UnifiedMonitor\|MonitorSamplingPlan\|MonitorMode\|BuiltinTabs\|compiled in\|compiled-in\|HostTabSource" /Users/adamu/proj/swift-ui-system-monitor-2ik.3/docs/one-page/systembar-tab-plugins.md
```

Leave the Decision Log and the D-sections as the record of what was decided and when. Anywhere the contracts (Plugin, Loading, Build, Test) describe the current code, bring it up to date: the loader resolves only bundles, the host runs the two shared samplers described in Step 2, `ProcessTable` and `ProcessList` are part of the SDK, and the Test Contract includes the fresh-file check.

Append these to the end of `## Decision Log`, in its existing format:

```markdown
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
```

- [ ] **Step 4: Run the tests and see them pass**

```bash
mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor-2ik.3 -- /Users/adamu/proj/swift-ui-system-monitor-2ik.3/test.sh 2>&1 | tail -15
```

Expected: `SystemBarPerformanceTests passed`, `Boundary check passed: ...`, `Fresh-file check passed: ...`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 commit -m "Document the six plugin tabs, the shared samplers and Stage 3's decisions" -m "The README says which shared feed is sampled when and where each tab's
intervals live; AGENTS.md and CLAUDE.md describe the host with no tab
compiled in; the spec's contracts match the code and its Decision Log
records what Stage 3 decided.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- README.md AGENTS.md CLAUDE.md docs/one-page/systembar-tab-plugins.md
```

---

## Done when

- `./test.sh` passes: the in-process tests (every moved test in its new file, and the new sampler, presenter and plugin tests), the boundary check, and the fresh-file check that loads all six tabs from `Contents/PlugIns/`.
- `grep -rn "UnifiedMonitor\|MonitorMode\|MonitorSamplingPlan\|MonitorBackedTab" Sources Plugins *.swift *.sh` prints nothing, and nothing in `Sources/Host/` names a tab (Task 8, Step 10).
- A closed window runs no sampler at all, and switching tabs runs only the shown tab's `collect()` and the samplers it declares, plus the 1-second sampler: the presenter tests prove both.
- Every tab looks and behaves as it did at the start of Stage 3 when opened in the popover (checked in Phase 5 below).
- README, AGENTS.md, CLAUDE.md and the spec describe the plugin-only host; issues 2ik.3 and 2ik.4 are closed.

## Closing checklist (the coordinator runs this, not a task implementer)

- [ ] **1. Final whole-branch review.** Dispatch a code reviewer over `git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 diff capacity-ledger...HEAD`, against this plan's Goal and "Done when". Fix anything CRITICAL or HIGH in a follow-up commit, with the test run above green.
- [ ] **2. Phase 5 verification.** Build and run the app from the worktree (`/Users/adamu/proj/swift-ui-system-monitor-2ik.3/SystemBar.app`), and open each of the six tabs in the popover: Power, Dev, Memory, Disk, Network, CPU. Each shows live data as it did before; the CPU and network graphs keep their history across a tab switch; the speed test runs; Disk's rescan runs; CPU's drill-in opens. Then close the popover and confirm in Activity Monitor that no `ps`, `nettop`, `lsof` or `du` starts for a minute. Record what was seen, and anything not looked at, in the Stage 3 Decision Log entry.
- [ ] **3. Rebase and fast-forward.**

  ```bash
  git -C /Users/adamu/proj/swift-ui-system-monitor-2ik.3 rebase capacity-ledger
  git -C /Users/adamu/proj/swift-ui-system-monitor merge --ff-only swift-ui-system-monitor-2ik.3
  ```

- [ ] **4. Tests on the merged branch.**

  ```bash
  mc run --action=swift-test --lease=mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --project=/Users/adamu/proj/swift-ui-system-monitor -- /Users/adamu/proj/swift-ui-system-monitor/test.sh 2>&1 | tail -15
  ```

  Expected: `SystemBarPerformanceTests passed`, `Boundary check passed: ...`, `Fresh-file check passed: ...`.
- [ ] **5. Remove the worktree.**

  ```bash
  git -C /Users/adamu/proj/swift-ui-system-monitor worktree remove /Users/adamu/proj/swift-ui-system-monitor-2ik.3
  git -C /Users/adamu/proj/swift-ui-system-monitor branch -d swift-ui-system-monitor-2ik.3
  ```

- [ ] **6. Release the lease.** `mc resource release mc-xcode-build-2 --issue=swift-ui-system-monitor-2ik.3 --reason=done`
- [ ] **7. Close the issues.**

  ```bash
  bd close swift-ui-system-monitor-2ik.3 --reason="Stage 3 landed: every tab is a bundle under Plugins/, UnifiedMonitor is deleted, the host keeps two shared samplers, and test.sh checks a fresh plugins.json loads all six"
  bd close swift-ui-system-monitor-2ik.4 --reason="TabPresenter owns what is showing; its tests prove a closed window runs nothing and a tab switch runs only the shown tab's samplers"
  ```

- [ ] **8. Breadcrumb.** `bd update swift-ui-system-monitor-2ik --append-notes="Stage 3 merged into capacity-ledger: <first>..<last> commit ids; Phase 5 result; any follow-up issue ids"`.
- [ ] **9. Cost.** `python3 /private/tmp/claude-501/-Users-adamu-proj-swift-ui-system-monitor/88e0f481-5838-408f-b57f-6274a87f4a43/scratchpad/cost.py swift-ui-system-monitor-2ik.3`, and put the figure in the recap. Then `bd ready` to see what Stage 3 unblocked.
- [ ] **10. Recap for Adam.** Outcome first: what moved, what was deleted, what the tests now prove, what Phase 5 saw and did not see, the Decision Log entries marked "for Adam to confirm", and what `bd ready` shows next.
- [ ] **11.** `agent-status --state done`.
