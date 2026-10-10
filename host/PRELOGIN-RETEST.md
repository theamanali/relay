# Pre-sign-in topology retest — 2026-10-09

## Evidence and scope

The user verified real v4 pairing (existing/fresh/wrong PIN), Forget from either
side, reconnect without a PIN, and 3024×1964@120 streaming. Disconnect restoration,
lock/unlock during streaming, and connecting while locked passed. One reboot and
login-screen connection followed by remote sign-in passed. An earlier reboot and
sign-out/reconnect failed until local sign-in.

The sign-out log shows a new SYSTEM worker in session 2 accepting CLIENT_HELLO.
Startup restore and connection setup both encountered SetDisplayConfig error 5;
the original exclusive apply error was obscured by an invalid flags retry (87),
and the GDI fallback returned DISP_CHANGE -1. Therefore worker launch, pairing and
transport succeeded. The log lacks thread-desktop information and does not prove
whether desktop context alone explains the failure.

[Microsoft documents error 5](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig)
as lack of console/current-desktop access, and permits ALLOW_PATH_ORDER_CHANGES
only with TOPOLOGY_SUPPLIED. The removed retry combined it with
USE_SUPPLIED_DISPLAY_CONFIG. DISP_CHANGE -1 is generic; it does not establish a
mode, permission or readiness cause by itself.

Setup inherited Default; restoration also ran on the window-owning tray thread.
Topology now executes on scoped threads bound to the input desktop. It logs actual
and console sessions, station, thread and input desktops, and layout/monitor facts.
The process window station and existing capture/input binding are unchanged.
Read-only queries wait at most two seconds per query/empty-layout phase. Access
denials stop fallback; saved snapshots remain available for recovery. No MTT pipe
commands or repeated modesets were introduced.

## Validation so far

- `cargo test`: 134 passed; the interactive test is opt-in.
- `cargo test topology_binding_is_scoped_and_errors_propagate -- --ignored --nocapture`:
  passed on this Windows PC while signed in. Creates a hidden window, verifies
  topology executes on another thread, checks error propagation and unchanged
  caller context, and takes a read-only CCD snapshot. No display changes.
- `cargo clippy --all-targets -- -D warnings`, `cargo build --release`,
  `cargo fmt --check`: passed.
- The user subsequently installed the fix and reported all three retests passed
  once (reboot-before-login, sign-out/reconnect and lock/unlock), with no observed
  failure. Agent did not run exclusive-display tests. Repeat runs and service
  crash-restore verification remain pending.

## First hardware retest report — October 9, 2026 (Pacific)

The installed executable and locally built release executable have the same
SHA-256: `991E516AC4362F07D9ADCF453503655CBA50F435318AB2B9A6B403546691F737`.
The log's timestamps below are UTC (October 10 UTC is still October 9 Pacific).

- 00:39:10: 3024×1964@120 exclusive streaming; 00:39:16: layout restored and VDD
  disabled after normal disconnect.
- 00:41:00–00:41:10: lock/unlock interrupted capture, which recovered in about
  1.1 seconds per restart and resumed approximately 120 fps.
- 00:41:23: shutdown cleanup re-enabled physical monitors and removed the VDD.
  A concurrent capture recovery attempt found no MTT1337 monitor; this warning
  did not prevent restoration. The restore thread changed from Default to
  Winlogon, with process session and console both 2; saved layout restore succeeded.
- 00:41:58: service started after reboot; Windows logged SessionLogon in session 1,
  then SessionLock. The 00:42:04 connection configured the display on Default and
  streamed at the requested mode, recovering through SessionUnlock at 00:42:13.
- No SetDisplayConfig error 5/87 or DISP_CHANGE -1 recurred in the reviewed log
  after installation. A service-process DPI-awareness warning is separate from
  topology setup. The last stream was still active when inspected, so its saved
  display snapshot was expected to exist.

The user's one-pass report covers all three scenarios. The log independently
confirms the outcomes above, but SessionLogon **preceded** the post-reboot connection;
it does not establish that connection occurred before any Windows user session
existed. It also does not separately corroborate a post-fix sign-out → ConsoleConnect
→ pre-logon connection sequence. Preserve those evidence limits when reporting
status; do not infer automatic sign-in as a proven cause. On repeat runs, distinguish
the visible lock/login screen from whether Windows has already created a user session.

## Install and baseline (user-run)

1. Disconnect Relay. From elevated PowerShell at the repository root, run
   `./tools/install-host.ps1 -SkipDriver`. This deploys the rebuilt executable and
   restarts the service. Confirm **Start on system boot** is enabled.
2. Save the existing `%ProgramData%\Relay\host.log` separately; retain the log
   rather than deleting snapshots or pairing state. Note the test start time.
3. With local sign-in, connect at 3024×1964@120, then disconnect. Confirm both
   physical monitors, primary monitor, positions and refresh rates return.

## Reboot before login (repeat three times)

1. Reboot the PC. Do not sign in locally, use auto-login, or restart Relay manually.
2. As soon as Relay appears on the Mac, connect. Record how long after reboot it
   was attempted. Confirm the login screen appears and input works.
3. Disconnect **while still at the login screen**. Confirm physical monitors
   return to the login screen. Reconnect, then sign in using the Mac.
4. Confirm streaming survives sign-in at the requested mode. Disconnect and
   verify the normal physical layout, then reconnect without a PIN.
5. If an attempt fails, stay signed out. Retry once after 15 seconds and once
   after 60 seconds. Record each time/result. Only then sign in locally and retry
   as a control. Save host.log after local access returns. This distinguishes an
   early readiness window from a failure that persists until sign-in.

## Sign out while streaming (repeat three times)

1. Start a normal 3024×1964@120 stream. Sign out of Windows through the Mac.
2. Allow the old stream to end and return to the picker. Reconnect as soon as the
   host is available, before any local sign-in. Record the delay.
3. Confirm login-screen video and input. Disconnect while still signed out;
   verify physical monitors return. Reconnect and sign in using the Mac.
4. Disconnect after sign-in and verify the original physical layout. Use the same
   15/60-second retries and local-sign-in control if a connection fails.

## Regression checks and log interpretation

- Lock and unlock during an active stream. Disconnect while locked, connect to
  the already-locked PC, unlock remotely, then disconnect and check restoration.
- Separately test tray Exit and Ctrl-C restoration as appropriate; service crash
  restore remains an additional user-run check, not claimed verified here.
- Successful topology operations should log matching nonzero `session`/`console`,
  `station=WinSta0`, and a `bound` thread desktop matching the input desktop
  (`Winlogon` at login/lock, `Default` after sign-in).
- `OpenInputDesktop`/`SetThreadDesktop` failure, mismatched sessions, or error 5
  indicate context/access. An old worker rejected after the console changes is
  expected; the new worker must retry the saved restore.
- Zero active paths or continually changing query sizes indicate readiness/churn.
  A missing virtual monitor, mismatched mode, or non-access apply failure after
  successful binding points toward driver/topology state; retain the exact error
  and preceding path/mode counts. A stable bound context plus error 5 is still an
  access failure requiring further investigation, not proof of a stale layout.
- Error 87 with flags `0x24a0` means the old binary is still running. A successful
  restore clears the snapshot; failure must retain it. Keep the full host.log
  covering worker exit, session changes, new worker startup and every attempt.

Pair-only “paired <IP>” naming is a separate follow-up. This change does not alter
the protocol or client.
