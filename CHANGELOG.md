# Changelog

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
