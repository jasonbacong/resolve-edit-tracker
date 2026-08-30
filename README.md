# Resolve Edit Tracker

A native macOS menu-bar app that automatically tracks how long you spend editing in
**DaVinci Resolve** — which page and timeline the time went to, and what you've earned.
It starts on its own the moment you open a project, so you never forget to hit "start".

[![CI](https://github.com/jasonbacong/resolve-edit-tracker/actions/workflows/ci.yml/badge.svg)](https://github.com/jasonbacong/resolve-edit-tracker/actions/workflows/ci.yml)
&nbsp;·&nbsp; macOS 14+ &nbsp;·&nbsp; DaVinci Resolve **Studio** &nbsp;·&nbsp; MIT

<!-- Add screenshots to docs/ and reference them here:
![Dropdown](docs/dropdown.png)
-->

## Why

The in-Resolve time-tracker scripts work, but they don't launch with Resolve and don't
start themselves — so sessions quietly go untracked. This runs as a normal menu-bar app:
launches at login, detects when you enter a project, and tracks in the background.

## Features

- **Auto-start / auto-stop.** Open a project → a toast slides down with a soft ping and
  tracking begins. Close the project, switch projects, quit Resolve, or put the Mac to
  sleep → the session is saved.
- **Desk-idle pause.** After N minutes with no keyboard/mouse input anywhere (default 1),
  the session stops and saves; it resumes on input. A manual pause auto-resumes if you
  keep working without hitting Resume.
- **Render-aware.** Optionally keeps tracking while Resolve is rendering instead of
  idle-pausing.
- **Per-page & per-timeline breakdown** — see where the hours actually went (Edit, Fusion,
  Color, Fairlight, Deliver…), per timeline.
- **Per-project rates.** Each project bills at the default rate unless you set an override.
  Earnings are stored per session at the rate in effect, so changing a rate never
  rewrites history.
- **History & Reports window** — edit or delete any session, add time manually, and export
  a printable **HTML timesheet** (print → Save as PDF) or CSV, filtered by project and
  date range.
- **Connection diagnostics.** If Resolve scripting is disabled or the helper can't run,
  the dropdown tells you — instead of silently doing nothing.

## Requirements

- **DaVinci Resolve Studio.** External scripting is a Studio-only feature; the free
  edition can't be tracked this way. Tested with Resolve 21.
- macOS 14 or later.
- `/usr/bin/python3` — present as soon as Xcode or the Command Line Tools are installed.
  It's only used to talk to Resolve's scripting API; no Python packages are needed.

## Install

1. Download `ResolveEditTracker-<version>.zip` from the
   [latest release](https://github.com/jasonbacong/resolve-edit-tracker/releases/latest).
2. Unzip and move **Resolve Edit Tracker.app** to `/Applications`.
3. The app is **not notarized**, so macOS will block the first launch. Either right-click
   the app → **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Resolve Edit Tracker.app"
   ```
4. Open it, then **Settings → Launch at login**.

There's no Dock icon — look for the timer icon in the menu bar.

## Build from source

```bash
git clone https://github.com/jasonbacong/resolve-edit-tracker.git
cd resolve-edit-tracker
./make_app.sh
cp -R "dist/Resolve Edit Tracker.app" /Applications/
```

Needs Xcode 16+ (Swift 6 toolchain). See [CONTRIBUTING.md](CONTRIBUTING.md).

## How it works

A small Python probe (embedded in the app, written to a temp file at launch) connects to
Resolve's scripting API and prints the current page, project, timeline and render state
every ~2 s. The Swift app reads that stream, runs the start/stop/idle state machine,
attributes each second to the current page and timeline, and persists sessions. A
watchdog restarts the probe if it hangs or dies. Idle time comes from Quartz Event
Services — **no Accessibility or Input-Monitoring permission required**. Notifications use
a custom panel, not Notification Center, so there's no permission prompt for that either.

### Where your data lives

`~/Library/Application Support/ResolveEditTracker/`

| File | Purpose |
|---|---|
| `sessions.json` | The session log — the source of every total and report |
| `settings.json` | Your settings (older files load fine; missing fields keep defaults) |
| `current.json`  | In-progress session, checkpointed every ~20 s for crash recovery |
| `debug.log`     | Rolling text log of state changes |

Everything is local. Nothing is sent anywhere.

## Source layout

```
Sources/ResolveEditTracker/
  Main.swift            entry point (AppKit, accessory app)
  App.swift             AppDelegate: status item, popover, Settings + History windows
  AppState.swift        state machine, tick loop, derived stats, sleep/wake
  Models.swift          Session / Settings / ResolveStatus / ConnectionState (tolerant decoders)
  ResolveMonitor.swift  runs & parses the probe, watchdog, connection state
  ProbeScript.swift     the probe (multi-path, render-aware), as a string
  IdleMonitor.swift     system-wide input idle
  SessionStore.swift    sessions.json / current.json
  Formatting.swift      time / money formatting + stats builder
  Timesheet.swift       printable HTML timesheet
  Toast.swift           fade-in/out notification panel
  MenuContentView.swift menu-bar dropdown (SwiftUI)
  SettingsView.swift    settings + per-project rates (SwiftUI)
  HistoryView.swift     session list, add / edit / delete, exports (SwiftUI)
  CSV.swift             export / import
  LoginItem.swift       launch-at-login (SMAppService)
  EventMonitor.swift    outside-click dismissal for the popover
  Log.swift             debug.log writer
```

## License

MIT — see [LICENSE](LICENSE).
