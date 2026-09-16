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

`relay-host --no-vdd` + `probe --hz 120 --wiggle`, so the capture
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

## Phase-locked capture (done, 2026-09-16)

The native path captures on its own thread now. It polls `AcquireNextFrame(0)`
every 200 µs on a high-resolution timer and folds every new desktop frame
into the composition texture; pictures go to NVENC on a **steady** 1/fps
tick whose **phase is servoed** to land `TARGET_LEAD` (1.2 ms) after DWM's
present, using `LastPresentTime`. Each tick moves by at most 0.4 ms, and only
when two consecutive ticks had fresh content (so 30/60 fps video does not
steer it). `timeBeginPeriod(1)` is set for the session.

Same probe loop, three consecutive sessions:

| | frame age at submit (avg / max, settled) | encode |
|---|---|---|
| before (free-running tick) | 0.7 / 7.4 / 5.5 / 2.6 ms per session, max 8.5 | 3.3–3.8 ms |
| after | **1.20 / 1.20 / 1.20 ms**, max 1.6 | 3.1–3.5 ms |

Two things tried on the way, both measured on the real cable with the Mac:

- **Blocking in `AcquireNextFrame(timeout)`** made encode take exactly one
  frame interval (8.1 ms). With `ID3D11Multithread` protection on, the
  waiting thread holds the device lock and NVENC's DirectX input pass cannot
  finish the previous picture until the wait returns. Hence the 200 µs poll.
- **Submitting the instant a frame arrives** (no tick) gave 0.55 ms age on a
  hardware monitor but bunched sends on the virtual display: the MTT
  driver's vblank is a software timer that jitters by milliseconds, and the
  Mac's decode counter swung 110–130 with visible judder against its own
  fixed refresh. The steady servoed tick keeps the even cadence and costs
  ~0.7 ms over the pure event-driven number.

Cost: the whole host process is ~12% of one core at 120 fps. Item 3 (thread
hops) is moot: encrypt+send is 0.07 ms and the output worker → server hop is
the only one left. Items 4 and 5 remain.

**Verified on the real cable (2026-09-16, Mac at 3024×1964@120):** decode
counter on the Mac steady at 120; host log during continuous motion
`desktop frame age at submit avg 1.13–1.19 ms, max 1.9–2.0 ms (595–599 fresh)`,
so the virtual display's vblank jitter is under a millisecond once locked.
Encode at 6 MP is 4.3–5.9 ms, the ×1.6 pixel scaling of the 1440p number,
and is now the only host stage of any size.

## Colour signalling (item 5, done 2026-09-16)

The in-process path now writes a VUI colour description: matrix SMPTE 170M
(BT.601, which is what NVENC uses for its internal ARGB->YUV conversion),
primaries and transfer BT.709 (sRGB's), limited range. Verified with
`ffprobe` on probe dumps for both HEVC and H.264. The ffmpeg fallback already
signalled a 601 matrix (`bt470bg`, same coefficients) from ddagrab's frame
metadata, so it was left alone. The Mac's Metal shader takes the matrix from
the pixel buffer, so no client change is needed.

## Item 4 results (2026-09-16, real Mac, Valorant launcher trailer as motion)

Mac overlay, read after 10 s of continuous motion with the overlay hidden:

| | default | `--intra-refresh` |
|---|---|---|
| Rx→present mean / p95 | **4.15 / 5.31** | 4.84 / 7.28 |
| Rx→decode p50 | 2.55 | 2.83 |
| Host work p50 / p95 | 5.89 / 6.46 | 6.01 / 6.63 |

Intra-refresh makes every frame a little bigger and slower to decode, while
a 2 s IDR is one big frame in 240 that the p95 barely sees. It stays off.
For reference the same overlay on the free-running host this morning read
4.73 / 7.08: the phase-locked tick took 1.8 ms off the client p95 with the
mean nearly unchanged, which is the bunching gone.

Note the client connected over the LAN (global IPv6), not the cable; RTT/2
moved 3.1 → 4.1 ms between two runs on identical settings, so treat
sub-millisecond differences on this link as noise. `--codec h264` and
`--scale 0.75` are still untested.

## Thread priority and tighter lead (2026-09-16)

The capture and output-worker threads raise themselves to `THREAD_PRIORITY_HIGHEST`
so a game's render threads cannot delay a poll or a bitstream read (the delay
would land in the client p95). `TIME_CRITICAL` was tried first and is wrong: at
the realtime band it starves DWM and the GPU scheduler, and the virtual display
stops presenting (capture drops to a handful of fresh frames per 600). `TARGET_LEAD`
is lowered 1200 -> 800 us now that the measured vblank jitter is under a millisecond;
frame age at submit settles around 0.5-1.0 ms.

GPU BGRA->NV12 conversion (feeding NVENC NV12 instead of ARGB) was built and
measured: encode was identical to the ARGB path at 6 MP (4.4 / 6.2 ms both), so
it was reverted. NVENC's internal RGB->YUV is effectively free on Ampere. Colour
stays correct via the BT.601 VUI tag from item 5.
