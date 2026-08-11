# Project capacity ledger

- **Date:** 2026-08-11
- **Epic:** swift-ui-system-monitor-17o
- **Status:** approved 2026-08-11

## Goal

Make the Dev panel answer the question its owner actually has: which of my
projects is drawing down machine capacity right now, and through what kind of
expensive work. Today the panel shows a raw `lsof` listen dump, a
name-substring guess at "developer processes", and a static note about whether
Docker is installed. None of that survives contact with the real question.

This is the first of three specs. The Power panel and cross-project history
both depend on the attribution and grading built here.

## Decisions

### D1: How does a process get attributed to a project?

- **Option A — inference from the nearest enclosing Git repository:** Pull
  path-like tokens out of a process's arguments, walk up to the first directory
  containing `.git`, and treat that repository root as the project. No
  configuration, nothing machine-specific compiled in, correct on a stranger's
  Mac the day they install it. It can only guess.
- **Option B — user-configured watched roots:** The user lists directories to
  treat as project containers. Explicit rather than magic, and it handles
  projects that are not Git repositories, but it says nothing until configured
  and needs a settings surface the app does not have.
- **Option C — cooperative declaration only:** Show load only for projects that
  opt in. Precise and never wrong, but silent for every project that has not
  onboarded.

**Selected: A first, then C layered on top.** Inference makes the panel useful
to someone who just installed it; publication makes it exact for projects that
choose to participate. Where both describe the same project, published data
wins, because it knows and inference only guesses.

### D2: How do projects publish exact state?

- **Option A — drop file with a heartbeat:** Each publisher writes small JSON
  into a documented directory declaring project name, active work, leases and a
  timestamp. No server, no ports, no privileges, language-agnostic, and
  testable from fixtures. Entries past their TTL render as stale.
- **Option B — local socket or HTTP endpoint:** Genuinely live with no polling
  lag, but it makes a monitoring app into a listening server, and publishers
  fail silently whenever it is not running.
- **Option C — per-repository state file:** Keeps data beside the project that
  owns it, but SystemBar can only find repositories it already knows about, so
  it depends entirely on inference working first.

**Selected: A — a documented file contract is the smallest thing that is honest
about liveness and adds no attack surface to a monitoring app.**

### D3: Which per-project numbers may be shown?

- **Option A — show only what `proc_pid_rusage` measures:** CPU share from
  user-plus-system CPU-time deltas, memory from summed `ri_phys_footprint`, and
  disk I/O rate from `ri_diskio_bytesread` and `byteswritten` deltas. All three
  are per-PID and therefore attribute cleanly.
- **Option B — sum `ps` pcpu per project:** Cheap and already collected, but
  macOS `pcpu` is a decaying lifetime average rather than current load, so a
  displayed percentage would not mean what a reader takes it to mean.
- **Option C — express draw only through work categories and leases:** Never
  risk a wrong number. Honest, but throws away three measurements that are
  genuinely available.

**Selected: A, with C as the degradation path.** A number on screen is a claim.
When the measurement does not complete, the row falls back to naming the
categories of work it found and says the load was not measurable.

### D4: What is deliberately not measured per project?

- **Disk space** would need `du` walks across repositories, package
  directories and DerivedData, and could not be attributed without guessing.
  It stays the Disk panel's concern.
- **Network** is not collected per PID today. The existing network summary
  groups by process name, which cannot separate two projects both running
  `node`.

**Selected: omit both rather than approximate them.**

### D5: Does SystemBar act on other projects?

- **Option A — read-only:** Display load, categories and lease state. Never
  kill, throttle, or change a lease.
- **Option B — enforce:** Offer to kill processes or reclaim stale leases.

**Selected: A.** This matches the `shotstep-zp2s` non-goals, which forbid
process killing, throttling and lease changes. The single piece of state
SystemBar owns and mutates is its own sleep assertion, and that arrives in the
Power panel spec.

## Measurement Contract

Numbers shown per project are measured or absent. There is no third case.

- **CPU share** is the user-plus-system CPU-time delta across a project's live
  categorized PIDs, divided by elapsed time times the active core count. This
  is the same whole-machine denominator `ProcessCPUScale` already uses, so a
  project row is comparable with the CPU panel.
- **Memory** is the sum of `ri_phys_footprint`, the figure Activity Monitor
  reports as Memory. Shared framework pages can be counted once per process,
  so the sum is a close upper bound rather than an exact byte count.
- **Disk I/O** is the read and write byte deltas over the same interval.
- Only PIDs that matched a work category are sampled, which bounds the syscall
  count naturally even during a large build.

Two limits are stated in the panel rather than buried:

- The sample sees processes **alive at sample time**. A build churning through
  short-lived compiler jobs has CPU that no sampler can recover, because a
  reaped child's rusage is gone. A row describes current draw, never total work
  done.
- A project with categorized work but no completed measurement is **unmeasured**,
  and renders as its categories plus a plain statement that load was not
  measurable. It never renders as zero, and never as a stale previous value.

The capacity headline grades on whole-machine CPU, thermal state and counts of
heat-heavy work, so it stays trustworthy in every case above — including when
attribution fails completely.

## Expected Outcomes

- One row per project, naming the categories of expensive work it is running
  and its measured CPU share, memory footprint and disk I/O rate.
- A capacity headline reading low, moderate or high available capacity from the
  same rules as `machine-capacity.js`, so the panel and that script never
  disagree.
- Work that could not be attributed appears as a visible Unattributed row.
  A visible failure is the evidence for whether the `lsof` fallback layer earns
  its cost.
- Listening ports carry a project name where one is known, and become a detail
  of the project rather than a flat dump.
- Nothing machine-specific is compiled in, so the app remains shippable as open
  source.

## Non-Goals

- No hardcoded project paths, user names, or repository lists.
- No process killing, CPU throttling, or lease changes.
- No per-project disk space or network figures.
- No number derived from `ps` pcpu presented as current load.
- No zero or stale value standing in for a failed measurement.
- No listening server, no elevated privileges, no new package manager.

## Issue Map

- swift-ui-system-monitor-17o — Dev panel becomes a per-project capacity ledger
  - 17o.1 — classify expensive work into categories
  - 17o.2 — attribute a process to a project by nearest Git repository
  - 17o.3 — measure real per-project CPU, memory and disk I/O
  - 17o.4 — port the capacity grade shared by both panels
  - 17o.5 — render the Dev panel as a project ledger; waits for 17o.1 to 17o.4
  - 17o.6 — `lsof` cwd fallback for unattributed heavy work; waits for 17o.5
  - 17o.7 — read project state published by drop file; waits for 17o.5

## Related Work

- `shotstep-zp2s` chose project-local capacity history and rejected a
  machine-wide log. That decision answered a project-scoped question. SystemBar's
  question is machine-wide by nature, so it keeps its own bounded history in a
  later spec, storing project name, category and metrics — never raw arguments
  or private paths, preserving the `zp2s` privacy non-goal.
- `shotstep-91ms` retired a declarative leasing framework in July 2026 because
  no consumer justified it. 17o.7 is that consumer.

## Decision Log

- 2026-08-11 — D1: chose A then C — inference works on install, publication
  makes participating projects exact — Adam.
- 2026-08-11 — D2: chose A — a file contract is honest about liveness and adds
  no attack surface — Adam.
- 2026-08-11 — D3: chose A with C as degradation — a displayed number is a
  claim, so no number beats a speculative one — Adam.
- 2026-08-11 — D4: omit disk space and network rather than approximate — Adam.
- 2026-08-11 — D5: chose A — read-only, matching the zp2s non-goals — Adam.
