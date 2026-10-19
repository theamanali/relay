# Receive → screen spikes, 2026-10-17

Status: **cause found and fixed (2026-10-17, later the same night):** pointer
motion while the app had the system cursor hidden with `NSCursor.hide()`. See
[Pointer motion with a hidden cursor](#pointer-motion-with-a-hidden-cursor).
The measurements below are the original, pre-fix investigation.

Source `0159395`, M3 Pro / macOS 27.0, real GAMING-PC, HEVC
3024×1964 @ 120 Hz, 120 Mbps, Balanced, 4:2:0 8-bit, Ethernet,
VSync off, detailed Relay HUD. Mostly static PowerShell content; its window
geometry changed between some runs. First three seconds excluded by Relay.
All times below are October 17 Pacific.

## Whole-session reports

| run | measured length | receive → screen p50 / p95 / p99 | receive → decode p50 / p95 | PC work p50 / p95 | shown | replaced |
|---|---|---|---|---|---|---|
| Initial Control, includes a 45 s Metal trace, ended 18:39 | 1:53 | 7.8 / 20.7 / 28.7 ms | 2.6 / 3.2 ms | 18.6 / 19.0 ms | 104.9 fps | 281 |
| Observe, no profiler or screenshots during sample, ended 18:44 | 0:44 | 14.0 / 27.5 / 35.5 ms | 2.8 / 3.3 ms | 18.6 / 19.0 ms | 106.7 fps | 16 |
| Control, no profiler or screenshots during sample, ended 18:45 | 0:46 | 17.3 / 34.4 / 35.5 ms | 3.0 / 3.3 ms | 18.6 / 18.7 ms | 60.1 fps | 2,278 |
| One connection, Control → Observe → Control, ended 18:48 | 1:26 | 30.8 / 35.3 / 36.6 ms | 2.9 / 3.4 ms | 18.7 / 18.7 ms | 41.6 fps | 5,796 |

RTT/2 medians were 1.1–1.5 ms. No late frames; the slow presentation runs
replaced many decoded frames rather than accumulating a compressed-frame queue.
Pointer stillness was requested for the first comparisons, but input activity
was not instrumented or independently confirmed. These are diagnostic samples,
not a controlled claim that Control is slower than Observe.

## Same-connection checks

After connecting with Control enabled, toggle Observe and Control without
reconnecting; wait 15 s after each toggle so the 1.5 s status banner and the
five-second HUD history have cleared. HUD snapshots:

| mode | receive → screen median / p95 | shown / decoded |
|---|---|---|
| Control | 26.8 / 34.0 ms | 53 / 107 fps |
| Observe | 30.5 / 35.0 ms | 43 / 107 fps |
| Control again | 30.9 / 35.2 ms | 40 / 107 fps |

Turning off forwarding did not clear the slow state. This rules out Control
being required for the failure; it does not rule out input activity as a trigger.

## Metal and system checks

- AC power, Low Power Mode off. The 45 s Metal System Trace reported nominal
  thermal state. Display-vsync intervals: 8.333 ms p50/p95/p99, 16.667 ms max.
- Exported Relay vertex/fragment GPU execution intervals had about 1.4 ms p99
  and 1.94 ms max. Recorded drawable waits: 521 intervals, 7.92 ms p95,
  10.69 ms p99, 15.13 ms max. These do not account for the full receive →
  screen tail; the trace also has measurement overhead.
- A separate launch with `MTL_HUD_ENABLED=1` reported **Direct**, **Game Mode
  On**, GPU 0.87 ms, frame interval 25.07 ms / 39.89 fps while Relay reported
  31.2 ms median, 35.5 ms p95, and 107 fps decoded. Thus compositing is not
  required for the slow state, and the low shown rate is corroborated by Metal.
- After resetting the computer-use runtime and leaving the stream untouched
  for 45 s, the same connection reported **Composited**, about 105 fps and
  7.9 ms median. Control stayed enabled. Raising/focusing the stream did not
  restore the slow Direct state. The runtime reset, presentation-mode change
  and improvement are correlated; none is established as the cause.

## Next diagnostic

Record per-frame decode completion, presenter queue entry, drawable wait,
command commit, GPU start/end and actual presentation, keyed by frame sequence.
Correlate slow frames with input-event counts and presentation-mode transitions.
The current receive → decode / receive → screen histograms cannot separate all
those waits. Keep measurements lightweight and validate with the observation
tools detached. Do not change encoder quality or assume a transport problem
to explain this post-decode delay.

Local trace: `/tmp/relay-latency-20261017-baseline.trace`; extracted summary:
`/tmp/relay-latency-trace-summary.txt`. Raw traces were not committed.

## Pointer motion with a hidden cursor

Reproduced on the Mac alone: bundled `Relay --host 127.0.0.1:8479` against
`fakehost hang --paired --clip <testsrc2 3024×1964, 120 fps HEVC> --size
3024x1964 --fps 120`, isolated `CFFIXED_USER_HOME`, VSync off. A small
CGEvent tool posted `mouseMoved` at 125 Hz in a circle for 16 s, then ⌃⌥⌘Q
(which logs the session report). 17 s sessions:

| run | shown fps | receive → screen p50 / p95 |
|---|---|---|
| idle pointer, `NSCursor.hide()` | 111.1 | 2.5 / 17.5 ms |
| moving pointer, `NSCursor.hide()` | 46.8–54.4 | 24.1–32.7 / 33.0–34.5 ms |
| moving pointer on **another display** (the app gets no mouse events) | 54.4 | 24.1 / 33.0 ms |
| moving, `--metal-vsync` (idle: 109.6 fps, 13.9 / 22.0) | 109.5 | 15.8 / 23.9 ms |
| moving, `maximumDrawableCount` 3 | 115.5 | 19.3 / 27.0 ms |
| moving, cursor not hidden | 101.7–110.3 | 2.5 / 16.3–31.9 ms |
| moving, transparent cursor via cursor rect (the fix) | 107.0–111.6 | 2.5 / 11.3–25.1 ms |
| idle, transparent cursor | 110.6 | 3.3 / 8.6 ms |

Receive → decode stayed at 1.5–2.5 ms throughout. Input forwarding and the
app's event handling are not involved (the other-display run); the system's
handling of a moving hidden cursor stalls VSync-off drawable turnaround. The
25.1 ms p95 run included a `screencapture -C` mid-session, which also showed
no Mac cursor over the stream. `StreamView.hidesCursor` now installs a
transparent 1×1 cursor over the view instead of hiding the cursor.
Not yet checked on the real PC or with a physical trackpad.
