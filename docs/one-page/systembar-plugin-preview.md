# Preview one plugin on its own

- **Date:** 2026-10-04
- **First user:** the Backup tab in `~/proj/system-backup` (its spec:
  `docs/superpowers/specs/2026-10-04-menubar-backup-tab-design.md` there)
- **Status:** approved in conversation 2026-10-04, awaiting written review

## Goal

Show one plugin outside the menu bar, so a plugin author can test it from
start to finish without installing it into the running app.

Today the only way to see a plugin is to add it to `plugins.json`, relaunch
SystemBar and click the menu bar icon. That cannot run in a test, and it can
only show whatever the real machine happens to be doing.

## What it does

The SystemBar app gets a second command-line mode beside `--list-plugins`:

```
SystemBar --preview <bundle> --png <out.png> [--replies <file>] [--settings <file>] [--size <W>x<H>]
SystemBar --preview <bundle> --window        [--replies <file>] [--settings <file>]
```

- `--png` makes the plugin, tells it it is showing, runs `collect()` once,
  waits for the update the plugin sends to the main thread, saves a picture of
  its view, and exits. No window, no screen needed. `--size` defaults to the
  popover's size.
- `--window` opens the tab in an ordinary window and refreshes it on the tab's
  own timer, using the same scheduler as the app. Buttons work.

It is part of the app, not a separate program, so it loads the bundle with the
same loader, SDK and name checks as the menu bar. A plugin that loads in the
preview loads in the app. A plugin that fails to load prints the same
one-sentence error the app's error tab shows, and the preview exits 1.

## Settings and data folder

`--settings <file>` is a JSON object handed to the plugin as
`host.settings`, exactly as an entry's `"settings"` in `plugins.json` would
be, and checked the same way (it must be an object). Without it the plugin
gets empty settings. The plugin's `dataDirectory` is a fresh temporary folder
for each preview, so a preview never reads or writes the real
`PluginData` folder.

## Fake answers

Plugins learn about the machine by running commands through
`HostServices.run`. `--replies <file>` swaps the real command runner for one
that answers from a JSON file:

```json
{
  "replies": [
    { "path": "/Users/ada/proj/system-backup/bin/backup",
      "arguments": ["status", "--json"],
      "output": "{ ... }", "status": 0 }
  ]
}
```

A reply matches on the exact path and argument list; `error` (stderr) and
`status` are optional, defaulting to empty and 0. A command with no matching
reply gets status 127 and the stderr line `no canned reply for <path> <args>`,
so a missing fake answer shows up instead of a real command quietly running.
Two replies for the same path and arguments are an error, so the first never
quietly wins.
Without `--replies`, real commands run, as in the app.

The file is parsed as strictly as `plugins.json`: an unknown key or a wrong
type is an error naming its place, and the preview exits 2.

## What it does not do

- No automatic picture comparison. Fonts and drawing change with macOS
  updates, so comparing against saved pictures would fail for no real reason.
  The preview catches a plugin that will not load, crashes or cannot be drawn;
  wording and button states belong in the plugin's unit tests; a person checks
  the look from the saved pictures.
- No other host feeds are faked. The `processes` and `fastStats` feeds run as
  in the app when a plugin asks for them; faking them can come later if a
  plugin needs it.

## Testing

- In-process tests: the replies file parser (good file, unknown key, wrong
  type), the fake runner (match, no match → 127), and preview mode on a test
  plugin producing a non-empty PNG of the requested size.
- `test.sh` boundary check gains one step: `--preview` on `Examples/HelloTab`
  with a replies file answering its `/bin/date` call, expecting exit 0 and a
  PNG; and on a missing bundle, expecting exit 1 and the loader's sentence.
- `--window` is checked by hand.
