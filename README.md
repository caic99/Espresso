# Espresso ☕

A tiny native macOS menu bar app that keeps your Mac awake — like `caffeinate`
or Amphetamine, minus everything you don't need.

- Native `NSStatusItem` + `NSMenu` in the menu bar (SF Symbol cup icon,
  filled while active). No Dock icon, no windows.
- Keep-awake sessions: indefinitely, or 15 min / 30 min / 1 h / 2 h / 4 h.
  Timed sessions deactivate themselves. The menu header shows a live
  countdown, the active duration gets a checkmark, and **Deactivate**
  appears only while a session runs.
- Uses a native IOKit power assertion (`PreventUserIdleDisplaySleep`,
  the same mechanism as `caffeinate -d`) — no subprocesses.
- **Keep Display Awake** option (checked by default): uncheck it to let the
  display sleep while the system stays awake (`caffeinate -i` behavior).
  The choice is remembered across launches.

## Build & run

```bash
./make-app.sh
open build/Espresso.app
```

Requires macOS 13+ and Xcode command line tools. The bundle is ad-hoc signed.
To start it at login, add the app in
System Settings → General → Login Items.

## Scripting

`--activate [minutes]` starts a session at launch:

```bash
open build/Espresso.app --args --activate 30   # keep awake for 30 minutes
open build/Espresso.app --args --activate      # keep awake indefinitely
```

Verify the assertion is held:

```bash
pmset -g assertions | grep -A2 Espresso
```

## Notes

- Closing the lid still sleeps the Mac (as with `caffeinate`); the assertion
  prevents *idle* sleep only.
- Quitting Espresso (or the session timer expiring) releases the assertion
  immediately.
