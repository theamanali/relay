# Session handoff (Mac ↔ PC)

The one file for passing work between the Mac session (`client/`) and the PC
session (`host/`, `tools/`). Do not create other handoff or retest files.

## How to use it

- **Before you start:** `git pull`, then read **Open**. Anything addressed to
  your machine is yours to do first, unless the user says otherwise.
- **Handing off:** add an item under Open: who it is for (→ PC / → Mac /
  → user), the date, what is needed and why, the steps, and what counts as
  done. Commit and push it before you stop.
- **Picking up:** work the item and write results into it as you go (dates,
  commits, installed hashes, what passed, what failed, what was not checked).
- **Closing:** once it is done, move the outcome into the README status table
  and the AGENTS.md status bullet, and delete the item here. Git history keeps
  the old text; nothing is archived in this file.
- Protocol changes still go host-first and land in `docs/PROTOCOL.md`; an item
  here only says what to implement or verify, never the wire contract itself.

## Open

### → user, on the PC: Windows service retests (from 2026-10-09)

Reboot-before-login, sign-out/reconnect and lock/unlock each passed once on
2026-10-09. Still needed: repeats, proof that setup works **before any
Windows user session exists** (in the one pass, a `SessionLogon` preceded the
post-reboot connection), and a crash of the **service process** itself. A
killed *worker* already restored correctly (U6, 2026-10-17). These black out
the PC's monitors, so the user runs them; agents read the logs afterwards.

**Setup**

1. Elevated, at the repo root: `.\tools\install-host.ps1 -SkipDriver`. Confirm
   **Start on system boot** is on and auto-login is off.
2. Copy `%ProgramData%\Relay\host.log` aside. Note the start time and the
   time of every step below.
3. Signed in locally, connect at 3024×1964@120, disconnect, and check that
   both physical monitors, the primary, positions and refresh rates return.

**Reboot before login (3 times)**

1. Reboot. Do not sign in at the PC or restart Relay by hand.
2. Connect from the Mac as soon as the PC appears; note the delay after the
   reboot. The login screen should show and take input.
3. Disconnect at the login screen; the physical monitors should show it.
4. Reconnect, sign in from the Mac; streaming should survive sign-in at the
   same mode. Disconnect, check the layout, reconnect without a PIN.
5. If a connect fails: stay signed out, retry after 15 s and after 60 s, note
   each result, only then sign in locally and retry. Save host.log.

**Sign out while streaming (3 times)**

1. Stream at 3024×1964@120, sign out of Windows from the Mac.
2. Back at the picker, reconnect as soon as the PC appears; note the delay.
   Login-screen video and input should work.
3. Disconnect while signed out and check the monitors. Reconnect, sign in
   from the Mac, disconnect, check the layout. Same 15/60 s retries on failure.

**Lock regression (once):** lock and unlock while streaming; disconnect while
locked, connect to the locked PC, unlock from the Mac, disconnect, check the
layout.

**Service process crash (new):** while streaming, elevated:
`Stop-Process -Id (Get-CimInstance Win32_Service -Filter "Name='Relay'").ProcessId -Force`.
Record whether the service manager restarts the service, whether the monitors
and layout return, and whether the Mac reconnects. The expected behaviour is
not specified anywhere yet; dark monitors are a finding, not a mistake.

**Reading host.log**

- Before-any-session proof: for each reboot run, the connection's topology
  lines must come **before** any `SessionLogon` line.
- Good topology operations log matching nonzero `session`/`console`,
  `station=WinSta0` and a `bound` desktop equal to the input desktop
  (`Winlogon` at login/lock, `Default` after sign-in).
- `OpenInputDesktop`/`SetThreadDesktop` failures, mismatched sessions or
  SetDisplayConfig error 5 mean context/access. An old worker rejected after
  the console changes is expected; the new worker must retry the saved restore.
- Zero active paths or changing query sizes mean readiness/churn. A missing
  virtual monitor or a mode mismatch after a good binding points at driver or
  topology state: keep the exact error and the path/mode counts before it.
- Error 87 with flags `0x24a0` means the old binary is still running. A
  successful restore clears the snapshot; a failed one must keep it.

Done when every run above has a recorded result and the logs have been read;
then update the README checklist item and the AGENTS.md "Topology context"
and Milestone 4 notes.

### → user: pair-only name survives a service restart (from 2026-10-10)

The Mac's name already shows in the PC's tray Forget menu right after
Pair-only. Check that it is still there after a restart:

1. On the Mac, Forget the PC, then Pair (enter the PIN) and stop; do not
   Connect.
2. PC tray ▸ Forget paired MacBook: the Mac's name is listed.
3. Elevated: `Restart-Service Relay`. Open the submenu again: the name is still
   there.

Done when reported; then tick the README checklist item and update the
"Pair-only name fix" bullet in AGENTS.md.
