# CPU Left Column Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under the CPU tab's headline and 90-second history, show what state the machine is in: one bar per core cluster named as sysctl names it, the user/system split, the 1-minute load average against the core count, and a thermal line that appears only when there is something to say. The right column (the top-process list) is untouched; Stage 3 replaces it.

**Architecture:** The host's 1-second feed (`FastStatsSnapshot`, in the SDK) gains three additive fields, `perCoreUsage`, `cpuUserPercent` and `cpuSystemPercent`, because `FastStatsSampler` already reads every core's ticks and only publishes the sum. The CPU plugin learns the chip's clusters from sysctl once at init (`hw.nperflevels`, `hw.perflevelN.name`, `hw.perflevelN.logicalcpu`) and lays them over the kernel's core indices with one rule, settled by the device tree on the development Mac: the kernel numbers cores slowest cluster first, while sysctl lists perflevels fastest first, so the last perflevel takes core 0 onward. Every ten seconds while showing, the plugin's `collect()` reads the load average and thermal state from the kernel and the throttling speed limit from `pmset -g therm` through the host, and publishes a `MachineState`. A new `MachineStateView` draws all of it from the feed and that state.

**Tech Stack:** Swift in `-swift-version 5` mode, `-target arm64-apple-macos14`, `swiftc` only, Foundation, Darwin (`sysctlbyname`, `getloadavg`, `host_processor_info`), SwiftUI, Combine. Tests are the one in-process binary `test.sh` builds; `expect(cond, msg)` exits on the first failure.

**Spec:** `docs/one-page/systembar-ewy-cpu-machine-state-and-background-sampling.md`, D1, D5, "CPU Tab Contract" (the layout block and the cluster paragraph), and the Issue Map's stage 2.

**Beads issue:** `swift-ui-system-monitor-ewy.2`. Claim it before Task 1 (`bd update swift-ui-system-monitor-ewy.2 --claim`), close it after Task 7.

**What the spike found (so no task needs to repeat it).** On the development Mac, `sysctl` says `hw.nperflevels` 2, `hw.perflevel0.name` Super with 6 logical cores, `hw.perflevel1.name` Performance with 12, `hw.ncpu` 18. The device tree (`ioreg -p IODeviceTree -r -c IOPlatformDevice`) gives every core's cluster: `cpu0` to `cpu11` are `cluster-type` M in two clusters, `cpu12` to `cpu17` are type P. So the six fastest cores (perflevel 0, Super) are indices 12 to 17 and the twelve Performance cores are 0 to 11. An M1 is the same shape: its four efficiency cores are 0 to 3 and its perflevel 0 is Performance. A spinning thread confirmed it: background QoS landed on cores 0 to 5, user-interactive QoS on 12 to 17. The rule in Task 3 encodes this; the fallback for a chip whose counts do not add up is one row of unnamed per-core bars.

**Rules for every task:**

- Work in a worktree, so the shared checkout at `/Users/adamu/proj/swift-ui-system-monitor` (which the Disk session also uses) is never edited:

  ```bash
  git -C /Users/adamu/proj/swift-ui-system-monitor worktree add /Users/adamu/proj/swift-ui-system-monitor-ewy.2 -b ewy.2-machine-state main
  ```

  Every command below spells the path out; `cd` does not persist between commands.
- Building and testing takes an `xcode-build` lease. Request it once before Task 1 and release it after Task 7:

  ```bash
  mc resource request xcode-build --issue=swift-ui-system-monitor-ewy.2 --reason="Stage 2 builds and tests"
  ```

  It prints a lease id; write it where `LEASE` appears below. Every test run is exactly this command, never piped into `head`:

  ```bash
  mc run --action=swift-test --lease=LEASE --issue=swift-ui-system-monitor-ewy.2 --project=/Users/adamu/proj/swift-ui-system-monitor-ewy.2 -- /Users/adamu/proj/swift-ui-system-monitor-ewy.2/test.sh 2>&1 | tail -15
  ```

  A green run ends with `Name check passed: ...` after the `passed` lines. A red run prints `FAIL: <message>` and stops; a compile error is also red.

  ```bash
  mc resource release LEASE --issue=swift-ui-system-monitor-ewy.2 --reason=done
  ```

- Commit with named paths, never a bare `git commit -a`. A new file needs `git add` first. Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Tests never touch the real `~/Library/Application Support/SystemBar/`. No test in this stage needs a file at all.
- Line numbers are from `main` at `aafcd7e`. Find each block by the text quoted with it; the number is for orientation.
- Immutable data, small functions, plain-words comments that say why. Public SDK symbols are only ever added, never changed or removed.

---

## File structure after this stage

```
Sources/Kit/SharedModels.swift            MODIFIED: three fields on FastStatsSnapshot (Task 1)
Sources/Host/FastStatsSampler.swift       MODIFIED: CoreTicks, CPUCounters(cores:), per-core and
                                                    user/system math (Task 2)
SystemBarSchedulerTests.swift             MODIFIED: one sampler test (Task 2)
Plugins/CPU/Sources/CPUModels.swift       CREATED: CPUSampling, CPUCluster, CPUClusters,
                                                   ThermalReading, CPUThermal, MachineState (Task 3)
Plugins/CPU/Sources/CPUCollector.swift    CREATED: sysctl clusters, load average, pmset (Task 4)
Plugins/CPU/Sources/CPUPlugin.swift       MODIFIED: 10 s refresh, clusters, machineState,
                                                    collect(), thermal notification (Task 4)
Plugins/CPU/Sources/MachineStateView.swift CREATED: the views under the history (Task 5)
Plugins/CPU/Sources/CPUPanel.swift        MODIFIED: MachineStateView under the sparkline (Task 5)
Plugins/CPU/Tests/CPUTests.swift          MODIFIED: six new tests, one updated (Tasks 3-4)
README.md                                 MODIFIED: feeds row, pmset row, CPU row (Task 6)
docs/one-page/systembar-tab-plugins.md    MODIFIED: feed comment, decision-log line (Task 6)
```

`test.sh`, `Examples/HelloTab`, the other five plugins and `Sources/Host/HostSamplers.swift` are not touched.

---

### Task 1: Three fields on the fast feed

**Files:**
- Modify: `Sources/Kit/SharedModels.swift:73-93` (`public struct FastStatsSnapshot`)

The SDK has no test of its own for a plain field; Task 2's sampler test is what exercises them. Committed alone so the interface change is one commit.

- [ ] **Step 1: Add the fields**

In `Sources/Kit/SharedModels.swift`, inside `public struct FastStatsSnapshot: Sendable { ... }`, after the `cpuHistory` field (the block ending `public var cpuHistory: [Double] = []`), add:

```swift
    /// How busy each core was over the last second, as a percent from 0 to 100, in the kernel's
    /// core order (core 0 first). Empty until the second reading, and after any reading whose
    /// core count differed from the one before it.
    public var perCoreUsage: [Double] = []
    /// The part of `cpuUsagePercent` spent running programs (user and nice time), as a percent
    /// of all cores together.
    public var cpuUserPercent: Double = 0
    /// The part spent in the kernel on their behalf (system time), the same way. User plus
    /// system is `cpuUsagePercent`.
    public var cpuSystemPercent: Double = 0
```

- [ ] **Step 2: Update the struct's doc comment**

Replace the comment above the struct, which begins `/// The host's 1-second reading of CPU load and network traffic` and ends `/// second, so the very first reading is all zeros.`, with:

```swift
/// The host's 1-second reading of CPU load (the whole machine, each core, and the user/system
/// split) and network traffic, behind `HostServices.fastStats`. Every figure is worked out from
/// how far the kernel's counters moved since the previous second, so the very first reading is
/// all zeros.
```

- [ ] **Step 3: Build and run the tests**

Run the test command. Expected: green. Nothing fills the fields yet; the SDK interface must still emit and every plugin must still build against it.

- [ ] **Step 4: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 add Sources/Kit/SharedModels.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 commit -F - <<'EOF'
Give the fast feed per-core usage and the user/system split

Additive fields with zero defaults, so a bundle built against the earlier interface still
loads. The host fills them in the next commit.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 2: The sampler fills them

**Files:**
- Modify: `Sources/Host/FastStatsSampler.swift` (the rate math, `collectCPUCounters`, and the `CPUCounters` struct at the end)
- Modify: `SystemBarSchedulerTests.swift:36-37` (`runAll`) and after `testFastStatsSamplerKeepsNinetySeconds` (line ~651)

- [ ] **Step 1: Write the failing test**

In `SystemBarSchedulerTests.swift`, in `runAll()`, after `testFastStatsSamplerKeepsNinetySeconds()`, add:

```swift
        testFastStatsSamplerReportsPerCoreAndUserSystemShares()
```

After the `testFastStatsSamplerKeepsNinetySeconds` function (before `// MARK: - Process sampler`), add:

```swift
    private static func testFastStatsSamplerReportsPerCoreAndUserSystemShares() {
        let sampler = FastStatsSampler()
        let start = Date(timeIntervalSince1970: 1_000)
        let quiet = NetworkCounters(received: 0, sent: 0)

        let first = sampler.sample(
            cpu: CPUCounters(cores: [
                CoreTicks(user: 0, system: 0, idle: 0, nice: 0),
                CoreTicks(user: 0, system: 0, idle: 0, nice: 0),
            ]),
            network: quiet,
            at: start
        )
        expect(first.perCoreUsage.isEmpty && first.cpuUserPercent == 0 && first.cpuSystemPercent == 0, "a first sample has no per-core or user/system figures yet")

        let second = sampler.sample(
            cpu: CPUCounters(cores: [
                CoreTicks(user: 60, system: 20, idle: 20, nice: 0),   // 80% busy
                CoreTicks(user: 10, system: 0, idle: 80, nice: 10),   // 20% busy; nice counts as user
            ]),
            network: quiet,
            at: start.addingTimeInterval(1)
        )
        expect(second.perCoreUsage == [80, 20], "each core's busy percent over the interval, in the kernel's order, got \(second.perCoreUsage)")
        expect(second.cpuUsagePercent == 50, "the headline is still the whole machine's busy percent, got \(second.cpuUsagePercent)")
        expect(second.cpuUserPercent == 40 && second.cpuSystemPercent == 10, "user (with nice) and system as shares of all cores: 80 of 200 ticks and 20 of 200, got \(second.cpuUserPercent)/\(second.cpuSystemPercent)")

        let fewerCores = sampler.sample(
            cpu: CPUCounters(cores: [CoreTicks(user: 100, system: 0, idle: 0, nice: 0)]),
            network: quiet,
            at: start.addingTimeInterval(2)
        )
        expect(fewerCores.perCoreUsage == [80, 20], "a reading with a different core count keeps the last per-core figures rather than pairing the wrong cores, got \(fewerCores.perCoreUsage)")
    }
```

- [ ] **Step 2: Run the tests to see it fail**

Run the test command. Expected: the build fails, because there is no `CoreTicks` and no `CPUCounters(cores:)`. A compile failure is this harness's "red".

- [ ] **Step 3: Replace the counters and the rate math**

In `Sources/Host/FastStatsSampler.swift`, replace the two structs at the end of the file, from `struct CPUCounters {` through the closing brace of `NetworkCounters`, with:

```swift
/// One core's cumulative tick counts, as `host_processor_info` reports them.
struct CoreTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var active: UInt64 { user + system + nice }
    var total: UInt64 { active + idle }
}

/// Every core's ticks from one read. The sums are what the headline needs; the cores are what
/// the per-core figures need.
struct CPUCounters {
    let cores: [CoreTicks]

    init(cores: [CoreTicks]) {
        self.cores = cores
    }

    /// The whole machine as one core: for a read that failed, and for tests of the rate math.
    init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        cores = [CoreTicks(user: user, system: system, idle: idle, nice: nice)]
    }

    var user: UInt64 { cores.reduce(0) { $0 + $1.user } }
    var system: UInt64 { cores.reduce(0) { $0 + $1.system } }
    var nice: UInt64 { cores.reduce(0) { $0 + $1.nice } }
    var active: UInt64 { cores.reduce(0) { $0 + $1.active } }
    var total: UInt64 { cores.reduce(0) { $0 + $1.total } }
}

struct NetworkCounters {
    let received: UInt64
    let sent: UInt64
}
```

In `sample(cpu:network:at:)`, replace the lines from `let cpuPercent = Self.busyPercent(from: previousCPU, to: cpu) ?? last.cpuUsagePercent` through `BoundedHistory.append(cpuPercent, to: &next.cpuHistory, limit: Self.historyLimit)` with:

```swift
        let cpuPercent = Self.busyPercent(from: previousCPU, to: cpu) ?? last.cpuUsagePercent
        let shares = Self.shares(from: previousCPU, to: cpu)
            ?? (user: last.cpuUserPercent, system: last.cpuSystemPercent)
        let perCore = Self.perCoreBusyPercent(from: previousCPU, to: cpu) ?? last.perCoreUsage
        let rates = Self.rates(from: previousNetwork, at: previousDate, to: network, at: date)
            ?? (download: last.currentDownloadRate, upload: last.currentUploadRate)

        var next = last
        next.cpuUsagePercent = cpuPercent
        next.cpuUserPercent = shares.user
        next.cpuSystemPercent = shares.system
        next.perCoreUsage = perCore
        next.currentDownloadRate = rates.download
        next.currentUploadRate = rates.upload
        BoundedHistory.append(cpuPercent, to: &next.cpuHistory, limit: Self.historyLimit)
```

Replace the `busyPercent` function (from its doc comment `/// Nil when there is nothing to compare with or no CPU time passed.` through its closing brace) with:

```swift
    /// Nil when there is nothing to compare with or no CPU time passed.
    static func busyPercent(from previous: CPUCounters?, to current: CPUCounters) -> Double? {
        guard let previous else { return nil }
        let totalDelta = delta(previous.total, current.total)
        guard totalDelta > 0 else { return nil }
        return Double(delta(previous.active, current.active)) / Double(totalDelta) * 100
    }

    /// User (with nice) and system time as percents of all cores together; nil as `busyPercent`.
    static func shares(from previous: CPUCounters?, to current: CPUCounters) -> (user: Double, system: Double)? {
        guard let previous else { return nil }
        let totalDelta = delta(previous.total, current.total)
        guard totalDelta > 0 else { return nil }
        let userDelta = delta(previous.user, current.user) + delta(previous.nice, current.nice)
        let systemDelta = delta(previous.system, current.system)
        return (user: Double(userDelta) / Double(totalDelta) * 100, system: Double(systemDelta) / Double(totalDelta) * 100)
    }

    /// Each core's busy percent over the interval, in the kernel's order. Nil when there is no
    /// previous reading or the core count changed, since pairing cores by index would then pair
    /// the wrong ones. A core with no ticks at all reads as idle.
    static func perCoreBusyPercent(from previous: CPUCounters?, to current: CPUCounters) -> [Double]? {
        guard let previous, previous.cores.count == current.cores.count else { return nil }
        return zip(previous.cores, current.cores).map { before, after in
            let total = delta(before.total, after.total)
            guard total > 0 else { return 0 }
            return Double(delta(before.active, after.active)) / Double(total) * 100
        }
    }

    /// A counter that went backwards counts as no change rather than a huge wrapped number.
    private static func delta(_ before: UInt64, _ after: UInt64) -> UInt64 {
        after >= before ? after - before : 0
    }
```

In `collectCPUCounters()`, replace the block from `var user: UInt64 = 0` through `return CPUCounters(user: user, system: system, idle: idle, nice: nice)` (the end of the function) with:

```swift
        let stride = Int(CPU_STATE_MAX)
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(processorCount))

        for cpuIndex in 0..<Int(processorCount) {
            let offset = cpuIndex * stride
            cores.append(CoreTicks(
                user: UInt64(cpuInfo[offset + Int(CPU_STATE_USER)]),
                system: UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
            ))
        }

        let byteCount = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteCount)

        return CPUCounters(cores: cores)
```

The `guard result == KERN_SUCCESS, let cpuInfo else { return CPUCounters(user: 0, system: 0, idle: 0, nice: 0) }` line above it stays as it is: the one-core init covers it.

Update the class's doc comment: replace `/// The 1-second sample: CPU busy percent and network rates, each worked out from how far the` with `/// The 1-second sample: CPU busy percent (whole machine, each core, user and system) and network rates, each worked out from how far the`.

- [ ] **Step 4: Run the tests**

Run the test command. Expected: green, including the two older sampler tests (they use the one-core init and never read the new fields) and `testCollectorsDoNotLeakHostPortRights` in `SystemBarPerformanceTests.swift`, which calls `collectCPUCounters()` fifty times.

- [ ] **Step 5: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 add Sources/Host/FastStatsSampler.swift SystemBarSchedulerTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 commit -F - <<'EOF'
Publish each core's usage and the user/system split from the 1-second sampler

The sampler always read every core's ticks and summed them; now it keeps them, so the
feed carries per-core busy percents (empty across a core-count change, so cores are never
paired by the wrong index) and user and system as shares of all cores.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 3: The CPU tab's models and rules

**Files:**
- Create: `Plugins/CPU/Sources/CPUModels.swift`
- Modify: `Plugins/CPU/Tests/CPUTests.swift:7-15` (`runAll`) and the end of the enum

- [ ] **Step 1: Write the failing tests**

In `Plugins/CPU/Tests/CPUTests.swift`, in `runAll()`, after `testPluginIdentityMatchesTheOldTab()`, add:

```swift
        testClusterLayoutPutsTheSlowestClusterAtCoreZero()
        testClusterUsageIsTheMeanOfItsCores()
        testThermalSpeedLimitParsing()
```

At the end of the enum, after the `testPluginIdentityMatchesTheOldTab` function, add:

```swift
    // MARK: - Machine state

    private static func testClusterLayoutPutsTheSlowestClusterAtCoreZero() {
        // This Mac: sysctl lists Super (6) then Performance (12); the device tree puts the
        // Performance cores at 0-11 and the Super cores at 12-17.
        let thisMac = CPUClusters.layout(names: ["Super", "Performance"], counts: [6, 12], coreCount: 18)
        expect(thisMac == [CPUCluster(name: "Super", cores: 12..<18), CPUCluster(name: "Performance", cores: 0..<12)],
               "perflevel 0 is the fastest cluster and takes the last core indices, got \(String(describing: thisMac))")

        let m1 = CPUClusters.layout(names: ["Performance", "Efficiency"], counts: [4, 4], coreCount: 8)
        expect(m1 == [CPUCluster(name: "Performance", cores: 4..<8), CPUCluster(name: "Efficiency", cores: 0..<4)],
               "an M1's efficiency cores are 0-3, got \(String(describing: m1))")

        expect(CPUClusters.layout(names: ["Only"], counts: [8], coreCount: 8) == [CPUCluster(name: "Only", cores: 0..<8)],
               "one perflevel covers every core")
        expect(CPUClusters.layout(names: ["A", "B"], counts: [4, 4], coreCount: 10) == nil,
               "counts that do not add up to the core count give nil, so the view falls back to per-core bars")
        expect(CPUClusters.layout(names: [], counts: [], coreCount: 8) == nil, "no perflevels at all is nil too")
        expect(CPUClusters.layout(names: ["A"], counts: [4, 4], coreCount: 8) == nil, "mismatched name and count lists are nil rather than a trap")
    }

    private static func testClusterUsageIsTheMeanOfItsCores() {
        let cluster = CPUCluster(name: "Super", cores: 2..<4)
        expect(cluster.usage(perCore: [0, 0, 80, 20]) == 50, "a cluster's usage is the mean of its cores, got \(cluster.usage(perCore: [0, 0, 80, 20]))")
        expect(cluster.usage(perCore: []) == 0, "before the feed has per-core figures the cluster reads 0")
        expect(cluster.usage(perCore: [1, 2, 3]) == 0, "a feed with fewer cores than the cluster expects reads 0 rather than trapping")
        expect(cluster.coreCount == 2, "the core count is the range's length")
    }

    private static func testThermalSpeedLimitParsing() {
        let quiet = "Note: No thermal warning level has been recorded\nNote: No performance warning level has been recorded\nNote: No CPU power status has been recorded\n"
        expect(CPUThermal.parseSpeedLimit(quiet) == nil, "no CPU power status means no speed limit to show")

        let throttled = "CPU Power notify\n\tCPU_Scheduler_Limit \t= 100\n\tCPU_Available_CPUs \t= 18\n\tCPU_Speed_Limit \t= 80\n"
        expect(CPUThermal.parseSpeedLimit(throttled) == 80, "the speed limit is the CPU_Speed_Limit line, got \(String(describing: CPUThermal.parseSpeedLimit(throttled)))")
        expect(CPUThermal.parseSpeedLimit("CPU_Speed_Limit = banana") == nil, "a value that is not a number is nil, not a crash")

        expect(ThermalReading(state: .nominal, speedLimitPercent: nil).isNominal, "nominal with nothing recorded has nothing to say")
        expect(ThermalReading(state: .nominal, speedLimitPercent: 100).isNominal, "full speed is nothing to say either")
        expect(!ThermalReading(state: .fair, speedLimitPercent: nil).isNominal, "a fair state is worth a line")
        expect(!ThermalReading(state: .nominal, speedLimitPercent: 80).isNominal, "and so is a speed limit under 100")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run the test command. Expected: the build fails on `CPUClusters`, `CPUCluster`, `CPUThermal` and `ThermalReading` being undefined.

- [ ] **Step 3: Create the models**

Create `Plugins/CPU/Sources/CPUModels.swift`:

```swift
import Foundation

/// The CPU tab's own cadence. The headline, history, per-core and user/system figures come from
/// the host's 1-second feed; this is how often the tab reads what that feed does not carry.
enum CPUSampling {
    /// Load average, thermal state and `pmset -g therm`, while the tab is showing.
    static let refreshInterval: TimeInterval = 10
}

/// One group of cores that share a design, named as sysctl names it (`hw.perflevelN.name`),
/// with the range of core indices the kernel reports them under.
struct CPUCluster: Equatable {
    let name: String
    let cores: Range<Int>

    var coreCount: Int { cores.count }

    /// The cluster's busy percent: the mean of its cores' entries in the feed's `perCoreUsage`,
    /// or 0 when the feed has none yet (the first second, or just after a core-count change).
    func usage(perCore: [Double]) -> Double {
        guard !cores.isEmpty, cores.upperBound <= perCore.count else { return 0 }
        return perCore[cores].reduce(0, +) / Double(cores.count)
    }
}

enum CPUClusters {
    /// Which core indices belong to which perflevel. sysctl lists perflevels fastest first
    /// (`hw.perflevel0` is the fastest), but the kernel numbers cores slowest cluster first: on
    /// the development Mac the device tree puts the twelve "Performance" cores at 0-11 and the
    /// six "Super" cores at 12-17, and an M1 puts its four efficiency cores at 0-3. So the last
    /// perflevel takes the first indices, and so on back to perflevel 0. The result is in
    /// sysctl's order, fastest first, for display. Nil when the lists disagree or the counts do
    /// not add up to the core count; the view then falls back to unnamed per-core bars.
    static func layout(names: [String], counts: [Int], coreCount: Int) -> [CPUCluster]? {
        guard names.count == counts.count, !names.isEmpty, counts.reduce(0, +) == coreCount else { return nil }
        var next = 0
        var slowestFirst: [CPUCluster] = []
        for (name, count) in zip(names, counts).reversed() {
            slowestFirst.append(CPUCluster(name: name, cores: next..<(next + count)))
            next += count
        }
        return slowestFirst.reversed()
    }
}

/// What the thermal line shows: the coarse state macOS reports to any process, and, while the
/// tab is showing, the speed limit `pmset -g therm` reports (100 means no throttling).
struct ThermalReading: Equatable {
    let state: ProcessInfo.ThermalState
    let speedLimitPercent: Int?

    /// The line is hidden while there is nothing to say: a nominal state at full speed.
    var isNominal: Bool {
        state == .nominal && (speedLimitPercent ?? 100) >= 100
    }
}

enum CPUThermal {
    /// `pmset -g therm` prints `CPU_Speed_Limit = 80` under "CPU Power notify" while throttled,
    /// and "No CPU power status has been recorded" when nothing has happened. Nil for the latter,
    /// and for any output without a numeric line.
    static func parseSpeedLimit(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("CPU_Speed_Limit") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// What the left column says beyond the headline and the feed: read every
/// `CPUSampling.refreshInterval` while the tab is showing.
struct MachineState: Equatable {
    /// The 1-minute load average: runnable threads, so "6.2 of 18 cores" reads as how many
    /// cores could have been kept busy.
    let loadAverage: Double
    let coreCount: Int
    let thermal: ThermalReading
    let sampledAt: Date

    /// Before the first collect: the view hides the load line while `coreCount` is 0.
    static let empty = MachineState(
        loadAverage: 0,
        coreCount: 0,
        thermal: ThermalReading(state: .nominal, speedLimitPercent: nil),
        sampledAt: .distantPast
    )
}
```

- [ ] **Step 4: Run the tests**

Run the test command. Expected: green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 add Plugins/CPU/Sources/CPUModels.swift Plugins/CPU/Tests/CPUTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 commit -F - <<'EOF'
Model the CPU tab's clusters, thermal reading and machine state

The cluster rule is the one the device tree settled: the kernel numbers cores slowest
cluster first, so sysctl's last perflevel takes core 0 onward. Counts that do not add up
give nil and the view falls back to per-core bars.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 4: The plugin reads sysctl, the load average and pmset

**Files:**
- Create: `Plugins/CPU/Sources/CPUCollector.swift`
- Modify: `Plugins/CPU/Sources/CPUPlugin.swift` (whole file)
- Modify: `Plugins/CPU/Tests/CPUTests.swift` (`runAll`, `testPluginIdentityMatchesTheOldTab`, and the end of the enum)

- [ ] **Step 1: Write the failing tests**

In `runAll()`, after `testThermalSpeedLimitParsing()`, add:

```swift
        testMachineStateRunsPmsetThroughTheHost()
        testClustersOnThisMacCoverEveryCore()
        testCollectPublishesTheMachineState()
```

In `testPluginIdentityMatchesTheOldTab`, replace the line

```swift
        expect(plugin.refreshInterval == PluginScheduler.maximumRefreshInterval, "its collect() does nothing, so it asks to be called as rarely as the host allows, got \(plugin.refreshInterval)")
```

with:

```swift
        expect(plugin.refreshInterval == CPUSampling.refreshInterval && CPUSampling.refreshInterval == 10, "collect() reads the load average, thermal state and pmset every 10 seconds while showing, got \(plugin.refreshInterval)")
```

At the end of the enum, after `testThermalSpeedLimitParsing`, add:

```swift
    private static func testMachineStateRunsPmsetThroughTheHost() {
        let recorder = LogRecorder()
        let command = "/usr/bin/pmset -g therm"
        let throttled = "CPU Power notify\n\tCPU_Speed_Limit \t= 80\n"
        let host = makeHost(runner: recordingRunner(recorder, answers: [command: throttled]))
        let state = CPUCollector.machineState(using: host, now: Date(timeIntervalSince1970: 1_000))
        expect(recorder.messages == [command], "one pmset, through the host, by explicit path, got \(recorder.messages)")
        expect(state.thermal.speedLimitPercent == 80, "the speed limit comes from pmset, got \(String(describing: state.thermal.speedLimitPercent))")
        expect(state.coreCount == ProcessInfo.processInfo.activeProcessorCount && state.loadAverage >= 0, "the core count and load average come from the kernel, got \(state.coreCount) and \(state.loadAverage)")
        expect(state.sampledAt == Date(timeIntervalSince1970: 1_000), "the reading carries the time it was taken")

        let failing = CPUCollector.machineState(using: makeHost(runner: recordingRunner(LogRecorder(), answers: [:])))
        expect(failing.thermal.speedLimitPercent == nil, "a pmset that fails means no speed limit, not a guess")
    }

    private static func testClustersOnThisMacCoverEveryCore() {
        // sysctl is read for real here: the layout rule has fixed-input tests above, this checks
        // the plumbing against whichever chip runs the tests.
        guard let clusters = CPUCollector.clusters() else {
            expect(true, "a chip whose perflevel counts do not add up falls back to per-core bars")
            return
        }
        let covered = clusters.flatMap { Array($0.cores) }.sorted()
        expect(covered == Array(0..<ProcessInfo.processInfo.activeProcessorCount), "the clusters cover every core index once, got \(clusters)")
        expect(clusters.allSatisfy { !$0.name.isEmpty }, "every cluster carries sysctl's name, got \(clusters.map(\.name))")
    }

    private static func testCollectPublishesTheMachineState() {
        let command = "/usr/bin/pmset -g therm"
        let answers = [command: "CPU Power notify\n\tCPU_Speed_Limit \t= 90\n"]
        let plugin = CPUPlugin(host: makeHost(runner: recordingRunner(LogRecorder(), answers: answers)))
        expect(plugin.machineState == .empty, "before the first collect the state is empty")
        plugin.collect()
        waitUntil { plugin.machineState.thermal.speedLimitPercent == 90 }
        expect(plugin.machineState.thermal.speedLimitPercent == 90 && plugin.machineState.coreCount > 0, "collect publishes the reading on the main thread, got \(plugin.machineState)")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run the test command. Expected: the build fails on `CPUCollector` being undefined and `plugin.machineState` not existing.

- [ ] **Step 3: Create the collector**

Create `Plugins/CPU/Sources/CPUCollector.swift`:

```swift
import Darwin
import Foundation
import SystemBarKit

/// The CPU tab's own reads: the chip's clusters from sysctl (once; a chip does not change), and
/// the load average, thermal state and `pmset -g therm` on every collect while showing.
enum CPUCollector {
    static let pmsetPath = "/usr/bin/pmset"
    static let pmsetArguments = ["-g", "therm"]

    /// The clusters sysctl describes, laid over the kernel's core indices by `CPUClusters.layout`,
    /// or nil when sysctl has no perflevels or their counts do not match `coreCount`.
    static func clusters(coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> [CPUCluster]? {
        guard let levels = sysctlInt("hw.nperflevels"), levels > 0 else { return nil }
        var names: [String] = []
        var counts: [Int] = []
        for level in 0..<levels {
            guard let name = sysctlString("hw.perflevel\(level).name"),
                  let count = sysctlInt("hw.perflevel\(level).logicalcpu") else { return nil }
            names.append(name)
            counts.append(count)
        }
        return CPUClusters.layout(names: names, counts: counts, coreCount: coreCount)
    }

    /// One reading of what the feed does not carry. `pmset` goes through the host so a test can
    /// answer it; the load average and thermal state are kernel calls that cannot usefully fail.
    static func machineState(using host: HostServices, now: Date = Date()) -> MachineState {
        let therm = host.run(path: pmsetPath, arguments: pmsetArguments)
        let speedLimit = therm.status == 0 ? CPUThermal.parseSpeedLimit(therm.output) : nil
        return MachineState(
            loadAverage: loadAverage(),
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            thermal: ThermalReading(state: ProcessInfo.processInfo.thermalState, speedLimitPercent: speedLimit),
            sampledAt: now
        )
    }

    /// The 1-minute load average, or 0 if the kernel will not say.
    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1 else { return 0 }
        return loads[0]
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
```

- [ ] **Step 4: Rewrite the plugin**

Replace the whole of `Plugins/CPU/Sources/CPUPlugin.swift` with:

```swift
import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The CPU tab as a bundle. The headline, graph, cluster bars and user/system split follow the
/// host's 1-second feed and the list follows its process feed. `collect()` reads what the feed
/// does not carry (load average, thermal state, `pmset -g therm`) every ten seconds while the
/// tab is showing, and again whenever macOS says the thermal state changed. The one other
/// command it runs is a `ps` when a row is tapped, which the panel calls off the main thread.
@objc(SystemBarCPUPlugin)
public final class CPUPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "cpu"
    public let title = "CPU"
    public let systemImage = "cpu"
    public let accent = Palette.warning
    public let refreshInterval: TimeInterval = CPUSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]

    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    @Published private(set) var machineState = MachineState.empty
    /// Read once at init: a chip does not change. Nil means the view draws per-core bars with
    /// no cluster names.
    let clusters: [CPUCluster]?
    private let host: HostServices
    private var feedSubscriptions: [AnyCancellable] = []
    private var thermalObserver: NSObjectProtocol?

    @MainActor public init(host: HostServices) {
        self.host = host
        clusters = CPUCollector.clusters()
        super.init()
        fastStats = host.fastStats.value
        processes = host.processes.value
        feedSubscriptions = [
            host.fastStats.publisher.sink { [weak self] snapshot in self?.fastStats = snapshot },
            host.processes.publisher.sink { [weak self] summary in self?.processes = summary },
        ]
        // The thermal state is read inside collect(); a change is worth one read now rather
        // than up to ten seconds later. Off the main thread, as the host's own calls are.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { self?.collect() }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    /// Reads the load average, thermal state and pmset's speed limit, and publishes them on the
    /// main thread, where the panel observes them.
    public func collect() {
        let state = CPUCollector.machineState(using: host)
        DispatchQueue.main.async { [weak self] in self?.machineState = state }
    }

    /// The tapped group's processes, from a fresh `ps`. Blocking: the panel calls it off main.
    func groupDetail(named name: String) -> [ProcessDetail] {
        ProcessDetail.fetchGroupDetail(name: name, using: host)
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(CPUPanel(plugin: self))
    }
}
```

- [ ] **Step 5: Run the tests**

Run the test command. Expected: green. `testPluginFollowsBothFeeds` and the drill-in tests are unchanged and still pass; the fresh-file check still loads six tabs. If `testCollectPublishesTheMachineState` fails because `waitUntil` timed out, check that `collect()` publishes with `DispatchQueue.main.async` and that the test's `waitUntil` spins the main run loop (it does; the other plugin tests rely on it).

- [ ] **Step 6: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 add Plugins/CPU/Sources/CPUCollector.swift Plugins/CPU/Sources/CPUPlugin.swift Plugins/CPU/Tests/CPUTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 commit -F - <<'EOF'
Read the chip's clusters, the load average and the thermal speed limit in the CPU tab

Clusters come from sysctl once at init. Every ten seconds while showing, and on a thermal
state change, collect() reads the load average and thermal state from the kernel and the
speed limit from pmset -g therm through the host, and publishes a MachineState.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 5: The views under the history

**Files:**
- Create: `Plugins/CPU/Sources/MachineStateView.swift`
- Modify: `Plugins/CPU/Sources/CPUPanel.swift:16-37` (the left column)

The project has no tests of SwiftUI views; this task is checked by the build and by eye at handoff.

- [ ] **Step 1: Create the views**

Create `Plugins/CPU/Sources/MachineStateView.swift`:

```swift
import SwiftUI
import SystemBarKit

/// The left column under the history: one bar per cluster (or one thin bar per core when the
/// clusters are unknown), the user/system split, the load average against the core count, and
/// the thermal line when it has something to say.
struct MachineStateView: View {
    let clusters: [CPUCluster]?
    let fastStats: FastStatsSnapshot
    let state: MachineState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let clusters {
                ForEach(clusters, id: \.name) { cluster in
                    LabelledBar(
                        label: "\(cluster.name) · \(cluster.coreCount)",
                        percent: cluster.usage(perCore: fastStats.perCoreUsage),
                        color: accent
                    )
                }
            } else {
                PerCoreBars(perCore: fastStats.perCoreUsage, color: accent)
            }

            UserSystemBar(user: fastStats.cpuUserPercent, system: fastStats.cpuSystemPercent, accent: accent)

            if state.coreCount > 0 {
                Text("load \(String(format: "%.1f", state.loadAverage)) of \(state.coreCount) cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.thermal.isNominal {
                ThermalLine(thermal: state.thermal)
            }
        }
    }
}

/// A name on the left, a thin bar, and the percent on the right.
struct LabelledBar: View {
    let label: String
    let percent: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            ProgressBar(value: percent / 100, color: color)
                .frame(height: 6)
            Text(percentString(percent))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// The fallback when sysctl's clusters cannot be laid over the cores: one thin bar per core,
/// in the kernel's order, with no names.
struct PerCoreBars: View {
    let perCore: [Double]
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(perCore.enumerated()), id: \.offset) { _, percent in
                ProgressBar(value: percent / 100, color: color)
                    .frame(height: 6)
            }
        }
    }
}

/// User time filled from the left in the accent, system time after it in white, idle as the
/// track, with a legend that names both figures.
struct UserSystemBar: View {
    let user: Double
    let system: Double
    let accent: Color

    private let systemColor = Color.white.opacity(0.6)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    accent.frame(width: geometry.size.width * fraction(user))
                    systemColor.frame(width: geometry.size.width * fraction(system))
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 6)

            HStack(spacing: 12) {
                LegendLabel(text: "user \(percentString(user))", color: accent)
                LegendLabel(text: "system \(percentString(system))", color: systemColor)
            }
        }
    }

    private func fraction(_ percent: Double) -> CGFloat {
        CGFloat(max(0, min(1, percent / 100)))
    }
}

/// "thermal: fair, 80% speed", coloured by the state the way the Power tab colours it.
struct ThermalLine: View {
    let thermal: ThermalReading

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var text: String {
        let state = thermalStateLabel(thermal.state).lowercased()
        if let limit = thermal.speedLimitPercent, limit < 100 {
            return "thermal: \(state), \(limit)% speed"
        }
        return "thermal: \(state)"
    }

    private var color: Color {
        switch thermal.state {
        case .critical: return Palette.critical
        case .serious: return Palette.warning
        default: return Palette.caution
        }
    }
}
```

- [ ] **Step 2: Put it under the history**

In `Plugins/CPU/Sources/CPUPanel.swift`, replace the lines

```swift
                Sparkline(values: plugin.fastStats.cpuHistory, maxValue: 100, color: accentColor, fill: true)
                    .frame(height: 120)

                Spacer(minLength: 0)
```

with:

```swift
                Sparkline(values: plugin.fastStats.cpuHistory, maxValue: 100, color: accentColor, fill: true)
                    .frame(height: 96)

                MachineStateView(
                    clusters: plugin.clusters,
                    fastStats: plugin.fastStats,
                    state: plugin.machineState,
                    accent: accentColor
                )

                Spacer(minLength: 0)
```

- [ ] **Step 3: Build and run the tests**

Run the test command. Expected: green. The views are compiled into the CPU bundle by `build.sh`, which the test command runs first; a SwiftUI type error here is the thing this step catches.

- [ ] **Step 4: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 add Plugins/CPU/Sources/MachineStateView.swift Plugins/CPU/Sources/CPUPanel.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 commit -F - <<'EOF'
Show cluster load, the user/system split, load average and thermal state under the CPU history

One bar per cluster named as sysctl names it, or per-core bars when the clusters are
unknown; the thermal line only appears when the state is not nominal or pmset reports a
speed limit under 100.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md:62` (the `.fastStats` row), `README.md:152` (the `pmset` row), `README.md:179` (the CPU row)
- Modify: `docs/one-page/systembar-tab-plugins.md:197` (the `fastStats` case comment) and the Decision Log at the end

- [ ] **Step 1: README, the feeds table**

Replace the row beginning `| `.fastStats` | CPU percent and network rates, with 90 seconds of history |` with:

```markdown
| `.fastStats` | CPU percent (the whole machine, each core, and the user/system split) and network rates, with 90 seconds of history for the headline figures | Every second while the window is open, whatever the tab, so the history has no gaps |
```

- [ ] **Step 2: README, the commands table**

Replace the row beginning `| `/usr/bin/pmset` | Battery state and sleep assertions; thermal and performance warnings | Every 60s |` with:

```markdown
| `/usr/bin/pmset` | Battery state and sleep assertions; thermal and performance warnings; the thermal speed limit | Every 60s for the Power and Dev tabs; every 10s while the CPU tab is showing |
```

- [ ] **Step 3: README, the per-tab table**

Replace the row beginning `| CPU | Nothing of its own: everything it shows comes from the two shared feeds |` with:

```markdown
| CPU | Load average, thermal state and `pmset -g therm` every 10s; the headline, history, cluster bars and user/system split come from the 1-second feed | — | `CPUSampling` in `Plugins/CPU/Sources/CPUModels.swift` |
```

- [ ] **Step 4: The plugin spec's feed comment and decision log**

In `docs/one-page/systembar-tab-plugins.md`, replace the line

```swift
    case fastStats   // the 1-second CPU and network counters and their histories
```

with:

```swift
    case fastStats   // the 1-second CPU (whole machine, per core, user/system) and network counters and their histories
```

At the end of the `## Decision Log` list, add:

```markdown
- 2026-10-10 — `FastStatsSnapshot` gains `perCoreUsage`, `cpuUserPercent` and
  `cpuSystemPercent`, additive, because the host already read every core's ticks
  and only published the sum (CPU epic D5) — Adam.
```

- [ ] **Step 5: Check the tables and the tests**

`cat` the README's three tables once to be sure every row still has the right number of cells (three in the feeds and commands tables, four in the per-tab table). Then run the test command: the commit should sit on a green tree.

- [ ] **Step 6: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 add README.md docs/one-page/systembar-tab-plugins.md
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 commit -F - <<'EOF'
Document the fast feed's new fields and what the CPU tab now reads every 10 seconds

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 7: Review, close, hand off

**Files:** none new.

- [ ] **Step 1: Full test run**

Run the test command once more on the final tree. Expected: green.

- [ ] **Step 2: Code review**

Use the `code-reviewer` agent on `git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 diff main...ewy.2-machine-state`. Fix anything HIGH or above, re-run the tests, and commit the fix with a named path.

- [ ] **Step 3: Release the lease and close the issue**

```bash
mc resource release LEASE --issue=swift-ui-system-monitor-ewy.2 --reason=done
bd close swift-ui-system-monitor-ewy.2 --reason="fast feed per-core and user/system fields, cluster layout from sysctl, load average, thermal line, MachineStateView on branch ewy.2-machine-state"
```

- [ ] **Step 4: Hand off**

Report: the branch name and its commits (`git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.2 log --oneline main..ewy.2-machine-state`), that the tests passed, and that merging to `main` and installing wait for the user's word. Ask the user to open the CPU tab after installing and check by eye: two cluster bars named Super and Performance (6 and 12 cores) that move with load, the user/system bar and legend, the load line, and no thermal line while the machine is cool. Running a short `yes > /dev/null` in a terminal should lift one cluster's bar and the user share within a second or two.
