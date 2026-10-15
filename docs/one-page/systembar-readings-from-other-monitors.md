# Readings learned from other Mac monitors

- **Date:** 2026-10-14
- **Epics:** swift-ui-system-monitor-125 (host lane, this repository's Beads);
  system-monitor-core-plugins-3wj (tab lanes, the tabs' repository's Beads)
- **Builds on:** swift-ui-system-monitor-jhi (Power draw and keep-awake),
  swift-ui-system-monitor-ewy (background sampling)
- **Status:** approved 2026-10-14

## Goal

Compare the tabs against Stats (open source, read from its code), iStat Menus 7,
Activity Monitor, macmon, asitop, btop, coconutBattery and AlDente, and act on
three things that came out of it:

1. **Values we show wrong.** One is wrong on this Mac right now.
2. **Data people expect that we can read and do not show.** Battery detail,
   power draw, disk activity, Wi-Fi signal, latency, totals.
3. **Pictures that make a number useful.** History graphs that keep running when
   the popover is closed, a power-flow picture, and notifications when something
   crosses a line.

The spec is laid out tab by tab, after the shared work in the host and SDK that
several tabs wait on.

## What Probing This Mac Showed

Every source below was read on the development Mac (macOS 26.6, an M5-class chip
with 6 "Super" and 12 "Performance" cores), without `sudo`.

| What | Where it comes from | What it said |
|---|---|---|
| Charging state | `pmset -g batt` | `80%; AC attached; not charging` — the Power tab shows **"80% Charging"** |
| Charge limit | `/Library/Preferences/com.apple.powerd.charging.plist`, `policies` (a keyed archive) | `manualChargeLimit`, `soclimit` = 80 |
| Why not charging | `ioreg -rn AppleSmartBattery`, `ChargerData.NotChargingReason` | non-zero (held at the limit) |
| Battery health | same, `AppleRawMaxCapacity` / `DesignCapacity` | 6259 / 6249 = 100% |
| Cycles, temperature | same, `CycleCount`, `Temperature` | 24 cycles, 3066 = 30.7 °C |
| Charger | same, `AdapterDetails.Watts` | 94 W |
| Whole-Mac power draw | same, `PowerTelemetryData.SystemLoad` (mW) | 31598 = 31.6 W, on AC |
| Battery-only watts | `Voltage` × `Amperage` (jhi D2) | **0 W** on AC, because the battery is idle: wrong as "power draw" |
| Whole-Mac draw, on battery (2026-10-14, P1 probe) | `SystemLoad`, `BatteryPower`, `Voltage` × `Amperage` | `SystemLoad` **−15.8 W** (negative), `BatteryPower` 15.8 W, `Voltage × |Amperage|` **50.4 W** (12.14 V × 4.15 A); `TimeRemaining` 67 min on ~58 Wh left implies ~52 W |
| Telemetry freshness | `PowerTelemetryData` | lags: still showed 84.8 W charger input 50 s after unplugging; updates about once a minute, while `Voltage`/`Amperage` follow at once |
| Disk activity | `ioreg -r -c IOBlockStorageDriver`, `Statistics` | `Bytes (Read)` 742 GB, `Bytes (Write)` 1.47 TB since boot |
| GPU | `ioreg -r -c AGXAccelerator`, `PerformanceStatistics` | Device 34%, Renderer 32%, Tiler 21% |
| Interface totals | `netstat -ib` (64-bit) | `en0` received 113 GB since boot — far past the 4 GiB at which our counters wrap |
| Interfaces we sum | `getifaddrs`, every up non-loopback link | includes 7 `utun`, `awdl0`, `llw0`, `bridge0`, `anpi*` |

Two findings change earlier decisions:

- **jhi D2's watts are battery watts, not Mac watts.** On AC with the battery
  held, `Voltage × Amperage` is zero while the Mac draws 31.6 W. `SystemLoad`
  measures the Mac on AC. It is an undocumented key, so it was re-checked on
  battery (P1 probe, 2026-10-14): there it turns negative and reads a third of the
  real draw, so it is **not** whole-Mac watts on battery. On battery the Mac's draw
  is the battery's discharge, `Voltage × |Amperage|`, which agrees with the
  driver's own time-remaining estimate (P1 below).
- **The charge limit is readable.** It lives in a world-readable preferences file
  as a keyed archive. Undocumented, so it is shown only when it parses, and is
  absent otherwise.

## Answers to the Review Questions

**What are Wi-Fi noise and link speed?** Signal strength (RSSI) is how loud the
router sounds to the Mac, in dBm: −50 is loud, −80 is a whisper. Noise is the
background hiss on that channel, from microwaves, neighbours' Wi-Fi and so on,
around −90. What matters is the gap between them (signal-to-noise): a loud router
in a noisy room can be worse than a quieter one in a silent room. Link speed is
the rate the Mac and router agreed to talk at, in Mbps. It is the ceiling for this
connection, not what you are getting. The spec shows one plain verdict ("Signal:
good") built from the gap, with the three numbers underneath for anyone who wants
them.

**How would swap speed be shown?** As one line that only appears while the Mac is
actually swapping: "Swapping 40 MB/s out, 5 MB/s in". It comes from the kernel's
swap-in and swap-out counters (`vm_statistics64` `swapins`/`swapouts`) turned into
a speed. "Swap used" can sit at 3 GB for days after the squeeze has passed; the
speed says whether it is happening now. A small history strip under the pressure
graph shows when it happened.

**Don't we already have a memory pressure graph?** No. The Memory tab has a
pressure word in a pill and a bar of what memory holds now, but no history. Only
the CPU tab (CPU %) and the Network tab (down/up) draw history graphs.

**What is the connectivity strip for?** It answers "is it my internet or is it
this website?" at a glance: one square per ping, green when fast, yellow when
slow, red when no reply, so drop-outs over the last few minutes show as red gaps.
The spec folds this into the latency graph instead of adding a separate strip:
failed pings are drawn as red marks on the latency line.

**Can we compare the charge limit with the battery?** Yes, after probing: see
"What Probing This Mac Showed". The battery bar draws the limit as a marker, and
the state reads "Held at 80% limit" instead of "Charging".

## Decisions

### D1: Which units?

**Selected (by Adam, 2026-10-14): Apple's convention.** Disk sizes, disk speeds
and network speeds use 1000 (GB = 10⁹), as Finder and Disk Utility do. Memory uses
1024, as Activity Monitor does ("16 GB" of RAM is 16 GiB). The labels stay GB, MB,
KB, as Apple's do.

### D2: Private interfaces?

- **Option A — none.**
- **Option B — when the data is something most people expect to see,** and only
  when it needs no helper, no `sudo` and no entitlement, with a plain "not
  available" state when a macOS update breaks it.
- **Option C — whatever Stats and macmon read.**

**Selected: B** (Adam, 2026-10-14: "if they give us really valuable data that
people will typically want to see"). Under B:

- **In:** undocumented `ioreg` keys (`PowerTelemetryData`, `AdapterDetails`,
  `ChargerData`), the charge-limit preference file, IOKit disk statistics.
- **In, later phase, separate decision at the time:** CPU/SoC temperature through
  `IOHIDEventSystemClient` sensors, which every comparable app shows. This
  reverses jhi D1, so it gets its own probe and decision before any work.
- **Out:** IOReport (CPU frequency, CPU/GPU/Neural Engine watts) — niche, and
  macOS 27 already stops it working for apps other than Apple's. Fan speed through
  the SMC — only on Macs with fans, and the SMC is the most fragile of these.

### D3: How do graphs keep history while the popover is closed?

- **Option A — the 1-second CPU/network sampler runs always;** each tab that
  draws a graph of its own declares a `backgroundInterval` (floor 5 s) and keeps
  its own history. `ps` stays visible-only, as jhi D4 requires.
- **Option B — everything runs always,** including `ps`.
- **Option C — keep today's behaviour.**

**Selected: A.** The 1-second sampler is two kernel calls, microseconds of work.
`ps` over a thousand processes is not, and jhi D4 already rejected it. Histories
that must survive a relaunch (power draw over 24 hours) are saved in the tab's
data folder; the rest live in memory.

### D4: Where do notification rules live?

- **Option A — each tab owns its rules,** configured in its `settings` in
  `plugins.json`; the SDK gains one call to post a notification, and the host owns
  permission, rate limits and the off switch.
- **Option B — the host owns every rule,** over the shared feeds only.

**Selected: A.** Only the tab knows what "low disk" or "held at limit" means, and
B can only see CPU and network. The host owning the delivery keeps a misbehaving
tab from spamming: one notification per rule per cooldown, and one place to turn
them all off.

### D5: Which free space does the Disk tab headline?

- **Option A — keep strictly free** (`volumeAvailableCapacityKey`), which reads
  lower than Finder.
- **Option B — what Finder shows** (`volumeAvailableCapacityForImportantUsageKey`,
  which counts purgeable space as available), with "of which X purgeable"
  underneath.

**Selected: B.** "Match Apple's convention for numbers" covers this too, and
showing the purgeable share keeps the honest number visible. This reverses a
deliberate choice in the Disk tab (`DiskModels.swift`), so it is called out here.

### D6: Should Power install by default?

Power is kept but not installed today. With battery detail, power draw, charge
limit and history it becomes one of the more useful tabs.

**Selected: yes**, once P1–P4 land. On a Mac with no battery it shows power draw
alone if `SystemLoad` exists there, and otherwise says plainly that this Mac
reports no power figures.

## Host and SDK (this repository)

- **H1 — Apple-convention formatters (D1).** The SDK gains `fileByteString`,
  `fileRateString` (1000-based) and `memoryByteString` (1024-based). These are
  additions, so `byteString` and `rateString` stay for older bundles. Tabs switch
  to the right one. Accept: 1 500 000 000 bytes reads "1.5 GB" as a file and
  "1.4 GB" as memory.
- **H2 — Network counters that do not wrap and do not double count.** Read 64-bit
  counters through `sysctl NET_RT_IFLIST2` (`if_msghdr2.ifm_data`), as Stats does.
  Sum physical interfaces only (`en*`); skip `utun`, `awdl`, `llw`, `bridge`,
  `gif`, `stf`, `anpi`, `ap`. Accept: a fake counter crossing 2³² gives the right
  rate, and a VPN download counts once.
- **H3 — Totals since boot on the fast feed.** The feed carries total bytes
  received and sent. These are additive fields on the public model.
- **H4 — The 1-second sampler runs while the popover is closed (D3).** Accept:
  open the popover after a minute closed, and the CPU and network graphs are
  full.
- **H5 — Post a notification (D4).** `HostServices.notify(id:title:body:)`, added
  with a default so older bundles still load. The host asks for permission once,
  applies a per-rule cooldown, and has one off switch. Accept: a test host records
  posts and drops a repeat within the cooldown.
- **H6 — Footprint in `ProcessTable`.** Add each row's `phys_footprint` (falling
  back to RSS when unreadable), so the CPU drill-in shows the same memory figure as
  the list. An additive field.

## Power

Builds on jhi. jhi.2 (watts, health, cycles) and jhi.6 (render) are amended as
noted; jhi.3–jhi.5 (sleep blockers, sleep cause, keep-awake) are unchanged.

- **P0 — Fix the charging state (wrong today).** Charging comes from
  `AppleSmartBattery` `IsCharging` / `ExternalConnected` / `FullyCharged` and
  `ChargerData.NotChargingReason`, not from words in `pmset` output. States:
  Charging, Discharging, Full, Held at limit, On AC (not charging). Accept: the
  `pmset` and `ioreg` text captured from this Mac reads "Held at 80% limit".
- **P1 — Real power draw (amends jhi.2).** Battery watts = `Voltage × Amperage`
  (signed, as jhi warns: negative is discharge). Mac watts: on battery,
  `Voltage × |Amperage|`; on AC, `SystemPowerIn` (equal to `SystemLoad` there)
  less the battery's charging watts when it is charging. Charger watts = rated
  `AdapterDetails.Watts`. The probe ruled out `SystemLoad` on battery (negative,
  a third of the real draw); no desktop Mac was available, so a Mac with no
  battery shows `SystemPowerIn` when present and otherwise says it reports no
  power figures. Telemetry lags about a minute behind a plug or unplug, so for
  the minute after the source changes the tab prefers `Voltage × Amperage` and
  never shows charger input while `ExternalConnected` is false.
- **P2 — Battery detail.** Health (`AppleRawMaxCapacity ÷ DesignCapacity`, which
  can read over 100% on a new battery and will not match System Settings exactly),
  cycle count, battery temperature (labelled as the battery's), charger wattage,
  and time remaining ("Calculating…" while `TimeRemaining` is 65535 or absent,
  never 0:00).
- **P3 — Charge limit.** Read `soclimit` from the powerd charging policy; draw it
  as a marker on the battery bar. Absent, not guessed, when the file is missing or
  does not parse.
- **P4 — Power flow picture.** Charger → Mac and charger ↔ battery, with watts on
  each arrow; on battery, battery → Mac. AlDente's picture is the model.
- **P5 — Power draw over time.** Sample every 10 s in the background (D3); keep 24
  hours of one-minute averages in the data folder; draw the last hour, with the
  day behind a toggle.
- **P6 — Contributors use whole-machine CPU %,** like every other tab. Today an app
  reads "250% CPU" here and "14%" on the CPU tab.
- **P7 — Rules (D4):** battery below N%; charger connected but not charging below
  the limit.

## Memory

- **M1 — Pressure history graph.** The last 15 minutes of memory used (as a share
  of RAM), each sample coloured by the pressure level at that moment (green,
  yellow, red), in Activity Monitor's colours. Activity Monitor's own graph height
  is an undocumented pressure figure, and `100 − kern.memorystatus_level` is not it
  (see the Memory tab's notes), so the height here is memory used, which is
  documented. Background sampling every 10 s (D3).
- **M2 — Swap speed.** "Swapping X out, Y in" from `swapouts`/`swapins` deltas ×
  page size, shown only when non-zero in the last minute, with a strip under M1.
- **M3 — Bar fix.** Already tracked as 6yc (purgeable counted twice); also add the
  missing speculative pages so the bar sums to total.
- **M4 — Units.** `memoryByteString` (H1).
- **M5 — Rules:** pressure reaches warning or critical; swapping above a rate for
  N minutes.

## Disk

- **K1 — Disk activity.** Read and write speeds from `IOBlockStorageDriver`
  `Statistics` deltas, internal disk, drawn as a down/up graph like the Network
  tab's. Background sampling (D3) so the graph is full on open.
- **K2 — Free space as Finder shows it (D5),** with the purgeable share
  underneath.
- **K3 — Units.** `fileByteString` and `fileRateString` (H1).
- **K4 — Rules:** free space below N GB.

## Network

- **N1 — Wi-Fi signal.** CoreWLAN `rssiValue`, `noiseMeasurement`,
  `transmitRate`, band and channel; a verdict from signal minus noise (good above
  25 dB, fair 15–25, poor below). No network name, because CoreWLAN gives it only
  with Location permission. Hidden on Ethernet.
- **N2 — Latency.** One ping every 5 s to the router (default gateway) and one to
  a public address (configurable in `settings`, default 1.1.1.1), sent from inside
  the tab over an ICMP datagram socket (no root, no subprocess). Two lines on one
  graph, with failed pings as red marks: router fine and internet failing means the
  ISP; both failing means Wi-Fi.
- **N3 — Running totals.** Received and sent since boot (H3) in the Down/Up cards;
  per-app totals, which `nettop` already returns and the tab discards, as a column.
- **N4 — Units.** `fileRateString` (H1). The speed test stays in megabits per
  second, as Apple's `networkQuality` reports it.
- **N5 — Rules:** internet unreachable for N pings; latency above N ms for M
  minutes.

## CPU

- **C1 — Drill-in memory uses footprint** (H6), matching the list.
- **C2 — GPU line.** Device, renderer and tiler utilisation every second with a
  history graph, moved here from Memory, where "GPU busy" sits oddly. Memory keeps
  the GPU's share of memory.
- **C3 — Load averages** for 1, 5 and 15 minutes, and uptime.
- **C4 — Rules:** CPU above N% for M minutes; thermal state serious or worse.

## Dev

- **D-1 — Comment fix.** `ProjectLoadRollup.swift` says `ps %cpu` is a lifetime
  average; the man page says "a decaying average over up to a minute".
- **D-2 — Units** (H1).

## Expected Outcomes

- No tab shows a wrong state: the battery is never "Charging" while it is held or
  draining, network speed never drops to zero at a 4 GiB boundary, and a VPN
  download counts once.
- The same process shows the same CPU and memory figure on every tab.
- Sizes and speeds read the way Finder and Activity Monitor read them.
- Power shows what the Mac draws, where the watts go, battery health and the charge
  limit, and how draw changed over the day.
- Graphs are full when the popover opens.
- Wi-Fi signal and latency say whether a slow connection is the room, the router
  or the internet.
- A rule can tap you on the shoulder: low disk, memory pressure, battery low,
  internet down, CPU pinned.

## Non-Goals

- No IOReport: no CPU frequency, no per-chip watts.
- No fan speed and no fan control.
- No privileged helper, no `sudo`, no `powermetrics` (unchanged from jhi).
- No public-IP lookup: it tells a third-party server who you are, and nobody asked
  for it.
- No background `ps` (jhi D4 stands).
- No Wi-Fi network name (needs Location permission).
- No connectivity strip separate from the latency graph.

## Where the issues go

Tab work lives in the tabs' repository's own Beads, set up for this
(`system-monitor-core-plugins-3wj`); app and SDK work stays in this repository's
Beads (`swift-ui-system-monitor-125`). A tab issue that waits on a host issue names
it in its description, because Beads cannot link across the two. 6yc moved to M3;
jhi.2 and jhi.6 carry comments pointing at the Power lane.

## Issue Map: one worker per lane

Six lanes run in parallel, one worker each: the host, and one per affected tab.
Dev's two small items ride with the CPU worker. Inside a lane the work is in
order; between lanes the only waits are on the host's SDK additions, and each
lane puts those items last, so no worker sits idle at the start.

| Lane | Beads | Order inside the lane | Waits on the host for |
|---|---|---|---|
| Host | swift-ui-system-monitor-125 (.1–.6) | H1 → H6 → H5 → H3 → H2 → H4 | nothing |
| Power | system-monitor-core-plugins-3wj.1 | P0 → P6 → P1 probe → P1 → P2 → P3 → P4 → P5 → units → P7 → D6 | H1 (units), H5 (P7) |
| Memory | 3wj.2 | M3 → M2 → M1 → M4 → M5 → M6 (drop GPU busy after C2) | H1 (M4), H5 (M5) |
| Disk | 3wj.3 | K1 → K2 → K3 → K4 | H1 (K3), H5 (K4) |
| Network | 3wj.4 | N1 → N2 → N3 per-app totals → N3 since-boot totals → N4 → N5 | H3, H1 (N4), H5 (N5) |
| CPU + Dev | 3wj.5 | D-1 → C3 → C2 → C1 → units (CPU, Dev) → C4 | H6 (C1), H1 (units), H5 (C4) |

Why the host goes in that order: H1 (formatters) and H6 (footprint) are small and
unblock every tab's units step and C1 within the first stretch; H5 (notify) is
next because every lane ends on rules; H3 unblocks Network's last data item; H2
and H4 change only the host, so they go last.

How a tab uses a new SDK addition: the tabs build against the installed app's
interface, so once a host item merges, the host worker rebuilds `SystemBar.app`
and tab workers run their checks with `SYSTEMBAR_APP` pointing at it.

Where workers will collide, and how it is kept small:

- `scripts/test.sh` in the tabs' repository pins each tab's `--list-plugins` line.
  Power, Memory and Network each add `background every <n>s` to their own line
  (P5, M1, N2). One line per lane; the merge is mechanical.
- The tabs' `README.md` has a section per tab on what it reads and how often.
  Each lane edits only its own tab's lines.
- `DEFAULT_TABS` in `scripts/systembar.sh` changes only in the Power lane (D6).
- 6yc (the memory bar) is already an issue; M3 takes it over.

Outside the lanes, after everything else: the temperature probe and its decision
(D2, later phase).

## Decision Log

- 2026-10-14 — D1: chose Apple's convention — Adam.
- 2026-10-14 — D2: private interfaces only for data people typically want —
  Adam; the in/out lists above are proposed.
- 2026-10-14 — D2 in/out lists, D3 (A), D4 (A), D5 (B), D6 (yes) accepted as
  proposed — Adam.
- 2026-10-14 — Work planned as six parallel lanes, one worker per lane; tab
  issues in a new Beads in the tabs' repository — Adam.
