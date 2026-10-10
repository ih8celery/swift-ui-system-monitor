# Background Sampling Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A plugin may declare `backgroundInterval`, and the host then keeps calling its `collect()` at that cadence while its tab is not showing, with a floor of 5 seconds, a two-minute settle after the Mac wakes, `--list-plugins` reporting the cadence, and the contract documented for plugin authors. Nothing else changes: a plugin that declares nothing behaves exactly as before.

**Architecture:** `TabPlugin` (in the SDK, `Sources/Kit/TabPlugin.swift`) gains one optional property with a nil default in its protocol extension, so every bundle built against the earlier interface still loads. `PluginScheduler` (`Sources/Host/PluginScheduler.swift`) already owns one serial queue per plugin and a timer that runs only while shown; it gains a second, slower timer per declaring plugin on that same queue, started at launch by a new `start(_:)`, swapped for the fast timer by `show`, swapped back by `hide` or by another tab being shown, and restarted two minutes after a wake notification. Because both timers share the plugin's serial queue, a background collect still running when the tab is shown finishes before the first foreground tick. `PluginListReport` appends the clamped cadence to a declaring plugin's line. The shared feeds (`HostSamplers`) are untouched.

**Tech Stack:** Swift in `-swift-version 5` mode, `-target arm64-apple-macos14`, `swiftc` only (no package manager), Foundation, AppKit (`NSWorkspace` wake notifications), Dispatch timers. Tests are the in-process binary `test.sh` builds; `expect` exits on the first failure.

**Spec:** `docs/one-page/systembar-ewy-cpu-machine-state-and-background-sampling.md`, sections "SDK Contract" and Decisions D2, D3, D7. The Disk epic (`swift-ui-system-monitor-ifd`) adopts this contract and waits for this stage, so the names below are shared: `backgroundInterval`, `PluginScheduler.minimumBackgroundInterval`, `PluginScheduler.backgroundSettleAfterWake`, and the `--list-plugins` suffix `background every <n>s`.

**Beads issue:** `swift-ui-system-monitor-ewy.1`. Claim it before Task 1 (`bd update swift-ui-system-monitor-ewy.1 --claim`), close it after Task 7.

**Rules for every task:**

- Work in a worktree, so the shared checkout at `/Users/adamu/proj/swift-ui-system-monitor` (which the Disk session also uses) is never edited. Before Task 1, wait for the Disk session's settings and `dataDirectory` commits to be on `main` (it will send the hash), then:

  ```bash
  git -C /Users/adamu/proj/swift-ui-system-monitor worktree add /Users/adamu/proj/swift-ui-system-monitor-ewy.1 -b ewy.1-background-sampling main
  ```

  If the hash has not arrived and the user says to go ahead anyway, branch from the current `main`; the only overlap is `Sources/Host/App.swift`, where Task 5 adds one line, and a rebase resolves it.
- `W` below is shorthand in prose for `/Users/adamu/proj/swift-ui-system-monitor-ewy.1`; every command spells the path out. `cd` does not persist between commands.
- Building and testing takes an `xcode-build` lease. Request it once before Task 1 and release it after Task 7:

  ```bash
  mc resource request xcode-build --issue=swift-ui-system-monitor-ewy.1 --reason="Stage 1 builds and tests"
  ```

  It prints a lease id; write it where `LEASE` appears below. Every test run is exactly this command, never piped into `head`:

  ```bash
  mc run --action=swift-test --lease=LEASE --issue=swift-ui-system-monitor-ewy.1 --project=/Users/adamu/proj/swift-ui-system-monitor-ewy.1 -- /Users/adamu/proj/swift-ui-system-monitor-ewy.1/test.sh 2>&1 | tail -15
  ```

  A green run ends with `Name check passed: ...` after the four `passed` lines from the in-process tests and the boundary, shipped-script and fresh-file checks. A red run prints `FAIL: <message>` and stops.

  ```bash
  mc resource release LEASE --issue=swift-ui-system-monitor-ewy.1 --reason=done
  ```

- Commit with named paths, never a bare `git commit -a`. A new file needs `git add` first. Every commit message ends with the attribution line shown in Task 1.
- Tests never touch `~/Library/Application Support/SystemBar/`. No test in this stage needs a file at all.
- Line numbers are from `main` at `b086597`. Find each block by the text quoted with it; the number is for orientation.
- Immutable data, small functions, plain-words comments that say why.

---

## File structure after this stage

```
Sources/Kit/TabPlugin.swift            MODIFIED: backgroundInterval requirement + nil default (Task 1)
Sources/Host/PluginScheduler.swift     MODIFIED: slow timer, start(_:), clamp, wake settle (Tasks 2-4)
Sources/Host/PluginListReport.swift    MODIFIED: "background every <n>s" suffix (Task 5)
Sources/Host/App.swift                 MODIFIED: scheduler.start(...) after loading (Task 5)
TestFakes.swift                        MODIFIED: BackgroundTab fake (Task 2)
SystemBarSchedulerTests.swift          MODIFIED: seven new scheduler tests (Tasks 2-4)
SystemBarLoaderTests.swift             MODIFIED: one new report test (Task 5)
docs/one-page/systembar-tab-plugins.md MODIFIED: D9, contract snippet, samplers paragraph, log (Task 6)
README.md                              MODIFIED: feeds line, "While hidden" column, commands sentence,
                                                 writing-a-plugin paragraph, --list-plugins sentence (Task 6)
```

Nothing is created and nothing is deleted. `Examples/HelloTab` declares nothing and is not touched. `test.sh` is not touched: no shipped plugin declares a background interval in this stage, so its expected lines stay as they are.

---

### Task 1: The SDK property

**Files:**
- Modify: `Sources/Kit/TabPlugin.swift:30-51`

The SDK has no test of its own for a protocol default; the scheduler tests in Task 2 are what exercise it. This task is the one SDK edit, committed alone so the interface change is one commit.

- [ ] **Step 1: Add the requirement**

In `Sources/Kit/TabPlugin.swift`, after the `sharedFeeds` requirement (the block ending `var sharedFeeds: Set<SharedFeed> { get }`), add:

```swift
    /// How often the host calls `collect()` while this tab is NOT showing: the window closed,
    /// or open on another tab. Nil, the default, means never: the tab samples only while it is
    /// on screen, as every tab did before this existed. A number is clamped to between 5 seconds
    /// and one day, and each substitution is logged. Shared feeds do not run for a hidden tab,
    /// so a `collect()` that runs in the background samples for itself; a feed value read then
    /// is whatever the feed last held. After the Mac wakes, the first background tick waits
    /// two minutes so no sample lands on the login moment. Declare one only for work the person
    /// wants done while they are not looking, and say in the README what runs and how often.
    var backgroundInterval: TimeInterval? { get }
```

- [ ] **Step 2: Add the default**

In the same file, inside `public extension TabPlugin { ... }` (the block whose comment begins "Defaults, so a plugin implements only what it needs"), after the `visibilityChanged` default, add:

```swift
    /// Nil: the tab is collected only while it is showing.
    var backgroundInterval: TimeInterval? { nil }
```

- [ ] **Step 3: Update the doc comment on the protocol**

Replace the protocol's leading comment, which begins `/// One tab. The host creates a plugin once at launch, calls `collect()` on the plugin's own` and ends `/// because the panel observes it from there.`, with:

```swift
/// One tab. The host creates a plugin once at launch, calls `collect()` on the plugin's own
/// queue while its tab is on screen (and, if the plugin declares a `backgroundInterval`, more
/// slowly while it is not), and embeds `makeView()` in the window.
///
/// Thread rules, fixed for every plugin built against this SDK: the host constructs every
/// plugin on the main thread at launch; `collect()` runs on a queue the host owns for this
/// plugin, never concurrently with itself; `makeView()` and `visibilityChanged(isVisible:)` run
/// on the main thread; a plugin that publishes from `collect()` hops to the main thread first,
/// because the panel observes it from there.
```

- [ ] **Step 4: Build and run the tests**

Run the test command from the rules. Expected: green. Nothing declares the property yet, so the default is all that is exercised, but the SDK interface must still emit and every plugin must still build against it.

- [ ] **Step 5: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 add Sources/Kit/TabPlugin.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 commit -F - <<'EOF'
Let a plugin declare a backgroundInterval

Nil by default, so every bundle built against the earlier interface still loads. The host
does nothing with it yet; the scheduler learns to in the next commits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 2: The scheduler's slow timer

**Files:**
- Modify: `TestFakes.swift` (append after `FakeTab`)
- Modify: `SystemBarSchedulerTests.swift:10-35` (the `runAll` list) and after `testSchedulerClampsABadRefreshInterval` (line ~155)
- Modify: `Sources/Host/PluginScheduler.swift` (whole file)

- [ ] **Step 1: Add the fake**

In `TestFakes.swift`, after the `FakeTab` class, add:

```swift
/// A tab that counts its collects and declares whatever intervals a test gives it, so a test can
/// watch the scheduler's fast and slow cadences, and whether the two ever overlap. `work` is how
/// long each collect sleeps, for the tests that need one still running when the timers swap.
final class BackgroundTab: TabPlugin {
    static let identifier = "background"
    let title = "Background"
    let systemImage = "moon"
    let accent = Color.gray
    let refreshInterval: TimeInterval
    let backgroundInterval: TimeInterval?
    private let work: TimeInterval
    private let lock = NSLock()
    private var inFlight = false
    private var collects = 0
    private var didOverlap = false

    convenience init(host: HostServices) {
        self.init(refresh: 5, background: 60)
    }

    init(refresh: TimeInterval, background: TimeInterval?, work: TimeInterval = 0) {
        refreshInterval = refresh
        backgroundInterval = background
        self.work = work
    }

    func collect() {
        lock.withLock {
            if inFlight { didOverlap = true }
            inFlight = true
            collects += 1
        }
        if work > 0 { Thread.sleep(forTimeInterval: work) }
        lock.withLock { inFlight = false }
    }

    @MainActor func makeView() -> AnyView { AnyView(Text("background")) }

    var count: Int { lock.withLock { collects } }
    var overlapped: Bool { lock.withLock { didOverlap } }
}
```

- [ ] **Step 2: Write the failing tests**

In `SystemBarSchedulerTests.swift`, in `runAll()`, after the line `testSchedulerClampsABadRefreshInterval()`, add:

```swift
        testSchedulerCollectsAHiddenTabAtItsBackgroundInterval()
        testSchedulerLeavesAHiddenTabAloneWhenItDeclaresNoBackgroundInterval()
        testSchedulerSwapsToTheFastTimerWhenShownAndBackWhenHidden()
        testSchedulerReturnsAReplacedTabToItsBackgroundCadence()
        testSchedulerNeverOverlapsABackgroundCollectWithTheFirstForegroundTick()
```

After the `testSchedulerClampsABadRefreshInterval` function (before `// MARK: - Host samplers`), add:

```swift
    // MARK: - Background sampling

    /// A scheduler whose floors are short enough that a test's intervals run as declared.
    private static func makeBackgroundScheduler(log: @escaping (String) -> Void = { _ in }) -> PluginScheduler {
        PluginScheduler(
            minimumRefreshInterval: 0.01,
            minimumBackgroundInterval: 0.01,
            settleAfterWake: 0.3,
            wakeNotifications: NotificationCenter(),
            log: log
        )
    }

    private static func testSchedulerCollectsAHiddenTabAtItsBackgroundInterval() {
        let plugin = BackgroundTab(refresh: 0.05, background: 0.1)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        expect(plugin.count == 0, "a background timer's first tick comes one interval after launch, not at once, got \(plugin.count)")
        waitUntil(2) { plugin.count >= 3 }
        expect(plugin.count >= 3, "a hidden tab with a backgroundInterval is collected every interval, got \(plugin.count) collects")
        expect(!plugin.overlapped, "background collects never run concurrently with themselves")
    }

    private static func testSchedulerLeavesAHiddenTabAloneWhenItDeclaresNoBackgroundInterval() {
        let plugin = BackgroundTab(refresh: 0.05, background: nil)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        spinRunLoop(for: 0.3)
        expect(plugin.count == 0, "a tab with no backgroundInterval is never collected while hidden, got \(plugin.count)")
    }

    private static func testSchedulerSwapsToTheFastTimerWhenShownAndBackWhenHidden() {
        let plugin = BackgroundTab(refresh: 0.02, background: 0.3)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        scheduler.show(plugin)
        waitUntil { plugin.count >= 5 }
        expect(plugin.count >= 5, "showing a background tab collects it at its refreshInterval, got \(plugin.count)")
        scheduler.hide()
        let atHide = plugin.count
        spinRunLoop(for: 0.15)
        // A fast tick already dispatched when hide() cancelled its timer may still land, so
        // allow one; two would mean the slow timer fired early.
        expect(plugin.count <= atHide + 1, "after hide, the next tick waits one background interval, got \(plugin.count - atHide) collects in half an interval")
        waitUntil(2) { plugin.count > atHide }
        expect(plugin.count > atHide, "after hide, the tab goes back to its background cadence")
        expect(!plugin.overlapped, "the fast and slow timers never overlap")
        scheduler.hide()
    }

    private static func testSchedulerReturnsAReplacedTabToItsBackgroundCadence() {
        let background = BackgroundTab(refresh: 0.02, background: 0.1)
        let other = TickingTab(host: makeHost())
        let scheduler = makeBackgroundScheduler()
        scheduler.start([background])
        scheduler.show(background)
        waitUntil { background.count >= 2 }
        scheduler.show(other)
        let atSwitch = background.count
        waitUntil(2) { background.count >= atSwitch + 2 }
        expect(background.count >= atSwitch + 2, "a tab replaced by another returns to its background cadence, got \(background.count - atSwitch) more collects")
        expect(!background.overlapped, "swapping timers never overlaps a collect")
        scheduler.hide()
    }

    private static func testSchedulerNeverOverlapsABackgroundCollectWithTheFirstForegroundTick() {
        let plugin = BackgroundTab(refresh: 0.02, background: 0.05, work: 0.15)
        let scheduler = makeBackgroundScheduler()
        scheduler.start([plugin])
        waitUntil { plugin.count >= 1 }
        // The background collect is now asleep inside `work`; showing the tab must queue the
        // first fast tick behind it, not beside it.
        scheduler.show(plugin)
        spinRunLoop(for: 0.3)
        expect(!plugin.overlapped, "a background collect still running when the tab is shown must finish before the first foreground tick")
        scheduler.hide()
    }
```

- [ ] **Step 3: Run the tests to see them fail**

Run the test command. Expected: the build fails, because `PluginScheduler` has no `start(_:)`, `minimumBackgroundInterval:`, `settleAfterWake:` or `wakeNotifications:`. (A compile failure is this harness's "red".)

- [ ] **Step 4: Rewrite the scheduler**

Replace the whole of `Sources/Host/PluginScheduler.swift` with:

```swift
import AppKit
import Foundation
import SystemBarKit

/// Runs each plugin's `collect()` on a queue the host owns for it: every `refreshInterval`
/// seconds while its tab is showing and, for a plugin that declares a `backgroundInterval`,
/// every that many seconds while it is not. One serial queue per plugin, so the two cadences
/// never overlap and a slow collect delays the next tick rather than running beside it. Only one
/// plugin is shown at a time, enforced here: showing a different plugin returns the previous one
/// to its background cadence, or to nothing. After the Mac wakes, every background timer is
/// restarted with its first tick `settleAfterWake` later, because a Dispatch timer that missed
/// its deadline during sleep fires the instant the Mac wakes, which would land a sample on the
/// login moment. Main thread only.
@MainActor
final class PluginScheduler {
    private struct Slot {
        let plugin: TabPlugin
        let queue: DispatchQueue
        var timer: DispatchSourceTimer?
    }

    /// The floor under any plugin's declared refreshInterval, so a bad bundle cannot spin a core or trap.
    nonisolated static let minimumRefreshInterval: TimeInterval = 0.25
    /// The ceiling for both intervals: a day is the longest a tab can sensibly wait, and Dispatch traps far above it.
    nonisolated static let maximumRefreshInterval: TimeInterval = 86_400
    /// The floor under a declared backgroundInterval. A hidden tab is the app's idle cost, so it
    /// may not sample faster than this however small the bundle's number.
    nonisolated static let minimumBackgroundInterval: TimeInterval = 5
    /// How long after a wake the first background tick waits.
    nonisolated static let backgroundSettleAfterWake: TimeInterval = 120

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var shown: TabPlugin?
    private let minimumRefreshInterval: TimeInterval
    private let minimumBackgroundInterval: TimeInterval
    private let maximumRefreshInterval: TimeInterval
    private let settleAfterWake: TimeInterval
    private let wakeNotifications: NotificationCenter
    private var wakeObservers: [NSObjectProtocol] = []
    private let log: (String) -> Void

    /// The bounds, the settle, the notification center and `log` default to the real app's, but
    /// a test can override any of them — short floors so its fakes run at their own declared
    /// intervals, a center of its own so it can post a wake, and a capturing closure instead of
    /// NSLog — without any of it leaking into the real app.
    init(
        minimumRefreshInterval: TimeInterval = PluginScheduler.minimumRefreshInterval,
        minimumBackgroundInterval: TimeInterval = PluginScheduler.minimumBackgroundInterval,
        maximumRefreshInterval: TimeInterval = PluginScheduler.maximumRefreshInterval,
        settleAfterWake: TimeInterval = PluginScheduler.backgroundSettleAfterWake,
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        log: @escaping (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.minimumBackgroundInterval = minimumBackgroundInterval
        self.maximumRefreshInterval = maximumRefreshInterval
        self.settleAfterWake = settleAfterWake
        self.wakeNotifications = wakeNotifications
        self.log = log
        observeWakes()
    }

    deinit {
        wakeObservers.forEach { wakeNotifications.removeObserver($0) }
    }

    // MARK: - Intervals

    /// A declared refreshInterval clamped between this scheduler's minimum and maximum. Zero
    /// would spin its queue's thread and a negative or NaN value would trap the timer, so those
    /// take the minimum. Dispatch counts the interval in nanoseconds in a UInt64 and traps on a
    /// huge one, so anything above the maximum takes the maximum — including infinity, which
    /// reads as "hardly ever", not "as fast as possible". The substitution is logged each time.
    func effectiveInterval(_ declared: TimeInterval, identifier: String) -> TimeInterval {
        let clamped = Self.clamp(declared, floor: minimumRefreshInterval, ceiling: maximumRefreshInterval)
        if clamped != declared {
            log("SystemBar: \(identifier) asked for a refreshInterval of \(declared); using \(clamped)")
        }
        return clamped
    }

    /// A declared backgroundInterval clamped the same way, against the background floor.
    func effectiveBackgroundInterval(_ declared: TimeInterval, identifier: String) -> TimeInterval {
        let clamped = Self.clamp(declared, floor: minimumBackgroundInterval, ceiling: maximumRefreshInterval)
        if clamped != declared {
            log("SystemBar: \(identifier) asked for a backgroundInterval of \(declared); using \(clamped)")
        }
        return clamped
    }

    /// What a declared backgroundInterval becomes in the real app, for `--list-plugins` to
    /// report the cadence that would actually run.
    nonisolated static func reportedBackgroundInterval(_ declared: TimeInterval) -> TimeInterval {
        clamp(declared, floor: minimumBackgroundInterval, ceiling: maximumRefreshInterval)
    }

    nonisolated private static func clamp(_ declared: TimeInterval, floor: TimeInterval, ceiling: TimeInterval) -> TimeInterval {
        if declared.isNaN { return floor }
        return min(max(declared, floor), ceiling)
    }

    // MARK: - Showing and hiding

    /// At launch: every plugin that declares a background interval starts its slow timer, first
    /// tick one interval from now. A plugin that declares nothing is left alone until shown.
    func start(_ plugins: [TabPlugin]) {
        for plugin in plugins where plugin.backgroundInterval != nil {
            startBackgroundTimer(for: plugin, firstTickAfter: nil)
        }
    }

    /// Shows `plugin`: returns whichever plugin was previously shown to its background cadence,
    /// if it is a different one, then starts this plugin's fast timer on its own serial queue —
    /// immediately, then every clamped `refreshInterval`. The queue is kept in `slots` across
    /// hides and shows, so a collect still running from the slow timer finishes before the
    /// first fast tick rather than ever overlapping it.
    func show(_ plugin: TabPlugin) {
        if let previous = shown, previous !== plugin {
            returnToBackground(previous)
        }
        shown = plugin

        let interval = effectiveInterval(plugin.refreshInterval, identifier: type(of: plugin).identifier)
        replaceTimer(for: plugin, firstTickAfter: 0, every: interval)
    }

    /// Hides whichever plugin is currently shown: its fast timer stops, and if it declares a
    /// background interval its slow timer starts, first tick one interval later, since the tab
    /// was collected a moment ago.
    func hide() {
        guard let plugin = shown else { return }
        returnToBackground(plugin)
        shown = nil
    }

    private func returnToBackground(_ plugin: TabPlugin) {
        cancelTimer(for: plugin)
        startBackgroundTimer(for: plugin, firstTickAfter: nil)
    }

    /// Starts (or restarts) the slow timer for a plugin that declares one. `firstTickAfter` nil
    /// means one interval from now.
    private func startBackgroundTimer(for plugin: TabPlugin, firstTickAfter delay: TimeInterval?) {
        guard let declared = plugin.backgroundInterval else { return }
        let interval = effectiveBackgroundInterval(declared, identifier: type(of: plugin).identifier)
        replaceTimer(for: plugin, firstTickAfter: delay ?? interval, every: interval)
    }

    // MARK: - Wake

    private func observeWakes() {
        let names = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]
        wakeObservers = names.map { name in
            wakeNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.settleBackgroundTimersAfterWake() }
            }
        }
    }

    /// Every hidden plugin with a background interval gets its timer restarted, first tick
    /// `settleAfterWake` from now. The shown tab's fast timer is left alone: the person is
    /// looking at it.
    private func settleBackgroundTimersAfterWake() {
        // Iterate a copy: restarting a timer writes back into `slots`.
        for slot in Array(slots.values) where slot.plugin !== shown {
            startBackgroundTimer(for: slot.plugin, firstTickAfter: settleAfterWake)
        }
    }

    // MARK: - Timers

    private func replaceTimer(for plugin: TabPlugin, firstTickAfter delay: TimeInterval, every interval: TimeInterval) {
        let key = ObjectIdentifier(plugin)
        var slot = slots[key] ?? Slot(
            plugin: plugin,
            queue: DispatchQueue(label: "systembar.plugin.\(type(of: plugin).identifier)", qos: .utility),
            timer: nil
        )
        slot.timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: slot.queue)
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak plugin] in plugin?.collect() }
        timer.resume()
        slot.timer = timer
        slots[key] = slot
    }

    private func cancelTimer(for plugin: TabPlugin) {
        let key = ObjectIdentifier(plugin)
        guard var slot = slots[key] else { return }
        slot.timer?.cancel()
        slot.timer = nil
        slots[key] = slot
    }
}
```

- [ ] **Step 5: Fix the existing scheduler helper**

The existing `makeTestScheduler()` in `SystemBarSchedulerTests.swift` still compiles (every new parameter has a default), but it would observe the real `NSWorkspace` center. Change it to:

```swift
    private static func makeTestScheduler() -> PluginScheduler {
        PluginScheduler(minimumRefreshInterval: 0.01, wakeNotifications: NotificationCenter(), log: { _ in })
    }
```

- [ ] **Step 6: Run the tests**

Run the test command. Expected: green, including the five new tests and every existing scheduler test (a tab that declares nothing behaves as before: `TickingTab` and `SlowTickingTab` get the protocol default).

- [ ] **Step 7: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 add Sources/Host/PluginScheduler.swift TestFakes.swift SystemBarSchedulerTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 commit -F - <<'EOF'
Keep collecting a tab that declares a backgroundInterval while it is hidden

The scheduler gains a slow timer per declaring plugin on the same serial queue as its fast
one: started at launch by start(_:), swapped for the fast timer by show, swapped back by hide
or by another tab being shown. The two never overlap because the queue is serial. Nothing
runs for a tab that declares nothing, as before.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 3: The background clamp

**Files:**
- Modify: `SystemBarSchedulerTests.swift` (`runAll` and after the Task 2 tests)

The clamp exists since Task 2; this task pins its floor, its logging and its reported form.

- [ ] **Step 1: Write the failing test**

In `runAll()`, after `testSchedulerNeverOverlapsABackgroundCollectWithTheFirstForegroundTick()`, add:

```swift
        testSchedulerClampsABadBackgroundInterval()
```

After `testSchedulerNeverOverlapsABackgroundCollectWithTheFirstForegroundTick`, add:

```swift
    private static func testSchedulerClampsABadBackgroundInterval() {
        let log = LogRecorder()
        let scheduler = PluginScheduler(wakeNotifications: NotificationCenter(), log: { log.record($0) })
        for tooShort in [0, -1, .nan, 1, 4.9] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveBackgroundInterval(tooShort, identifier: "test")
            expect(effective == PluginScheduler.minimumBackgroundInterval,
                   "a backgroundInterval of \(tooShort) must be clamped to 5 seconds, got \(effective)")
            expect(log.count == before + 1, "clamping a backgroundInterval of \(tooShort) must log exactly once, got \(log.count - before) messages")
            expect((log.messages.last ?? "").contains("backgroundInterval"), "the clamp log names backgroundInterval, got: \(log.messages.last ?? "")")
        }
        for tooLong in [.infinity, 1e12, 86_401] as [TimeInterval] {
            let effective = scheduler.effectiveBackgroundInterval(tooLong, identifier: "test")
            expect(effective == PluginScheduler.maximumRefreshInterval,
                   "a backgroundInterval of \(tooLong) must be clamped to one day, got \(effective)")
        }
        for ok in [5, 60, 900, 86_400] as [TimeInterval] {
            let before = log.count
            let effective = scheduler.effectiveBackgroundInterval(ok, identifier: "test")
            expect(effective == ok, "a sane backgroundInterval of \(ok) must pass through unchanged")
            expect(log.count == before, "a sane backgroundInterval of \(ok) must not log, got \(log.count - before) messages")
        }
        expect(PluginScheduler.reportedBackgroundInterval(1) == 5, "the reported cadence is the clamped one, got \(PluginScheduler.reportedBackgroundInterval(1))")
        expect(PluginScheduler.reportedBackgroundInterval(60) == 60, "a sane cadence is reported as declared")
        expect(PluginScheduler.minimumBackgroundInterval == 5, "the background floor the README documents is 5 seconds")
        expect(PluginScheduler.backgroundSettleAfterWake == 120, "the settle the README documents is 120 seconds")
    }
```

- [ ] **Step 2: Run the tests**

Run the test command. Expected: green. (If the clamp were wrong this would be the first red line; the implementation landed in Task 2, so this test documents and pins it. If it fails, fix `clamp` or the statics in `PluginScheduler.swift`, never the expected numbers: 5 and 120 are the spec's.)

- [ ] **Step 3: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 add SystemBarSchedulerTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 commit -F - <<'EOF'
Pin the background interval's floor, ceiling, logging and reported form

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 4: The wake settle

**Files:**
- Modify: `SystemBarSchedulerTests.swift` (`runAll` and after the Task 3 test)

The observer landed in Task 2; these tests prove it does what the spec says, using the scheduler's own `NotificationCenter`.

- [ ] **Step 1: Write the failing tests**

In `runAll()`, after `testSchedulerClampsABadBackgroundInterval()`, add:

```swift
        testSchedulerSettlesBackgroundTimersAfterAWake()
        testSchedulerLeavesTheShownTabAloneAfterAWake()
```

After `testSchedulerClampsABadBackgroundInterval`, add:

```swift
    private static func testSchedulerSettlesBackgroundTimersAfterAWake() {
        let center = NotificationCenter()
        let plugin = BackgroundTab(refresh: 0.02, background: 0.05)
        let scheduler = PluginScheduler(
            minimumRefreshInterval: 0.01,
            minimumBackgroundInterval: 0.01,
            settleAfterWake: 0.3,
            wakeNotifications: center,
            log: { _ in }
        )
        scheduler.start([plugin])
        waitUntil { plugin.count >= 2 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        spinRunLoop(for: 0.02)
        let atWake = plugin.count
        spinRunLoop(for: 0.15)
        // One tick may have been dispatched before the restart cancelled the old timer.
        expect(plugin.count <= atWake + 1, "after a wake, no background tick runs until the settle passes, got \(plugin.count - atWake) in half the settle")
        waitUntil(2) { plugin.count > atWake }
        expect(plugin.count > atWake, "after the settle, the background cadence resumes")

        // The screens waking is the other signal the real app hears.
        let beforeScreens = plugin.count
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        spinRunLoop(for: 0.15)
        expect(plugin.count <= beforeScreens + 1, "screensDidWake also restarts the timer with a settle, got \(plugin.count - beforeScreens) ticks in half the settle")
    }

    private static func testSchedulerLeavesTheShownTabAloneAfterAWake() {
        let center = NotificationCenter()
        let plugin = BackgroundTab(refresh: 0.02, background: 0.05)
        let scheduler = PluginScheduler(
            minimumRefreshInterval: 0.01,
            minimumBackgroundInterval: 0.01,
            settleAfterWake: 0.3,
            wakeNotifications: center,
            log: { _ in }
        )
        scheduler.start([plugin])
        scheduler.show(plugin)
        waitUntil { plugin.count >= 2 }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let atWake = plugin.count
        waitUntil { plugin.count >= atWake + 3 }
        expect(plugin.count >= atWake + 3, "a wake does not touch the shown tab's fast timer, got \(plugin.count - atWake) ticks")
        scheduler.hide()
    }
```

- [ ] **Step 2: Run the tests**

Run the test command. Expected: green. If `testSchedulerSettlesBackgroundTimersAfterAWake` fails on its first expectation, the observer is not firing: check that `observeWakes()` is called from `init` and that the handler hops to the main actor with `Task { @MainActor in ... }`, since `settleBackgroundTimersAfterWake` is main-actor isolated.

- [ ] **Step 3: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 add SystemBarSchedulerTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 commit -F - <<'EOF'
Prove background timers wait out the settle after a wake, and the shown tab does not

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 5: The app starts the slow timers, and `--list-plugins` says so

**Files:**
- Modify: `SystemBarLoaderTests.swift:20` (`runAll`) and after `testListReportPrintsOneLinePerEntry` (line ~157)
- Modify: `Sources/Host/PluginListReport.swift` (whole file)
- Modify: `Sources/Host/App.swift:24-38`

- [ ] **Step 1: Write the failing test**

In `SystemBarLoaderTests.swift`, in `runAll()`, after `testListReportPrintsOneLinePerEntry()`, add:

```swift
        testListReportSaysWhichPluginsSampleInTheBackground()
```

After the `testListReportPrintsOneLinePerEntry` function, add:

```swift
    private static func testListReportSaysWhichPluginsSampleInTheBackground() {
        let tabs: [LoadedTab] = [
            .loaded(location: "quiet", plugin: BackgroundTab(refresh: 5, background: nil)),
            .loaded(location: "minute", plugin: BackgroundTab(refresh: 5, background: 60)),
            .loaded(location: "eager", plugin: BackgroundTab(refresh: 5, background: 1)),
            .loaded(location: "half", plugin: BackgroundTab(refresh: 5, background: 7.5)),
        ]
        let lines = PluginListReport.lines(for: tabs)
        expect(lines == [
            "ok background Background quiet",
            "ok background Background minute background every 60s",
            "ok background Background eager background every 5s",
            "ok background Background half background every 7.5s",
        ], "--list-plugins appends the clamped background cadence to a declaring plugin's line, got \(lines)")
    }
```

- [ ] **Step 2: Run the tests to see it fail**

Run the test command. Expected: `FAIL: --list-plugins appends the clamped background cadence ...` with the four plain `ok` lines.

- [ ] **Step 3: Extend the report**

Replace the whole of `Sources/Host/PluginListReport.swift` with:

```swift
import Foundation

/// What `SystemBar --list-plugins` prints: the loader's outcome, one line per enabled entry,
/// so the real loading path can be checked from a script. A plugin that samples while hidden
/// says so on its line, with the cadence the scheduler would actually run, so "the app does
/// nothing while closed except X" can be checked the same way.
enum PluginListReport {
    static func lines(for tabs: [LoadedTab]) -> [String] {
        tabs.map { tab in
            switch tab {
            case let .loaded(location, plugin):
                return "ok \(type(of: plugin).identifier) \(plugin.title) \(location)" + backgroundSuffix(for: plugin)
            case let .failed(location, reason):
                return "error \(location): \(reason)"
            }
        }
    }

    private static func backgroundSuffix(for plugin: TabPlugin) -> String {
        guard let declared = plugin.backgroundInterval else { return "" }
        return " background every \(seconds(PluginScheduler.reportedBackgroundInterval(declared)))s"
    }

    /// `60`, not `60.0`, for a whole number of seconds; one decimal otherwise.
    private static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? String(Int(interval)) : String(format: "%.1f", interval)
    }
}
```

Add `import SystemBarKit` under `import Foundation` at the top of the file, since `TabPlugin` is an SDK type.

- [ ] **Step 4: Start the timers at launch**

In `Sources/Host/App.swift`, the `init()` currently reads (lines 16-38):

```swift
    init() {
        let store = PluginConfigStore.standard()
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            processes: processes,
            fastStats: fastStats,
            runner: ProcessRunner.run,
            log: { NSLog("%@", $0) }
        )
        presenter = TabPresenter(
            scheduler: PluginScheduler(),
            samplers: HostSamplers.standard(processes: processes, fastStats: fastStats)
        )
        let source = BundleTabSource.standard()
        let loaded = TabLoader.load(store: store, source: source, host: host)
        tabs = loaded
        configPath = store.fileURL.path

        // `SystemBar --list-plugins` is the loader as a command: it reports what the window
        // would show, then exits without one. test.sh uses it to check the real loader.
        if CommandLine.arguments.contains("--list-plugins") {
            PluginListReport.lines(for: loaded).forEach { print($0) }
            exit(0)
        }
    }
```

Change it so the scheduler is named and started after the `--list-plugins` exit (the report must not start timers, and a plugin's background work must not begin before the loader has finished). If the Disk session's commits have changed how `HostServices` or `TabLoader.load` are called here, keep their form and change only the three lines marked:

```swift
    init() {
        let store = PluginConfigStore.standard()
        let host = HostServices(
            homeDirectory: NSHomeDirectory(),
            processes: processes,
            fastStats: fastStats,
            runner: ProcessRunner.run,
            log: { NSLog("%@", $0) }
        )
        let scheduler = PluginScheduler()                                   // changed: named
        presenter = TabPresenter(
            scheduler: scheduler,                                           // changed
            samplers: HostSamplers.standard(processes: processes, fastStats: fastStats)
        )
        let source = BundleTabSource.standard()
        let loaded = TabLoader.load(store: store, source: source, host: host)
        tabs = loaded
        configPath = store.fileURL.path

        // `SystemBar --list-plugins` is the loader as a command: it reports what the window
        // would show, then exits without one. test.sh uses it to check the real loader.
        if CommandLine.arguments.contains("--list-plugins") {
            PluginListReport.lines(for: loaded).forEach { print($0) }
            exit(0)
        }

        // A plugin that declared a backgroundInterval starts sampling now, window or no window.
        scheduler.start(loaded.compactMap(\.plugin))                        // added
    }
```

- [ ] **Step 5: Run the tests**

Run the test command. Expected: green, and the boundary and fresh-file checks still pass unchanged, since no shipped plugin declares a background interval yet.

- [ ] **Step 6: Check the real app by hand**

```bash
/Users/adamu/proj/swift-ui-system-monitor-ewy.1/SystemBar.app/Contents/MacOS/SystemBar --list-plugins
```

Expected: six `ok` lines with no suffix.

- [ ] **Step 7: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 add Sources/Host/PluginListReport.swift Sources/Host/App.swift SystemBarLoaderTests.swift
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 commit -F - <<'EOF'
Start background timers at launch, and let --list-plugins report the cadence

The suffix is "background every <n>s" with the clamped value, so a script can check what the
app runs while closed without opening the window.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/one-page/systembar-tab-plugins.md:129-135` (after D8), the contract snippet (line ~150), the samplers paragraph (line ~216), and the Decision Log (end of file)
- Modify: `README.md:41`, `58-65`, `144`, `168-178`, and the clamp paragraph in "Writing a plugin" (line ~86)

- [ ] **Step 1: Add D9 to the plugin spec**

In `docs/one-page/systembar-tab-plugins.md`, after the D8 section (which ends `...so the first run looks exactly like today.`) and before `## Plugin Contract`, add:

```markdown
### D9: May a plugin sample while its tab is hidden?

Decided 2026-10-10 in `systembar-ewy-cpu-machine-state-and-background-sampling.md`
(D2, D3, D7) and adopted by `systembar-ifd-disk-distribution-and-movers.md`.

- **Option A — yes, by declaring a `backgroundInterval`:** nil by default; the
  host keeps calling `collect()` at that cadence while the tab is not showing,
  with a 5-second floor, and restarts every background timer two minutes after
  the Mac wakes. Shared feeds stay visible-only.
- **Option B — never:** the guarantee D5 relied on, kept absolute.
- **Option C — a host-sampled background feed:** the host does the hidden work
  and plugins read it.

**Selected: A.** Two tabs need a memory of what normal looks like (the CPU
tab's movers, the Disk tab's size ledger), and a memory that fills only while
someone is looking is not one. The guarantee becomes opt-in per plugin, each
opt-in is reported by `--list-plugins` and named in the README, and nothing
changes for a plugin that declares nothing.
```

- [ ] **Step 2: Update the contract snippet**

In the same file, inside the `public protocol TabPlugin` code block under `## Plugin Contract`, after the lines

```swift
    /// Which shared samplers must be running while this tab is showing.
    var sharedFeeds: Set<SharedFeed> { get }
```

add:

```swift
    /// How often the host calls collect() while this tab is NOT showing. Nil (the
    /// default) means never. Clamped to 5s...86,400s. Shared feeds do not run for a
    /// hidden tab. The first tick after the Mac wakes waits 120s.
    var backgroundInterval: TimeInterval? { get }
```

- [ ] **Step 3: Update the samplers paragraph**

Replace the sentence `With the window closed, or an error tab showing, neither runs.` (in the paragraph beginning `The host runs two shared samplers of its own`) with:

```markdown
With the window closed, or an error tab showing, neither runs; the only work
that does is the `collect()` of a plugin that declared a `backgroundInterval`
(D9), on its own queue, at that cadence.
```

- [ ] **Step 4: Add the decision-log line**

At the end of the file's `## Decision Log` list, add:

```markdown
- 2026-10-10 — D9: chose A — a plugin may declare a `backgroundInterval`; the
  window-closed guarantee is opt-out per plugin, reported by `--list-plugins`
  — Adam, through the CPU and Disk epics.
```

- [ ] **Step 5: README, the feeds table's closing line**

In `README.md`, replace the line `Nothing is sampled while the window is closed.` (line 65) with:

```markdown
Nothing is sampled while the window is closed, unless a plugin declares a `backgroundInterval`: then the app keeps calling that plugin's `collect()` at that cadence while its tab is hidden, on the plugin's own queue, with a floor of 5 seconds. The first such call after the Mac wakes waits two minutes, so nothing lands on the login moment. The shared feeds never run for a hidden tab. The table below says which tabs sample while hidden; `--list-plugins` reports it too, as `background every <n>s` on that plugin's line.
```

- [ ] **Step 6: README, the per-tab table**

Replace the table at lines 170-177 with one that has a fourth column. Every row says `—` in this stage; the CPU row changes in Stage 3 and the Disk row in the Disk epic.

```markdown
| Tab | Its own sampling | While hidden | Where the number lives |
|---|---|---|---|
| Power | `pmset` every 60s | — | `PowerPlugin.refreshInterval` |
| Dev | `ps`, `lsof`, `pmset` and two usage reads a second apart, every 60s | — | `DevSampling` in `Plugins/Dev/Sources/CapacityModels.swift` |
| Memory | Kernel counters and pressure level every 3s; `ioreg` every 30s | — | `MemorySampling` in `Plugins/Memory/Sources/MemoryModels.swift` |
| Disk | Volumes and `tmutil` every 30s; the `du` scan every 10 min or on demand | — | `DiskSampling` in `Plugins/Disk/Sources/DiskModels.swift` |
| Network | `nettop` and `lsof` every 30s; `networkQuality` only on the button | — | `NetworkSampling` in `Plugins/Network/Sources/NetworkModels.swift` |
| CPU | Nothing of its own: everything it shows comes from the two shared feeds | — | `CPUPlugin.refreshInterval` (one day, so its empty collect almost never runs) |
```

- [ ] **Step 7: README, the commands sentence**

At line 144, replace the sentence `Every command below starts only while the window is open, and only while the tab that needs it is showing (a `du` scan or speed test already under way finishes even if you switch away).` with:

```markdown
Every command below starts only while the tab that needs it is showing (a `du` scan or speed test already under way finishes even if you switch away), except where the "While hidden" column of the table further down says a tab keeps sampling with the window closed.
```

- [ ] **Step 8: README, the writing-a-plugin paragraph and the list-plugins sentence**

In the "Writing a plugin" section, after the paragraph beginning `A plugin's `refreshInterval` is clamped to between 0.25 seconds and one day`, add a new paragraph:

```markdown
A plugin that needs to keep sampling while its tab is hidden declares `backgroundInterval` (nil by default). The app then calls its `collect()` at that cadence, clamped to between 5 seconds and one day, while the window is closed or another tab is showing, and waits two minutes after the Mac wakes before the first such call. It is the same `collect()`; a plugin that wants to do less while hidden keeps a flag from `visibilityChanged(isVisible:)`. Shared feeds do not run for a hidden tab, so a background `collect()` samples for itself. Say in your plugin's README what it runs while hidden and how often; the app reports the cadence in `--list-plugins`.
```

In the paragraph at line 41 beginning `./SystemBar.app/Contents/MacOS/SystemBar --list-plugins` prints the same outcome`, after the sentence ending `not a resolved path.`, add:

```markdown
A plugin that samples while hidden has `background every <n>s` at the end of its line.
```

- [ ] **Step 9: Check the docs render and the tests still pass**

Run the test command (the README is not tested, but the commit should sit on a green tree). Then read the README's two tables once in a Markdown preview or `cat` to be sure the column counts match in every row.

- [ ] **Step 10: Commit**

```bash
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 add README.md docs/one-page/systembar-tab-plugins.md
git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 commit -F - <<'EOF'
Document background sampling: D9 in the plugin spec and the README's hidden column

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 7: Review, close, hand off

**Files:** none new.

- [ ] **Step 1: Full test run**

Run the test command once more on the final tree. Expected: green.

- [ ] **Step 2: Code review**

Use the `code-reviewer` agent on `git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 diff main...ewy.1-background-sampling`. Fix anything HIGH or above, re-run the tests, and commit the fix with a named path.

- [ ] **Step 3: Release the lease and close the issue**

```bash
mc resource release LEASE --issue=swift-ui-system-monitor-ewy.1 --reason=done
bd close swift-ui-system-monitor-ewy.1 --reason="backgroundInterval, slow timer, clamp, wake settle, --list-plugins suffix, D9 and README on branch ewy.1-background-sampling"
```

- [ ] **Step 4: Hand off**

Report: the branch name and its commits (`git -C /Users/adamu/proj/swift-ui-system-monitor-ewy.1 log --oneline main..ewy.1-background-sampling`), that the tests passed, and that merging to `main` waits for the user's word. Tell the Disk session (via SendMessage to `swift-ui-system-monitor-d9`) that Stage 1 is on that branch and what the final names are, so its Stage 1 can build on it.
