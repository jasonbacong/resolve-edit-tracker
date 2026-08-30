# Contributing

Thanks for taking a look.

## Building

```bash
swift build            # debug
./make_app.sh          # assemble dist/Resolve Edit Tracker.app
./make_app.sh --zip    # + a distributable zip
```

Requires Xcode 16+ (Swift 6 toolchain) and macOS 14+. Running the app end-to-end
needs **DaVinci Resolve Studio** — external scripting is a Studio-only feature.

## Layout

`Sources/ResolveEditTracker/` — see the table in the README. The engine (state
machine, probe, persistence) is AppKit/Foundation; the three windows are SwiftUI.

## Pull requests

- Keep it lean. The menu-bar surface should stay small; depth belongs in the
  History and Settings windows.
- One behavioural change per PR where you can.
- `swift build` must be clean (CI runs it on macos-15).
- If you touch the persisted models, keep the tolerant `init(from:)` decoders in
  `Models.swift` working — old `sessions.json` / `settings.json` files must keep
  loading.
