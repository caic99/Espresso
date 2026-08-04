# Espresso ☕

A tiny native macOS menu bar app that keeps your Mac awake — like `caffeinate`
or Amphetamine, minus everything you don't need.

- Native `NSStatusItem` + `NSMenu` in the menu bar (SF Symbol cup icon,
  filled while active). No Dock icon, no windows.
- Keep-awake sessions: indefinitely, or timed via a native slider
  (15 min – 24 h, snapping to sensible stops; drag to preview, release on a
  new stop to start — the menu stays open and the header flips to the live
  countdown; your last position is remembered). Timed sessions deactivate
  themselves, and **Deactivate** appears at the top of the session group
  only while a session runs.
- The status header always explains the current state: while off it shows
  live "Display sleeps in … · Mac sleeps in …" countdowns from your actual
  power settings (naming other apps if they're holding the Mac awake);
  while on it shows the session countdown and the display policy.
- Uses a native IOKit power assertion (`PreventUserIdleDisplaySleep`,
  the same mechanism as `caffeinate -d`) — no subprocesses.
- **Keep Display Awake** option (checked by default): uncheck it to let the
  display sleep while the system stays awake (`caffeinate -i` behavior).
  The choice is remembered across launches.
- **Block Lid-Close Sleep** option (per-session): keeps the Mac awake even
  with the lid closed, via the root-only `pmset disablesleep 1` flag — the
  same mechanism as Amphetamine Enhancer's Closed-Display Mode. Guardrails:
  only available while a session is active and on AC power, and it turns
  itself off when the session ends, the app quits, or power is unplugged.

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
open build/Espresso.app --args --activate --block-lid   # also block lid-close sleep
```

Verify the assertion is held:

```bash
pmset -g assertions | grep -A2 Espresso
```

## Notes

- Without **Block Lid-Close Sleep**, closing the lid still sleeps the Mac
  (as with `caffeinate`); the assertion prevents *idle* sleep only.
  Alternative that needs no software: macOS clamshell mode (external display
  + AC power + external keyboard/mouse).
- Changing `disablesleep` requires root, and Espresso only engages the lid
  block when it can also *release* it unattended (session end, unplug, quit)
  — so it strictly uses passwordless `sudo -n`, never a password dialog that
  could go unanswered overnight. If passwordless sudo isn't available, the
  toggle refuses with instructions to add a scoped sudoers rule:
  `echo "$USER ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1" | sudo tee /etc/sudoers.d/espresso-lidsleep`
- The `SleepDisabled` flag is system-global. If Espresso is killed (not quit)
  while the lid block is engaged, it clears the leftover flag at next launch;
  `sudo pmset disablesleep 0` (or a reboot) also restores normal behavior.
- Quitting Espresso (or the session timer expiring) releases the assertion
  immediately.
