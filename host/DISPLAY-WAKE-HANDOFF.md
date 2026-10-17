# Windows handoff: wake the displays before a session starts

Written by the Mac session on 2026-10-17. **Status: done on Windows
2026-10-17** (host commit `7b38109`, installed and verified on the real Mac;
see "Windows verification record" below). The mid-session freeze in the open
question is confirmed and **not fixed**.

## Symptom

When Windows has turned the displays off after inactivity, connecting from the
Mac hangs: the picker sits on "Connecting to GAMING-PC…" (or "Starting
3024×1964 @ 120 fps…") and never opens the stream. Waking the PC by hand fixes
it. No `host.log` from a stuck attempt was captured, so which of the two
stall points below it hits is not confirmed.

## Cause (from the code, not yet from a log)

1. **No frames.** While the displays are off, Desktop Duplication delivers no
   frames until there is input (`AGENTS.md`, "Hard-won facts"). The host sends
   STREAM_START and then nothing, and the Mac waits for a first frame that
   never comes. This is the most likely case.
2. **No STREAM_START.** STREAM_START goes out only after `acquire_display`
   returns (`server.rs`, after `KeepAwake::new()`). All of its waits are
   bounded (the longest is MTT's 30 s `APPEAR_TIMEOUT`), so this would be a
   long stall ending in an error rather than a permanent hang, but Windows
   display calls made while the outputs are powered down are untested.

Nothing in session setup wakes the displays. `KeepAwake` sets only
`ES_SYSTEM_REQUIRED`, deliberately (next section).

## The change

In `handle_session` (`host/src/server.rs`), after `DisplayClaim::acquire`
succeeds and before `acquire_display`:

- **Wake the displays with one zero-distance mouse move.** `SendInput` with
  `MOUSEEVENTF_MOVE` and dx = dy = 0 (relative, so the cursor does not move;
  no button, no key). Windows counts it as user activity, turns the displays
  on and Desktop Duplication resumes. `SendInput` only works from a thread
  bound to the input desktop, so run it inside
  `desktop::with_input_desktop("wake displays", || …)`, as `acquire_display`
  does. A small `input::wake_displays()` beside the existing `SendInput`
  helpers in `input.rs` keeps it in one place. Log
  `woke displays before session setup` (or the error, and continue: a failed
  wake must not fail the session).
- **Do not add `ES_DISPLAY_REQUIRED` to `KeepAwake`.** Its comment records
  why: it applies to every physical connector and can wake monitors Relay has
  removed from the desktop. The wake above happens before those monitors are
  removed, so it only lights what the session is about to take over anyway.

No wire change: the Mac needs nothing from this to work.

## Open question to test before changing anything else

Does a session that sends no input (the Mac in Observe mode) freeze when
Windows' "turn off the display after" timer runs out mid-stream, with the
virtual monitor as the only display? If it does, the fix needs care: it must
not use `ES_DISPLAY_REQUIRED` (above). One option is to repeat the zero-move
nudge when capture has seen no new frame for a few seconds; check first
whether that lights the device-locked physical monitors.

## Windows verification

1. `cargo fmt --check`, `cargo test`, `cargo clippy --all-targets -- -D warnings`,
   `cargo build --release`.
2. Elevated `tools\install-host.ps1 -SkipDriver`; confirm the service runs the
   new hash.
3. Set Windows' display-off timeout to 1 minute, wait until the monitors go
   dark, then Connect from the Mac (Control mode off, so the Mac sends no
   input). Expect the stream within the usual 2–4 s, `woke displays before
   session setup` in `host.log`, and physical monitors and layout restored on
   disconnect.
4. Repeat at the lock screen with the displays off.
5. The open question: Observe mode, no input, past the display-off timeout.
   Record whether the stream keeps updating.
6. Put the timeout back to the user's setting.

## Windows verification record — 2026-10-17

Implemented as described: `input::wake_displays()` in `input.rs`, called from
`handle_session` right before `acquire_display` inside
`desktop::with_input_desktop("wake displays", …)`. Success logs `woke displays
before session setup`; a failure logs a warning and the session goes on.
`KeepAwake` is unchanged.

1. `cargo fmt --check`, 161 unit tests plus the probe integration test (the
   opt-in desktop test ignored), `cargo clippy --all-targets -- -D warnings` on
   1.98 and 1.99, `cargo build --release`: all pass.
2. Elevated `install-host.ps1 -SkipDriver`: service Running, installed
   `C:\Program Files\Relay\relay-host.exe` SHA-256 =
   `6335D2745E4408CA79C3AABCA7A3E78961E94FDEDC8C43983A241427252D5941`, the
   same as the release build.
3. The "turn off display after" timeout (Ultimate Performance plan) was
   15 min on AC and 3 min on DC; AC was set to 1 min. With the PC idle and the
   monitors dark (confirmed by the user), the real Mac connected in Observe
   mode (`input=false`) at 11:46:07.727 UTC: the wake line followed at
   .732, the virtual display was the only display at 11:46:09.47 and capture
   started at 09.80 with fresh frames at once (343 of 600 in the first 5 s),
   3024×1964 @ 120, HEVC 4:4:4 10-bit. Disconnect restored the physical
   monitors and layout (log and user).
4. Lock screen: SessionLock at 11:50:33, displays dark, Observe connect at
   11:51:58.390, wake line at .394, capture at 11:52:00.4 (about 2.0 s). The
   input desktop was reported as `Default` throughout. Desktop Duplication
   lost access twice (11:52:05, and 11:52:16 at SessionUnlock) and was
   recreated within about 1 s each time, the existing lock/unlock recovery.
   The user reported the stream worked; disconnect restored monitors and
   layout, matching that session's snapshot. (Windows had swapped the GDI
   names `\\.\DISPLAY1`/`2` of the two ACR monitors between the step 3
   session and this one; the restore follows the snapshot, not the names.)
5. **Open question answered: yes, it freezes.** In an earlier Observe session
   (connected 11:34:29, before the monitors had actually gone dark), the PC's
   last input was at 11:34:51. From 11:35:51, 60 s later, every 5-second
   capture report showed 0 fresh of 600 frames; the host kept sending 120 fps
   of the last picture. A topmost window with a clock redrawing 10 times a
   second, opened at 11:37:11 without any input, never appeared in capture or
   on the Mac. Disconnecting restored monitors and layout. Not fixed; the
   user decides how. The nudge idea above is untested, including whether it
   lights the device-disabled physical monitors.
6. The AC timeout is back to 15 min (`0x384`); DC was never changed.

Not exercised: the Mac's "The PC sent no picture" message against the old
host, and a wake failure path (the wake never failed).

## Mac side, done (2026-10-17)

`HostConnection` no longer waits forever after CLIENT_HELLO. If STREAM_START
has not arrived within 20 s the attempt ends "the PC didn't start the stream"
(picker: "The PC didn't start the stream — try again"). If the first FRAME has
not arrived within 10 s of STREAM_START it ends "the PC sent no picture"
(picker: "The PC sent no picture — wake it and try again"). Both limits are
`HostConnection.Options` fields. `Tools/test-pair-name.sh` covers both against
`fakehost` (`hang`, and the new `--no-frames`), plus a healthy stream that
must not time out. Against a host without the wake above, the Mac now shows
the second message within 10 s instead of hanging.
