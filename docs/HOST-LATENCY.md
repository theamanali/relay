# Host latency — note for the PC session (2026-09-16)

**From the Mac session.** The client presentation path has been reworked and
measured on the real cable (details and numbers in `docs/CLIENT-LATENCY.md`).
Where things stand, per frame at 3024×1964@120, HEVC, default settings:

| stage | ms | source |
|---|---|---|
| Host work (capture + encode + send) p50 / p95 | **6.0 / 6.9** | FRAME_TIMING, unchanged across four runs |
| RTT/2 estimate | 1.3–3.3 | FRAME_TIMING, swings between runs |
| Client decrypt→decode p50 | 2.6 | VideoToolbox, hardware |
| Client decrypt→scanout mean / p95 | 4.7 / 7.1 | Metal presenter, direct-to-display |

The client is now decode plus a ~2 ms average wait for the Mac's next refresh.
There is no big lever left on that side. Host work is the largest measured
stage and hasn't moved. Nothing below changes the wire protocol.

## 1. Which of capture / encode / send is the 6 ms?

FRAME_TIMING already carries the three fields separately but the client only
shows their sum. Read the host's own `native latency avg` log line during a
session and note capture vs encode. Earlier notes say encode ≈3.3 ms, capture
≈0.2 ms; if that still holds, ~2.5 ms is unaccounted for — probably
`send_us` (encrypt + `write`) or the hop from the output worker through the
channel to the server thread. Knowing which decides everything below.

## 2. Capture is paced by the host clock, not by the desktop

`native_nvenc.rs` `next_access_unit` captures on its own 120 Hz tick with
`AcquireNextFrame(0)` — i.e. whatever DWM last presented to the virtual
display. That frame can be anywhere from 0 to 8.3 ms old at the moment it's
grabbed, and no telemetry sees that wait because `capture_started` begins
after the acquire returns. The virtual display refreshes at 120 Hz on its own
vblank, so the alternatives are:

- **Event-driven:** block in `AcquireNextFrame(timeout ≈ frame_interval)` and
  submit to NVENC the instant a new desktop frame lands, dropping the pacer's
  `sleep_until`. This removes the host-side phase beat entirely. The pacer
  still matters as a fallback when the desktop is static (DDA delivers nothing).
- If keeping the pacer, phase it just after the virtual display's vblank so
  the acquire finds a fresh frame. Harder to get right; try the first.

This is the single most likely multi-millisecond win and is invisible to the
current numbers.

## 3. Thread hops on the output path

Encoded picture → `output_worker` (event wait, bitstream lock/copy) → channel →
`next_access_unit` on the encoder thread → server thread → encrypt → `write`.
Each hop is a scheduler wake, ~50–200 µs on Windows at default timer
resolution. Two things to check: whether `timeBeginPeriod(1)` is set for the
process (without it the thread sleeps and `recv_timeout` quantise to ~15.6 ms
in the worst case), and whether the output worker could encrypt and send
directly rather than bouncing through two more threads.

## 4. Experiments needing no code

- `--intra-refresh`: exists, defaults off. Keyframes at 6 MP are large and
  show up as a periodic latency spike in the client's p95. Turn it on and
  compare host p95 and client p95.
- `--codec h264`: compare encode ms. If H.264 encodes noticeably faster on this
  GPU at P1, that's a free win; the Mac decodes both in hardware.
- Mac `--scale 0.75`: halves the pixel count for both encode and decode. Use
  it to see how much of the 6 ms scales with resolution.

## 5. Not latency, but do it while in the encoder config

`init.bufferFormat = ARGB` (native_nvenc.rs:331) with no VUI colour
signalling. NVENC's internal RGB→YUV uses BT.601 limited-range coefficients;
the client (any client) decodes as BT.709 by default because nothing says
otherwise. Either set `colourPrimaries / transferCharacteristics /
matrixCoefficients` in the HEVC/H.264 VUI to 601, or have NVENC convert with
709. Mildly wrong saturation until then.

## What the Mac session can do next

Once capture is event-driven on the host, the remaining beat is the Mac's
refresh. Phase-locking the two clocks would need the client to report its
vblank phase and the host to align capture to it — a protocol change, so
host-first per the usual rule. Only worth it after items 1–3.

## Measurements from the PC session (2026-09-16)

`traveldisplay-host --no-vdd` + `probe --hz 120 --wiggle`, so the capture
source is the PC's 2560x1440@120 primary rather than the 6 MP virtual
display; encode scales with pixels (×1.6 for the Mac mode), the rest does not.

**Item 1 — the split.** Per frame, averaged over 600-frame windows:

| stage | ms |
|---|---|
| capture (desktop copy + cursor + slot copy + submit) | 0.19–0.27 |
| encode (submit → NVENC output ready) | 3.2–3.8 |
| encrypt + `write` | **0.06–0.07**, max 0.28 |

`send_us` is not the missing 2.5 ms; nothing on the output path is. The
6.0 ms host figure on the Mac is NVENC at 3024×1964 (≈ 3.5 × 1.6) plus the
small fixed parts. The old "encode ≈ 3.3 ms" was a 1440p number.

**Item 2 — frame age at acquire.** The native path now logs
`desktop frame age at acquire` (QPC now − `DXGI_OUTDUPL_FRAME_INFO.LastPresentTime`)
alongside capture/encode. Four consecutive sessions, identical settings:

| session | avg age | max |
|---|---|---|
| 1 | 0.7–1.3 ms | 8.5 |
| 2 | 7.4 ms | 8.4 |
| 3 | 5.3–5.8 ms | 6.4 |
| 4 | 2.4–2.9 ms | 3.4 |

The age is **not** uniform per frame: the pacer's phase is fixed by whenever
the first frame arrived and then free-runs against the display's vblank at the
same nominal rate, drifting ~0.5 ms per 5 s. So each session draws a random
0–8 ms of hidden latency and keeps it. This is invisible to FRAME_TIMING and
to the Mac's numbers, and is the largest single host-side stage in a bad
session — bigger than encode. Event-driven capture (block in
`AcquireNextFrame`) removes it; that is the next change.
