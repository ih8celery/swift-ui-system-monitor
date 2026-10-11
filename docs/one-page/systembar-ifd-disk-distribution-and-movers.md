# Disk tab: space distribution, movers, and a saved size ledger

- **Date:** 2026-10-10
- **Epic:** swift-ui-system-monitor-ifd
- **Status:** design approved in conversation 2026-10-10; spec awaiting review

## Goal

Make the Disk tab answer two questions a developer actually asks: where has the
space gone, and what changed recently. Today it answers neither. It shows a
list headed "Reclaimable Space" that measures a fixed set of 16 folders someone
judged safe to delete, drops any folder whose walk takes longer than 45 seconds,
and keeps nothing between scans. The word "cleanup" and the per-row hints go
away. What replaces them is a distribution of the disk on the left and a ranked
list of the biggest users and the biggest movers on the right, read from a size
ledger that survives between scans and shows the age of every number.

## Every Mechanism Was Verified First

Measured on the author's Mac on 2026-10-10 before the design was drawn.

| Question | How it was checked | Result |
|---|---|---|
| Are the capacity figures right? | `URLResourceValues` for `/` and `/System/Volumes/Data` against `diskutil` | Both volumes report the container: 994.6 GB total, 218.5 GB free, 231.8 GB available for important usage. Accurate. |
| Why is DerivedData the top row? | timed `du -sk -x ~/Library/Developer/CoreSimulator` | 256.6 GB, 53 s. The per-path cap is 45 s, so the row is dropped and only the footer says "1 too slow to finish". DerivedData, 7.9 GB, is the biggest row left. |
| Is the simulator hint right? | `xcrun simctl list devices -j` | 130 devices, all on iOS 26.5, all "available", 4 never booted, oldest boot 2026-09-18. "delete unavailable" would free nothing. |
| What are the real top users? | `du -kx -d1` on home, Library, Developer and the Data volume | CoreSimulator 256.6, Application Support 84.8, proj 83.7, .cache 43.4, /Applications 30.8, .ollama 24.9, Music 20.7, /opt 20.3 GB. One of eight is on the current list. |
| What does a wider walk cost? | timed `du -kx -d1 ~`, `-d2 ~/Library`, `-d1 ~/proj`, warm cache | 110 s, 61 s, 32 s. |
| Can Spotlight find big recent files cheaply? | `mdfind` with size and change-date predicates | 1 s for home, but 0 hits under Library/Developer and Library/Caches: Spotlight does not index them. Not a substitute for a walk. |

Two findings shape the design: a shallow walk of the folders that matter costs
minutes, not seconds, so it cannot run on the 30-second tick and its results
must be saved; and a single per-path timeout silently hides the biggest answer,
so a slow tree must be split (simulators per device) rather than capped.

## Decisions

### D1: What is the tab for?

- **Option A, a map of where the space went**, with change over time. Safe-to-delete is not the organising idea.
- **Option B, a correct cleanup list**: keep the framing, fix the simulator measurement, add growth.
- **Option C, both panes.**

**Selected: A.** A ranked map can never miss the biggest thing, and growth over a
day or a week is what tells a developer which cache or simulator set to look
at. The hints and the word "cleanup" are removed. Adam, 2026-10-10.

### D2: When do scans run?

- **Option A, while SystemBar is in the menu bar with the popover closed**, on a cadence, plus the button.
- **Option B, a launchd helper** that runs even when the app is not running.
- **Option C, only while the popover is open**, with results saved.

**Selected: A**, refined to per-plan cadences counted in awake time. Nothing
fires during sleep. Adam, 2026-10-10.

| Plan | Cadence | Typical day |
|---|---|---|
| Overview | 3 hours | first wake, then about three more times |
| Developer | 6 hours | first wake, then once mid-afternoon if still logged in |
| Simulators | 6 hours | right after Developer |

The Disk plugin declares a 15-minute `backgroundInterval` (the CPU epic's SDK
contract, see D6), so the host calls its `collect()` every 15 minutes while the
tab is hidden and every 30 seconds while it shows. Each call reads the volumes
and runs every plan whose newest sample is older than its cadence, one plan at
a time, in the order above, on the plugin's own scan queue. The scheduler
restarts background timers two minutes after the Mac wakes, so a scan never
lands on the login moment. That restart also gives an extra background tick
about two minutes after each wake, which is harmless and wanted: each tick is
only a due check, so it runs a plan only if one is due. Screen unlock is not a
trigger: a wake plus the 15-minute cadence covers the morning, and an unlock
without a sleep is not a moment worth scanning at (agreed with the CPU pane,
2026-10-10). The panel's button runs every plan now. A scan under way when the
popover closes finishes.

### D3: How far does the scan reach?

- **Option A, home two levels plus system roots one level.**
- **Option B, home one level plus system roots.** Library would be one 383 GB lump.
- **Option C, three levels everywhere.** Roughly double the time, mostly noise.

**Selected: a tiered form of A**, because this is a developer's tool and the
developer folders must be visible. Adam, 2026-10-10.

| Plan | Roots, each measured one level deep |
|---|---|
| Overview | `~`, `~/Library`, `/Applications`, `/opt`, `/Library` |
| Developer | `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Developer/Xcode`, `~/.cache`, `~/.ollama`, `~/.android`, `~/proj` |
| Simulators | one row per device from `simctl list devices -j`, sized by `du` on `~/Library/Developer/CoreSimulator/Devices/<udid>`, carrying name, runtime and last boot |

A root that does not exist is skipped silently. A root that exists but cannot
be listed is skipped the same way, and the earlier samples of its children stay
as they were rather than being marked freed. Each plan has its own time budget
and each folder its own `du` with its own timeout, as the current scan does, so
a slow folder costs one row. A row the budget does not reach keeps its previous
value and stamp. The roots, depth, cadences, budgets and timeouts are constants
in `DiskSampling`, and the README's interval table names them.

### D4: Where is the data kept?

A JSON ledger in the plugin's data folder (D6), path overridable for tests,
with a version field. One entry per measurement: path, bytes, measured-at,
plan; simulator entries add udid, device name, runtime and last boot. Writes
are atomic (temporary file, then rename). A plan writes once when it finishes.

Retention: every sample for two days; one per path per day between two and 30
days; nothing older. Compacted on every write. About 400 paths times 36
samples, a few megabytes.

The ledger is a value type. Applying a sample returns a new ledger. Newest per
path, value a day ago, value a week ago, deepest-level and remainder rows, and
movers are pure functions over it.

The plugin loads the ledger at launch, so the panel shows the last scan's
numbers at once, stamped with their age. A file that fails to parse is moved
aside with a `.broken` suffix, the status line says so, and a fresh ledger is
started. Adam, 2026-10-10.

### D5: What does the panel show?

```
┌──────────────────────────────┬──────────────────────────────────┐
│ 218 GB Free                  │ Where it goes    [Biggest|Movers]│
│ [Snapshots 0]                │                  [24h | 7d]      │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░  bar   │ Simulators · 130 devices  257 GB │
│ Used  Free                   │ ████████████████  measured 2h ago│
│                              │ Application Support (rest) 85 GB │
│ Where the space is           │ ██████                  5h ago   │
│ ▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒░░░░░  bar    │ proj (rest)                84 GB │
│ Simulators        257 GB     │ ██████                  2h ago   │
│ App Support        85 GB     │ ...                              │
│ Projects           84 GB     │                                  │
│ Everything else   240 GB     │ Overview 2h · Developer 5h ·     │
│ Free              218 GB     │ Simulators 5h        [rescan ↻]  │
└──────────────────────────────┴──────────────────────────────────┘
```

**Left.** Headline is plain free space. The Purgeable pill and category are
removed: purgeable space is still on the disk, so it counts as used, and the
headline, bar and legend then agree on one number. The capacity bar has two
segments, Used and Free. Below it, a second segmented bar splits the same
capacity into the six biggest measured rows, Everything else, and Free, with
a legend of sizes. Other volumes keep their section. Adam, 2026-10-10.

**Right.** One list, two modes. Biggest ranks every measured row by size.
Movers ranks by absolute change over 24 hours or 7 days, showing the signed
delta and the current size; a row with no earlier sample is marked new only
when its plan had already run before the window began, and is otherwise
silent, so a first scan never lists everything as new; a row whose path has
gone is shown as freed. Movers lists simulator devices individually, while
Biggest shows them as one group. Every row shows name, path, a bar
relative to the top row, and the age of its measurement. The simulator group
shows as one row with a device count, expandable to one row per device with
runtime and last boot; the group row is a button whose chevron turns when it is
open. The footer shows one line beside the rescan button: a problem first if
there is one (a settings value the tab could not use, then a failed save, then
a ledger moved aside), otherwise scan progress while a plan runs, otherwise the
summary of the last scan that did not measure everything, otherwise each plan's
newest sample age.

**Double counting.** Library contains Developer, which contains CoreSimulator.
The list shows the deepest measured level only. A parent appears as its own
row only for the part its measured children do not explain, labelled
"Library (rest)", and only when that remainder ranks among the 25 rows the
list shows. A folder that is both measured and a root of a deeper plan, such as
Application Support or proj, shows as its "(rest)" row plus its measured
children.

### D6: Does the SDK change?

- **Option A, plugin-only**: the Disk plugin observes wake and unlock itself, computes its own data path, and has no config switch, because the host owns the config file and its parser rejects unknown keys.
- **Option B, add three generic pieces to the SDK.**

**Selected: B.** Each is a need any persisting plugin will have, and the project
rule is that code two plugins need joins the SDK rather than being copied.
Adam, 2026-10-10.

1. **Per-plugin settings.** A plugins.json entry gains an optional `settings`
   object. The parser stays strict about its own keys and passes the object
   through untouched. `HostServices.settings` hands it to the plugin as a `PluginSettings`
   value, a Sendable wrapper over the decoded JSON with typed accessors such
   as `bool(forKey:)`; the plugin validates its own keys and reports a bad
   value in its status line rather than failing to load. The Disk plugin reads one
   key, `backgroundScans` (boolean, default true).
2. **A data folder per plugin.** `HostServices.dataDirectory` is
   `~/Library/Application Support/SystemBar/PluginData/<identifier>/`, created
   on first use, with `SYSTEMBAR_PLUGIN_DATA_ROOT` overriding the root for
   tests. The ledger lives there as `disk-ledger.json`.
3. **Background sampling, owned by the CPU epic (ewy.1).** The two specs
   written on 2026-10-10 each proposed a contract; the CPU spec's won, and this
   spec adopts it unchanged: `TabPlugin.backgroundInterval: TimeInterval?`,
   nil by default, makes the scheduler call `collect()` on the plugin's own
   serial queue at that cadence while the tab is hidden, clamped between 5
   seconds and a day, reported by `--list-plugins` as `background every <n>s`.
   One amendment came from this spec and is part of ewy.1: the scheduler
   observes the Mac waking and restarts every background timer with its first
   tick `PluginScheduler.backgroundSettleAfterWake` (120 s) later. The Disk
   plugin declares 900 seconds. This epic depends on ewy.1; the CPU epic's
   third stage depends on this epic's `dataDirectory`, where its baseline file
   will live.

The frozen interface rule applies: every new `TabPlugin` requirement gets a
default in a protocol extension, and `HostServices` gains a new initializer
rather than changing the existing one, so older bundles and the current tests
keep compiling. Because one `HostServices` is built today for every plugin,
the loader will build one per plugin from shared feeds and runner, adding that
plugin's settings and data folder.

### D7: What does the README promise?

Today: "Every command below starts only while the window is open." The CPU
epic's Stage 1 rewrites that sentence and the feeds table's closing line to say
the guarantee is now opt-in per plugin, and adds a "While hidden" column to the
per-tab sampling table. This epic owns the Disk specifics: the Disk row of
that table (volumes and `tmutil` every 30 s showing, 15 min hidden; plans at 3 h
and 6 h), the `du` row and a new `xcrun simctl` row of the subprocess table, the
"disk scan" paragraph rewritten around the plans and the ledger file, and the
`settings` key in the plugins.json section with `backgroundScans` as its first
example. Adam, 2026-10-10.

## Measurement Contract

- Capacity figures come from `URLResourceValues` on each browsable mounted
  volume: total and available capacity. Used is total minus available.
- Folder sizes come from one `du -s -k -x <path>` per row, in kibibytes, on one
  filesystem, with a per-row timeout and a per-plan budget.
- Simulator metadata comes from `xcrun simctl list devices -j`; sizes from `du`
  on each device folder.
- Snapshot counts come from `tmutil listlocalsnapshots /` as today.
- Every row shows the time it was measured. The panel never shows a number
  without an age.
- Movers compare the newest sample with the newest sample at or before the
  window start; a window with no earlier sample says so rather than showing 0.

## Expected Outcomes

- On the author's Mac the top row reads Simulators at roughly 257 GB, not
  DerivedData at 8 GB, and the eight folders in the verification table all
  appear in Biggest.
- Opening the popover the morning after install shows last night's map at
  once, stamped with its age, and the overview refreshes within the first
  tick after wake.
- A simulator added yesterday shows in Movers 24h as new with its size; a
  deleted DerivedData shows as freed.
- Turning `backgroundScans` off stops scheduled scans; the button still works.

## Non-Goals

- Deleting anything, or hints about what is safe to delete.
- Per-file listings, or anything deeper than one level under a plan's roots.
- Per-project disk space on the Dev tab (17o D4 stands).
- FSEvents-driven incremental measurement. Revisit once the ledger exists.
- A launchd helper. The scan dies with the app.
- Hour-scale movers. The finest resolution is one overview every three hours.

## Issue Map

Children of swift-ui-system-monitor-ifd, to be created by the implementation plan:

1. SDK: per-plugin `settings` through the config parser and `HostServices`, with parser tests.
2. SDK: `HostServices.dataDirectory` with the environment override, one `HostServices` per plugin.
3. (Owned by ewy.1) `backgroundInterval`, the scheduler's slow timer and wake settle.
4. Disk: ledger value type, derived views, retention, and the JSON store with atomic write and `.broken` handling.
5. Disk: scan plans, per-plan budgets, simulator plan from a `simctl` fixture, due rule.
6. Disk: panel rewrite (left distribution, right Biggest and Movers), removal of purgeable and hints.
7. README and interval tests.

## Decision Log

- 2026-10-10 — D1: a map of where the space went, not a cleanup list. Adam.
- 2026-10-10 — D2: scans run in the menu-bar app while awake; overview 3 h, developer and simulators 6 h; a 15-minute background collect, two-minute wake settle, no unlock trigger. Adam.
- 2026-10-10 — D3: tiered roots, one level each; simulators per device. Adam.
- 2026-10-10 — D4: JSON ledger, 2 days full then daily to 30 days. Claude proposed, Adam approved.
- 2026-10-10 — D5: left distribution, right Biggest and Movers; purgeable removed. Adam.
- 2026-10-10 — D6: change the SDK: settings, data folder; background sampling adopts the CPU epic's `backgroundInterval` contract plus a wake settle, agreed between the two panes. Adam.
- 2026-10-10 — D7: README names the one exception and its off switch. Claude proposed, Adam approved.
