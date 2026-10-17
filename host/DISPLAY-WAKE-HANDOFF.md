# Windows handoff: wake the displays before a session starts

Written by the Mac session on 2026-10-17. **Status: not started on Windows.**
The Mac side shipped on its own (see "Mac side, done" below); this file is the
PC session's to implement, verify and update.

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
