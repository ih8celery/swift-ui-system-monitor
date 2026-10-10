# The CPU tab shows the machine's state and what is odd, and plugins may sample while hidden

- **Date:** 2026-10-10
- **Epic:** swift-ui-system-monitor-ewy
- **Status:** approved 2026-10-10

## Goal

Make the CPU tab answer two questions its owner actually has: "my Mac is slow
or hot right now, why?" and "is something quietly burning in the background?"

Today the tab's right half is a top-process list. It never answers either
question, for four reasons that stack. Its number per row is `ps`'s CPU
column, which is smoothed over roughly the last minute, so a daemon ticking at
3% all week outranks a build that started ten seconds ago. Rows are grouped by
executable name, so Chrome is four helper rows and Xcode is several compiler
rows. The top of the list is always the same system baseline: kernel_task,
WindowServer, Spotlight, which is the machine breathing rather than
information. And the sub-value under each row is memory, which is the Memory
tab's job.

After this change the left column keeps the headline percent and its history
and gains the machine's state: load per core cluster, user against system
time, load average against core count, and thermal state. The right column is
a scrolling stack of cards that say what is odd right now: a process that has
run away, processes that have moved away from their own normal, and processes
that wake the chip too often. The old list is gone; the drill-in it opened
stays, reached from any card.

"Normal" needs a memory of what each process usually does, and that memory
must fill while the window is closed, so the SDK gains an opt-in way for a
plugin to sample in the background. Other plugins will use it; it is a
contract, documented like the rest.

## What Probing Against the Real Machine Showed

Every mechanism was tried on the development Mac before this was written.

| Question | Result |
|---|---|
| Can the kernel's per-process usage call read root daemons? | No. `proc_pid_rusage` returns `EPERM` for WindowServer, coreaudiod and launchd. The Dev tab gets away with it because it only asks about the owner's own processes |
| Can `top` see them? | Yes. `top -l 2 -s 1 -c d -stats pid,ppid,cpu,idlew` reports true CPU over the last second and idle wake-ups per process, for every process, as an ordinary user |
| What does one `top` sample cost? | 1.4 s wall, 0.42 s CPU, 9 MB, across 1,050 processes. Once a minute that is under one percent of one core |
| Does `top` give usable names? | No. Its command column is cut at sixteen characters (`AppleCentauriAlp`). `proc_pidpath` returns the full executable path for any pid, root's included, so the name is the path's file name, as `ProcessTable` already defines it |
| What are idle wake-ups? | Each time a process pokes a sleeping core awake for a tiny job. Measured over two seconds: superwhisper 22/s, kernel_task 17/s, WindowServer 9/s, ghostty 3/s. A misbehaving process shows hundreds or thousands |
| How does this chip report its cores? | Not as P and E. `hw.nperflevels` is 2, `hw.perflevel0.name` is `Super` (6 cores) and `hw.perflevel1.name` is `Performance` (12 cores). Cluster names and counts must come from sysctl, never from code. Which core numbers belong to which cluster is not reported and needs a spike |
| Does the host already read per-core ticks? | Yes. `FastStatsSampler` calls `host_processor_info` and sums user, system, nice and idle across cores every second, then publishes only the total |

## Decisions

### D1: What replaces the top-process list?

- **Option A — machine state on the left, anomaly cards on the right:** the
  left column says what state the machine is in; the right column says what is
  odd. Nothing is listed because it is big.
- **Option B — a better list:** true per-second CPU, grouped by app, system
  baseline folded into one row. Still a ranking by size.
- **Option C — per-app grouping only.**

**Selected: A.** A ranking by size answers "what is big", which is wallpaper
on a quiet machine. Change and abnormality are the signals, and the Dev tab
already owns "which of my projects is using the machine".

### D2: Where does "normal" come from?

- **Option A — learned fresh each time the window opens:** no state, honest,
  but blind for the first samples and never more than minutes old.
- **Option B — learned only while the window is open, remembered on disk:** no
  background cost, but a tab opened for ten seconds a day never learns much.
- **Option C — sampled in the background while the window is closed:** the
  fullest baseline. It ends the "nothing runs while closed" guarantee, on
  purpose, for the plugins that ask.

**Selected: C.** The baseline is only worth having if it is there when the
window opens.

### D3: How does a plugin sample while hidden?

- **Option A — a plugin opt-in:** `TabPlugin` gains `backgroundInterval`, nil
  by default; the host keeps calling `collect()` at that cadence while the tab
  is not showing. Small, general, and the host never learns what the plugin
  does with it.
- **Option B — a new shared feed of per-process activity, sampled by the host
  in the background:** more public surface, a host sampler and feed tests, paid
  for only when a second tab needs the same data.

**Selected: A.** Other plugins will want background sampling for their own
reasons (the Power epic's keep-awake, for one), and most of them will not
want this tab's data. If two tabs ever need per-process activity, the sampler
written here moves into the SDK, as `ProcessTable` did.

### D4: Which reading is the per-process truth?

- **Option A — `top` in delta mode:** true CPU over the last second and
  wake-ups, for every process. 0.42 s of CPU per sample.
- **Option B — `proc_pid_rusage`:** free, but refused for every root daemon,
  which is most of the system baseline.
- **Option C — `ps`:** nearly free, but its CPU column is the smoothed figure
  that makes the current list dull, and it has no wake-ups.

**Selected: A.** Names come from `proc_pidpath`, not `top`.

### D5: Where do the per-cluster and user/system numbers come from?

- **Option A — added to the fast feed:** `FastStatsSnapshot` gains per-core
  usage and user/system/idle shares. The sampler already has them. The
  cluster bars then match the headline to the sample, and any tab can use
  them. Additive public API, which the SDK rule allows.
- **Option B — the CPU plugin reads the kernel itself every second:** twenty
  lines copied from the host, and two readers of the same counters.

**Selected: A.**

### D6: Does the baseline survive a relaunch?

- **Option A — written to disk:** a JSON file beside `plugins.json`, written
  every five minutes, read on the first collect. A relaunch during development
  keeps its memory.
- **Option B — memory only:** refills within an hour or two, but every rebuild
  empties it, and the app is rebuilt often.

**Selected: A.**

### D7: One `collect()` or a second background method?

- **Option A — the same `collect()` at two cadences:** a plugin that wants to
  do less while hidden already hears `visibilityChanged` and keeps a flag.
- **Option B — a `collectInBackground()` method.**

**Selected: A.** One method, one queue, nothing new to explain.

## SDK Contract

```swift
public protocol TabPlugin: AnyObject {
    // ... everything as today, plus:

    /// How often the host calls `collect()` while this tab is NOT showing: the window closed,
    /// or open on another tab. Nil, the default, means never: the tab samples only while it is
    /// on screen, as every tab did before this existed. A number is clamped to between 5 seconds
    /// and one day, and each substitution is logged. Shared feeds do not run for a hidden tab,
    /// so a `collect()` that runs in the background samples for itself; a feed value read then
    /// is whatever the feed last held. After the Mac wakes, the first background tick waits
    /// `PluginScheduler.backgroundSettleAfterWake` so no sample lands on the login moment.
    /// Declare one only for work the person wants done while they are not looking, and say
    /// in the README what runs and how often.
    var backgroundInterval: TimeInterval? { get }
}

public extension TabPlugin {
    var backgroundInterval: TimeInterval? { nil }
}
```

The scheduler's rules, in addition to today's:

- At launch, every loaded plugin with a background interval gets its slow
  timer started on its own serial queue, first tick one interval after launch.
- `show(plugin)` cancels that plugin's slow timer and starts the fast one on
  the same queue, immediately, as today. The queue is serial, so a background
  collect still running finishes before the first foreground tick.
- `hide()` and showing a different plugin cancel the fast timer and, if the
  plugin declares a background interval, start the slow one with its first
  tick one interval later, since the tab was collected a moment ago.
- `PluginScheduler.minimumBackgroundInterval` is 5 seconds;
  `maximumRefreshInterval` is the ceiling for both.
- After the Mac wakes (`NSWorkspace.didWakeNotification` or
  `screensDidWakeNotification`), every background timer is restarted with its
  first tick `PluginScheduler.backgroundSettleAfterWake` (120 seconds) later.
  A Dispatch timer that missed its deadline during sleep fires the instant
  the Mac wakes, which would land a `top` sample, or a disk scan, on the
  login moment. The shown tab's fast timer is left alone.
- The host's shared samplers are unchanged: they run only while the window is
  open, and the process sampler only while the showing tab declares it.

`--list-plugins` appends `background every <n>s` to the line of a plugin that
declares one, so the cadence can be checked from a script without opening the
window.

Documentation that changes with it: the doc comment above (the shipped
`.swiftdoc` is what a plugin author reads); a D9 in
`systembar-tab-plugins.md` recording that the window-closed guarantee is now
opt-in per plugin; the README's feeds table, whose closing line becomes
"Nothing is sampled while the window is closed unless a plugin declares a
background interval; the table below says which do"; and a "While hidden"
column in the README's per-tab sampling table. `Examples/HelloTab` declares
nothing, so the smallest plugin still shows the default.

`FastStatsSnapshot` gains, all additive:

```swift
/// Share of the last second each logical core spent busy, 0 to 100, in the kernel's core order.
public var perCoreUsage: [Double] = []
/// Share of the last second all cores together spent in user code, and in the kernel. The two
/// sum to `cpuUsagePercent`, give or take rounding; the rest of the second was idle.
public var cpuUserPercent: Double = 0
public var cpuSystemPercent: Double = 0
```

## CPU Tab Contract

**Declarations.** `refreshInterval` 10 seconds, `backgroundInterval` 60
seconds, `sharedFeeds` `[.fastStats]` only: the tab stops declaring
`.processes`. Both cadences, the window length, the file write interval and
every threshold below live in `CPUSampling` and `CPURules` enums beside the
models, as named constants.

**Each collect, hidden or showing:** run `top -l 2 -s 1 -c d -stats
pid,ppid,cpu,idlew` through `host.run`; the second sample's rows are the
reading. Name each pid by the file name of `proc_pidpath`, falling back to
`top`'s own name when the path cannot be read (pid 0). Convert `top`'s
per-core percent to a share of the whole machine with `ProcessCPUScale`, as
the current list does. Then append one reading per process name to the
baseline, run the rules, and publish. While showing, also read the thermal
speed limit from `pmset -g therm` so the thermal line can say by how much.
Thermal state itself comes from `ProcessInfo.thermalState` and its
notification, which cost nothing.

**The baseline.** Per process name, the last 120 readings of machine share
and wake-ups per second, each with a timestamp. 120 readings, not two hours
of wall clock, so an overnight sleep does not empty it. A name absent for 120
consecutive samples is dropped. It is written as JSON to
`cpu-baseline.json` inside `host.dataDirectory`, the per-plugin folder under
Application Support that the Disk epic (ifd) adds to `HostServices`, every
five minutes, with a `version` field, and read on the first collect
rather than in `init`, which must stay under 100 ms. A file that will not
parse, or has a version this build does not know, is logged and replaced by
an empty baseline: the app wrote it, so unlike `plugins.json` it is not the
person's text to correct. Tests point `dataDirectory` at a temporary folder,
and never touch the real Application Support.

**The rules.** Initial values, tuned against real readings in Stage 3 and
kept as named constants:

- *Runaway:* a single pid whose share of one core was 90% or more in every
  reading of the last three minutes, with at least three readings. Shown by
  name and pid, with its duration and the classifier's "Likely:" label.
- *Mover, rising:* a name whose current machine share is at least 3 points
  and at least twice the median of its baseline.
- *Mover, falling:* a name whose baseline median is at least 3 points and
  whose current share is at most half of it.
- *Mover, new:* a name with no baseline and a current share of at least 3
  points.
- *Chatterer:* a name at 50 or more wake-ups per second, ranked by rate.

**The layout.** The left column is 300 points wide as today:

```
 42% CPU                      | Runaway                        (only when one exists)
 [sparkline, 90 s]            |   mds_stores  pid 311  12 min  Likely: macOS system service
                              | Movers                         (quiet: "Nothing has moved")
 Super        ▮▮▮▮▮▮  48%     |   swift-frontend  new    31%   ▁▂▇
 Performance  ▮▮▮▮▮▮  12%     |   Google Chrome   ▲ 2% → 18%   ▁▁▂▆
 user ████████░░ system       |   WindowServer    ▼ 9% → 2%    ▆▅▂▁
 load 6.2 of 18 cores         | Wake-ups                       (quiet: "Nothing is chattering")
 thermal: fair, 80% speed     |   superwhisper   120/s
 (hidden while nominal)       |   kernel_task     60/s
```

One bar per cluster, labelled with the name and core count from sysctl. Which
core indices belong to which cluster is settled by a spike in Stage 2: pin a
thread with a background QoS and a thread with user-interactive QoS and watch
which `perCoreUsage` entries rise. If the ordering cannot be confirmed, the
fallback is one row of small per-core bars with no cluster names. The right
column scrolls; each card is its own view with its own quiet state; tapping
any process row opens `ProcessDetailView` and `ProcessClassifier` as today.

## Expected Outcomes

- With the window closed, SystemBar runs one `top` a minute and nothing else,
  and `--list-plugins` says so.
- A tab that declares nothing behaves exactly as before, and a bundle built
  against the previous SDK still loads.
- Opening the CPU tab an hour after launch shows movers against a real
  baseline; opening it after a relaunch shows the baseline it had.
- A process pinned at a core for three minutes appears at the top of the
  right column, with a guess at what it is.
- The README names every command and cadence the tab runs, hidden and showing.

## Non-Goals

- No shared feeds in the background. A hidden tab samples for itself.
- No per-project attribution here; that is the Dev tab's.
- No energy or power figures; the Power epic owns those.
- No history older than 120 readings per process, and no graphs of the
  baseline beyond a row's sparkline.
- No change to the other five tabs.

## Issue Map

Epic swift-ui-system-monitor-ewy, three stage issues, each leaving a working,
buildable, tested app with something new on screen or in `--list-plugins`:

1. **Background sampling in the SDK.** `backgroundInterval`, the scheduler's
   slow timer, its clamp, the wake settle, `--list-plugins` reporting it,
   scheduler tests, the doc comment, D9 in the plugin spec, and the README's
   two tables. The Disk epic's Stage 1 adopts this contract and waits for it.
2. **The left column.** The fast feed's three new fields and their sampler
   tests, the cluster spike, and the machine-state views under the history.
3. **The right column.** The `top` sampler and its parser, naming by path,
   the baseline and its file in `host.dataDirectory`, the rules and their
   tests, the three cards, and the README's `top` row and CPU line. Waits for
   the Disk epic's `dataDirectory` task.

## Decision Log

- 2026-10-10 — D1: chose A — machine state and anomaly cards, not a better
  list — Adam.
- 2026-10-10 — D2: chose C — sample in the background, ending the
  window-closed guarantee for plugins that ask — Adam.
- 2026-10-10 — D3: chose A — a plugin opt-in, documented, because other
  plugins will sample in the background too — Adam.
- 2026-10-10 — D4: chose A — `top` in delta mode, after `proc_pid_rusage` was
  refused for root daemons on the development Mac — Claude, proposed.
- 2026-10-10 — D5: chose A — per-core and user/system shares join the fast
  feed — Claude, proposed.
- 2026-10-10 — D6: chose A — the baseline is written to disk — Adam.
- 2026-10-10 — D7: chose A — one `collect()` at two cadences — Claude,
  proposed.
- 2026-10-10 — The Disk epic (ifd) drops its own background-tick design and
  adopts this contract, adding the 120-second settle after wake from its D2;
  this epic's baseline file moves into the `host.dataDirectory` that ifd
  adds. Agreed between the two sessions, for Adam to confirm.
