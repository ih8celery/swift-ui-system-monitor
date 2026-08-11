# Power draw, sleep diagnosis and keep-awake

- **Date:** 2026-08-11
- **Epic:** swift-ui-system-monitor-jhi
- **Companion epic:** swift-ui-system-monitor-17o (project capacity ledger)
- **Status:** approved 2026-08-11

## Goal

Make the Power panel answer three questions it currently cannot: what is this
costing in watts, why did my Mac go to sleep and cut off my unattended work, and
can it stay awake by itself while that work runs.

Today the panel shows a thermal-state word, a battery percentage, raw `pmset`
assertion lines, and a list headed "Likely Contributors" that is the top five
processes by CPU — the same list the CPU tab already shows, relabelled. There is
no power figure anywhere in a panel called Power.

This is the second of three specs. It reads the capacity grade and work
categories built in 17o rather than deriving its own.

## Every Mechanism Was Verified First

The 17o spec was written before probing and had three decisions overturned by
contact with the real machine. This one was probed first. Findings are recorded
here because two of them change what can be promised.

| Mechanism | Verified | Result |
|---|---|---|
| Watts | `ioreg -rc AppleSmartBattery` | Voltage 11263 mV, Amperage −2292 mA → 25.8 W discharging |
| Time remaining | same | `TimeRemaining` = 69 minutes |
| Battery health | same | `AppleRawMaxCapacity` 5837 / `DesignCapacity` 6249 = 93%, `CycleCount` 171 |
| Sleep cause | `pmset -g log` | `Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:86%)` |
| Sleep blockers | `pmset -g assertions` | holders named with their own reason strings, e.g. "Codex is running an active turn" |
| Keep-awake | `IOPMAssertionCreateWithName` | succeeds with no privileges; visible to `pmset` under SystemBar's own name; releases cleanly |
| CPU temperature | `pmset -g therm` | **nothing.** No thermal warning, no performance warning, no CPU power status |

Two of those findings constrain the design:

- **There is no unprivileged heat number on this Mac.** `pmset -g therm` reports
  that no thermal warning, performance warning or CPU power status has ever been
  recorded, and CPU temperature, fan speed and throttle percentage all require
  root. This independently re-confirms `shotstep-zp2s` D4. "Heat headroom" was
  asked for and cannot be delivered as a figure.
- **The sleep log is expensive.** `pmset -g log` takes 1.5 seconds and produces
  10 MB. It cannot run on the panel's 60-second tick.

## Decisions

### D1: What may be shown about heat?

- **Option A — the coarse signals that exist:** the macOS thermal state's four
  levels, battery temperature labelled as the battery's, and what the 17o ledger
  says is driving heat right now.
- **Option B — a privileged temperature source:** a helper tool or `osx-cpu-temp`
  would give real degrees, at the cost of an install, a privilege grant, or a
  dependency.
- **Option C — show nothing about heat.**

**Selected: A.** It is everything available for free and it is honest about being
coarse. B stays deliberately deferred, as it has been since `zp2s` D4. Battery
temperature is never presented as a CPU or system temperature.

### D2: Where do watts come from?

- **Option A — `ioreg -rc AppleSmartBattery`:** Voltage times Amperage, verified
  above, no privileges, no new dependency.
- **Option B — `powermetrics`:** richer and per-component, but requires root.
- **Option C — no watts.**

**Selected: A.** With one hazard recorded in the contract below: the amperage
field is printed as an unsigned integer even when negative.

### D3: When does keep-awake hold, and what does it prevent?

- **Option A — automatic, from published work; system sleep always, display sleep
  only for UI work:** hold `PreventUserIdleSystemSleep` whenever a project
  publishes that it is running expensive work, and add
  `PreventUserIdleDisplaySleep` only while that work includes a simulator or
  automation, because UI automation breaks when the screen sleeps.
- **Option B — manual toggle with a duration.**
- **Option C — both assertions whenever anything runs:** simplest to explain, but
  it lights the display through every test run, which on battery at 25 W is a real
  cost for no benefit.

**Selected: A.** Manual arming only helps on the runs you remembered to arm, which
is the failure being fixed. Scoping the display assertion to simulator and
automation work keeps the cost proportional.

### D4: How is expensive work detected while the window is closed?

- **Option A — keep sampling processes when hidden:** works for every project with
  no opt-in, but costs a `ps` over a thousand processes plus rusage reads every
  minute, forever, and breaks the app's existing guarantee that a hidden window
  runs no heavy samplers.
- **Option B — published state only:** when hidden, read only the publisher drop
  directory. That is a file read, not a process scan, so the app stays genuinely
  idle. Nothing works until a project opts in.
- **Option C — keep-awake only while the popover is open:** preserves the
  guarantee and drops the feature, since unattended work is the whole point.

**Selected: B.** A monitoring app that burns CPU in the background to watch power
would be self-defeating, and declared work is more accurate than inferred work
anyway. Two consequences are accepted deliberately:

- `17o.7`, the publisher contract, becomes a **prerequisite** of keep-awake rather
  than a later nicety, and its schema must carry work **categories**, because D3
  scopes the display assertion by category.
- Until a project publishes, automatic keep-awake does nothing, and the panel says
  so plainly rather than appearing armed. Making `machine-capacity.js` publisher
  number one is a change in the ShotStep repository, outside this spec.

### D5: Can keep-awake hold indefinitely?

- **Option A — a ceiling:** release after a maximum hold even if work still looks
  active, and say plainly that it lapsed and why.
- **Option B — hold while work is detected.**

**Selected: A.** A wedged build or stuck simulator would otherwise keep the Mac
awake until the battery is flat, and the failure would be silent. `caffeinate`
itself uses timeouts for this reason.

### D6: How often is the sleep history read?

- **Option A — rare bounded refresh:** at most every 10 minutes and only while the
  Power tab is open, with a status line saying when it last ran — the pattern the
  disk hog scan already uses.
- **Option B — on demand behind a button.**
- **Option C — both.**

**Selected: A.** Sleep history changes slowly, so a rare refresh is always
effectively current, and nothing has to be remembered.

### D7: What state does SystemBar change?

Carried from `17o` D5: SystemBar remains read-only about everything except the one
assertion it holds itself. It never kills a process, never changes another
process's assertion, and never alters a lease.

## Measurement Contract

Every figure shown is measured or absent. There is no third case.

- **Watts** are `Voltage` millivolts times `Amperage` milliamps. The sign of
  amperage distinguishes discharging from charging.
- **Amperage arrives as two's complement printed unsigned.** A 2292 mA discharge
  appears as `18446744073709549324`. It must be reinterpreted as a signed 64-bit
  value or the figure is nonsense rather than merely wrong. This is the single
  most dangerous parse in the panel and is tested directly.
- **A Mac with no battery has none of these fields.** It says so; it never reports
  0 W, because zero watts is a claim and absence is a fact.
- **Battery health** is `AppleRawMaxCapacity` over `DesignCapacity`, with
  `CycleCount` shown as-is.
- **Battery temperature** is `Temperature` hundredths of a degree, labelled as the
  battery's. It is never presented as a CPU or system temperature.
- **Thermal state** is `ProcessInfo.thermalState`: four coarse levels, no number.
- **Sleep events** carry their timestamp, the quoted reason, and the power source
  and charge at the time.
- **Sleep blockers** carry the holding process, its pid, and the reason string it
  supplied. SystemBar's own assertion is distinguished from everyone else's.

## Expected Outcomes

- A panel called Power finally shows power: watts, time remaining, and whether the
  battery is charging or discharging.
- Battery health and cycle count are visible, so a degrading battery is noticeable
  before it is a surprise.
- The panel answers "why did my unattended run get cut off" with the recorded
  reason, the power source and the charge at the time.
- Sleep blockers read as statements about processes and what they say they are
  doing, not as raw `pmset` lines.
- Long unattended work survives idle sleep without anything being armed by hand,
  and the display additionally stays lit while UI automation is running.
- Keep-awake always says whether it is holding, why, and when it will lapse. It is
  visible to `pmset` under SystemBar's own name, so it can never be a mystery
  assertion.

## Non-Goals

- No CPU temperature, fan speed, throttle percentage, or fan-on prediction.
- No privileged helper, no `sudo`, no temperature tool install.
- No `powermetrics`.
- No watts, and no zero watts, on a Mac without a battery.
- No keep-awake that cannot lapse, and none that survives the app exiting.
- No attempt to defeat the screen lock. An assertion cannot stop the lock; that is
  a separate screensaver setting, and the panel points at it rather than pretending
  to control it.
- No process killing, throttling, or changes to other processes' assertions.
- No background process sampling while the window is closed.

## Issue Map

- swift-ui-system-monitor-jhi — Power panel becomes power draw, sleep diagnosis and keep-awake
  - jhi.1 — link IOKit for power assertions
  - jhi.2 — read real power draw and battery health
  - jhi.3 — say who is blocking sleep in plain language
  - jhi.4 — diagnose why the Mac last went to sleep
  - jhi.5 — hold an automatic keep-awake while published work runs; waits for
    jhi.1 and **17o.7**
  - jhi.6 — render the Power panel; waits for jhi.1 to jhi.5

## Decision Log

- 2026-08-11 — D1: chose A — no unprivileged heat number exists, so none is
  claimed — Adam.
- 2026-08-11 — D2: chose A — ioreg gives real watts with no privileges — Adam.
- 2026-08-11 — D3: chose A — automatic, with the display assertion scoped to UI
  work — Adam.
- 2026-08-11 — D4: chose B — published state keeps the app idle when hidden, and
  promotes 17o.7 to a prerequisite — Adam.
- 2026-08-11 — D5: chose A — a wedged build must not be able to flatten the
  battery silently — Adam.
- 2026-08-11 — D6: chose A — a rare bounded refresh, like the disk hog scan —
  Adam.
