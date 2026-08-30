# Changelog

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
