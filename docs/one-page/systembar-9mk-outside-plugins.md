# Plugins installed from outside the app

- **Date:** 2026-10-04
- **Epic:** swift-ui-system-monitor-9mk
- **Status:** approved 2026-10-04

## Goal

Let another project install a SystemBar tab without editing SystemBar or its
`plugins.json`. The first such project is machine-capacity-manager, whose
lease tab (its epic `machine-capacity-manager-m4e`, spec
`docs/one-page/machine-capacity-manager-m4e-systembar-lease-tab.md` in that
repository) is built and installed by mc's own `install.sh`.

This is the first step towards a decision made the same day: SystemBar
eventually ships no tabs inside the app, and the six built-ins install the
same way an outside plugin does (epic swift-ui-system-monitor-i0q).

## Decisions

### D1: How does SystemBar find a plugin another project installed?

- **Option A — scan a shared folder:** at launch the host loads every
  `*.bundle` in `~/Library/Application Support/SystemBar/PlugIns/` that
  `plugins.json` does not already name. An installer only has to copy a
  bundle; nothing but the person edits SystemBar's config.
- **Option B — the installer adds a `path` entry to `plugins.json`:** no host
  change, but a second program writes a strictly parsed file it does not own,
  and must cope with it being missing, hand-edited, or mid-edit.

**Selected: A.** The folder is the one already named in the tab-plugins spec's
config example and the README's HelloTab walkthrough, so it is a convention
the project already uses rather than a new one.

### D2: Where do scanned tabs go, and how does the person control them?

Listed entries load first, in `plugins.json` order, exactly as today. Then
every folder bundle whose resolved, standardized path matches no `path` entry
loads, in alphabetical order of file name, so the order is the same on every
launch.

To move a folder bundle or hide it, the person adds a `path` entry for it,
optionally with `"enabled": false`. A listed folder bundle is never loaded a
second time by the scan. No config key is added, so the strict parser does
not change.

A folder bundle that fails to load is reported exactly as a failed listed
entry is: an error tab today, the notifications list once
swift-ui-system-monitor-4pa lands. Two bundles with the same `identifier`
hit the existing duplicate-id check, whichever way they were found.

### D3: How does the folder interact with a missing `plugins.json`?

swift-ui-system-monitor-5pn decides that a missing `plugins.json` means no
listed tabs and writes nothing. The scan still runs in that case, so the empty
state shows only when the file lists nothing *and* the folder holds no
bundles. A missing folder is the same as an empty one; the host does not
create it.

Tests never touch the real folder: `SYSTEMBAR_PLUGINS_DIR` overrides it, the
same way `SYSTEMBAR_PLUGINS_FILE` overrides the config file, and the tests
build their own folder inside a temporary directory.

### D4: How does an outside project build against the installed SDK?

- **Option A — ship `build-plugin.sh` inside the app** at
  `Contents/Resources/build-plugin.sh`. Run from there with no SDK argument,
  it uses the app it sits in. An outside installer runs that copy, so every
  plugin is built by the one compile path, with the `-swift-version` and
  `-target` the interface was emitted with.
- **Option B — each outside project carries its own `swiftc` line.** Works,
  but every project then has to track the SDK's flags by hand, and the first
  one that drifts gets an interface mismatch at load time.

**Selected: A.** The script already finds the SDK in an app's
`Contents/Resources/SDK`; the change is shipping it and defaulting its third
argument to the enclosing app when it runs from inside one. It already reads
`-target` and `-swift-version` from the interface's `swift-module-flags`
header rather than from `toolchain.env`, so the shipped copy needs nothing
from the repository.

## Expected Outcomes

- Copying a built bundle into the shared folder and relaunching shows its tab
  after the listed ones, with no edit to `plugins.json`.
- A `path` entry for that bundle moves it or, with `"enabled": false`, hides
  it; it is never loaded twice.
- `SystemBar.app/Contents/Resources/build-plugin.sh Examples/HelloTab out.bundle`
  builds from any directory, with no repository checked out.
- A broken bundle in the folder is reported like any failed entry.

## Testing

- **Unit:** the folder scan against a temporary folder: unlisted bundles
  appended alphabetically; a listed bundle skipped by the scan; a disabled
  `path` entry hides its bundle; a missing folder is empty; non-bundle files
  are ignored; path matching survives `~` and a trailing slash.
- **Integration:** `test.sh` builds `Examples/HelloTab` with the app's shipped
  `build-plugin.sh` into a temporary `SYSTEMBAR_PLUGINS_DIR`, with a
  `plugins.json` that does not list it, and checks `--list-plugins` shows it
  after the listed six. It fails if the shipped script is missing.

## Non-Goals

- No watching the folder. Relaunch is still the mechanism.
- No signing or verification. The README's existing warning — a bundle runs
  inside the app with its privileges, load only what you built or trust —
  now covers the folder too.
- No change to how the six built-in tabs are found or installed. That is
  epic swift-ui-system-monitor-i0q.

## Effect on Open Issues

- **0u2** (installer offers the built-ins): proposed change, for whoever picks
  it up — copy the chosen bundles into the shared folder instead of writing
  `plugins.json`. Then the built-ins and outside plugins install one way.
  0u2 now depends on this epic.
- **5pn** (missing `plugins.json` means no tabs): D3 refines its empty state.
- **4pa** (failures behind a notifications button): folder failures follow
  whatever failed entries do.

## Issue Map

Epic swift-ui-system-monitor-9mk:

- 9mk.1 — load every bundle in the shared folder that `plugins.json` does not
  list (D1–D3)
- 9mk.2 — ship `build-plugin.sh` inside the app (D4)
- 9mk.3 — `test.sh` proves an outside-built plugin installs and loads; depends
  on 9mk.1 and 9mk.2

machine-capacity-manager-m4e (the lease tab) depends on this epic finishing.
