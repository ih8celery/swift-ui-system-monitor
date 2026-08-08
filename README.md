# SystemBar

A single menu bar icon for Memory, CPU, Disk, Network, and Power — instead of five separate ones.

![SystemBar screenshot](screenshot.png)

SystemBar replaces a cluttered row of individual menu bar monitors with one icon and a tabbed popover. Tap between tabs to see memory pressure, per-process CPU share, disk usage hogs, network throughput, and battery/power state, all sampled live from macOS kernel APIs.

## Build

```bash
./build.sh
```

## Install as a login item

```bash
./install.sh
```

This builds the app, copies it to `~/Applications/SystemBar.app`, and registers a LaunchAgent that keeps it running across login.

To uninstall:

```bash
./install.sh uninstall
```

## Test

```bash
./test.sh
```

## Status

This is a personal project maintained casually in spare time — no guarantees on response time, but bug reports, feature requests, and pull requests are genuinely welcome.
