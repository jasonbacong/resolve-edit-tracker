# Changelog

## v1.2.0

- **Renamed to Editor Tracker** (was Resolve Edit Tracker), now that it covers more than
  Resolve. The app is `Editor Tracker.app`, the process `EditorTracker` (so the pause
  shortcut is now `killall -USR1 EditorTracker`), and data lives in
  `~/Library/Application Support/EditorTracker/` — your existing folder is moved there
  automatically on first launch. The bundle ID is unchanged, and launch-at-login is
  re-pointed at the renamed app.

- **Premiere Pro, After Effects, Photoshop, Lightroom and Lightroom Classic** are tracked
  alongside Resolve. Whichever supported app is in front gets the time, and the menu-bar
  icon switches to that app's own icon. Switches must hold for 8 seconds before the
  session moves (the seconds are credited to the new app), so a quick look at another
  app doesn't split anything. Each app can be turned off in Settings → Apps.
- **Sequence and composition names** (opt-in). Premiere: project + active sequence,
  read from its window (needs Accessibility — Premiere's AppleScript can't report
  either). After Effects: project + active composition. Photoshop and Lightroom are
  app-level only by design. Playback in Premiere / After Effects defers idle-stop, as it
  does in Resolve. Saving an unsaved project relabels the session rather than splitting it.
- **History**: App column; choose the app when adding or editing an entry.
- **Timesheet**: App column, the timelines / sequences / comps worked on under each
  session, and a By-app summary with earnings.
- **Menu**: app icon in the header; Premiere / After Effects projects break down by
  sequence / comp; a per-app "today" row appears once you've used more than one app.
- Fix: a session frozen while you were away (or asleep) no longer has its end time
  stretched to when it was saved — timesheet spans match tracked time and adjacent
  sessions don't overlap.
- Fix: editing a session's note or project no longer rounds its duration to whole
  minutes or wipes its page / timeline breakdown.
- Existing history loads unchanged — every earlier session is recorded as Resolve.

## v1.1.0

- **Focus-aware tracking** (new, on by default — Settings → Tracking). The timer only
  runs while DaVinci Resolve is the active app. Switch to another app and it freezes;
  stay away longer than ~90 seconds and the session is saved. Click back into Resolve
  and it picks up where it left off. Turn the setting off for the old behaviour
  (track whenever a project is open, regardless of what's in front).
- **Playback and jog count as activity.** A moving playhead — whether from JKL, the
  spacebar, or a hardware panel like the Speed Editor that doesn't register as
  keyboard/mouse — no longer counts as idle. Reviewing a long cut won't pause tracking.
- **Resolve's own progress dialogs no longer trip the idle timer.** Transcribe
  subtitles, sync audio, cache, analyze — you're waiting on Resolve, not idle.
- **Project-switch flicker fixed.** Resolve briefly swaps in an empty "Untitled Project"
  while loading a project or running a modal task; the tracker was recording those as
  15-second sessions and false switches. It now ignores any project with no timelines,
  and a real switch has to hold for a few seconds before it's acted on.
- Idle-stop default raised from 1 to 3 minutes for new installs. Existing settings are
  unchanged.
- Backstop: playback or a modal task can't defer an idle-stop for more than 30 minutes.

## v1.0.1

- Fix: the timer no longer stops and restarts when Resolve puts up a progress dialog
  (transcribe subtitles, sync audio, cache, analyze, project load). Those briefly make
  the scripting API return no page; the tracker now treats "project loaded but Resolve
  is busy" as a distinct state and keeps tracking, attributing the time to the last
  known page. A session is only auto-stopped when Resolve quits, the scripting
  connection drops, the project is genuinely closed for 20 s+, or desk-idle triggers.
- Probe bridges short gaps where Resolve reports neither a page nor a project name, and
  no longer rebuilds its connection on every transient API exception.
- Safety net: if Resolve stays off-page for 15 minutes while tracking, the session is
  paused (auto-resumes on activity).

## v1.0.0

First public release.

- Auto-starts tracking when a project is opened in DaVinci Resolve Studio; toast +
  optional ping, then fades out.
- Menu-bar dropdown: today / this week / project total / earnings, per-page breakdown,
  live elapsed time.
- Desk-idle auto-pause and resume; manual pause auto-resumes if you keep working.
- Keeps tracking through renders (optional).
- Per-project hourly rates; earnings stored per session at the rate in effect.
- History & Reports window: edit / delete / manually add sessions; export a printable
  HTML timesheet or CSV, filtered by project and date range.
- Per-page and per-timeline time attribution.
- Connection diagnostics, multi-path Resolve detection, probe watchdog.
- Sleep/wake handling, crash recovery, launch-at-login.
- `killall -USR1 ResolveEditTracker` toggles pause.
