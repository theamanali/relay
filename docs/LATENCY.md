# Latency

How Relay's frame path was measured and tuned. The test setup was a 14-inch
MacBook Pro (3024×1964, 120 Hz) streaming from a Windows 11 PC with an NVIDIA
Ampere GPU, using HEVC with default settings.

## Results

Per frame, during continuous motion:

| stage | time |
|---|---|
| Capture (desktop copy, cursor, submit to the encoder) | 0.2 ms |
| Encode (NVENC, 6 MP) | 4.3–5.9 ms |
| Encrypt + send | 0.07 ms |
| **PC total**, p50 / p95 | **5.9 / 6.5 ms** |
| Mac: received → decoded, p50 | 2.6 ms |
| **Mac: received → on screen**, mean / p95 | **4.2 / 5.3 ms** |

How the Mac's time to screen changed as the work below landed:

| change | received → on screen, mean / p95 |
|---|---|
| Metal presenter, first clean measurement | 5.47 / 9.71 ms |
| + one socket read per message | 4.73 / 7.08 ms |
| + phase-locked capture on the PC | **4.15 / 5.31 ms** |

The work that mattered most was a bug that none of the existing numbers could
see (see [The hidden 0–8 ms](#the-hidden-08-ms)).

## What is measured, and what isn't

- **PC.** The native capture path logs the average capture time, encode time
  and frame age every 600 frames. Each video frame can be followed by an
  optional `FRAME_TIMING` message ([protocol](PROTOCOL.md)) carrying its
  capture, encode and send times.
- **Mac.** The latency HUD (⌃⌥⌘L or `--latency-stats`) shows received → on
  screen p50 and p95 over the last five seconds, with a per-frame sparkline
  against one refresh interval; its detailed view adds p99, PC work, RTT/2,
  received → decoded and the presenter's counters. "On screen" is the time
  Metal reports for each drawable through `addPresentedHandler`. Every
  session also keeps whole-session histograms (0.1 ms bins), logged as
  `Session report:` when it ends and shown in View ▸ Last Session Report,
  whose Copy button gives a Markdown table for this file.
- **Not measured.** Network transit (the protocol's RTT/2 is only an
  estimate), the decryption before the Mac's timestamp, and the display
  panel's own response time. Summing the stages does not give an end-to-end
  number. Measuring from screen to screen with a camera is still to do.

There are also three traps in reading the Mac's numbers:

- **The old overlay inflated what it showed.** It was a view on top of the
  Metal layer, so while it was visible macOS couldn't present the video
  directly to the display: 7.92 ms mean with it up, 5.47 ms after hiding it
  for a full 600-frame window. Since 2026-10-17 the HUD is drawn into the
  video frame itself (one blended quad in the same render pass), so the layer
  stays opaque and alone. Against `fakehost` at 3024×1964 / 120 fps the
  detailed HUD was on and Metal's own HUD (`MTL_HUD_ENABLED=1`) still said
  Direct, at 3.8 ms p50, and against the real PC the median was the same
  with it on and off (3.5 vs 3.4 ms; [below](#picture-options-and-the-hud-on-the-real-mac-2026-10-17)).
- **An open Netflix tab in Chrome throttles presentation, even paused.**
  Decode keeps up, but frames reach the screen only every 20–25 ms, so most
  are replaced before they are shown. It looked like a regression: every build
  tested (today's, the commit before the in-frame HUD, the commit before the
  SwiftUI migration) was slow while the tab was open. Metal still reports
  Direct and the built-in panel stays at 120 Hz, so it is neither compositing
  nor a refresh drop. An Instruments Metal System Trace showed the slow
  seconds as 400–700 ms of drawable waits each, with the GPU mostly in its
  Minimum performance state; keeping the GPU lightly busy from another
  process made no difference while the tab was closed, so that was not
  tested further. Close such tabs before measuring. fakehost, 3024×1964 at
  ~95 fps, 15 s runs, 2026-10-17:

  | Netflix tab | to screen p50 | p95 | shown | replaced |
  |---|---|---|---|---|
  | open, paused | 29.6 ms | 36.1 ms | 44.7 fps | 714 |
  | open, paused | 19.5 ms | 35.8 ms | 57.3 fps | 536 |
  | closed | 3.7 ms | 8.2 ms | 90.5 fps (all sent) | 52 |
  | closed | 3.6 ms | 8.4 ms | 92.1 fps (all sent) | 30 |

  Game Mode (macOS lowers background work's priority while a game is full
  screen) only partly helped while it was playing: 20 ms instead of 28 ms
  p50, alternating ~4 ms and ~30 ms stretches. Relay opts into it anyway
  (`LSApplicationCategoryType` games + `GCSupportsGameMode` in Info.plist);
  the kiosk window counts as full screen. The real-PC sessions of 02:39–02:56
  that day ran with the tab open and are not valid measurements.
- **The link matters.** Two runs with identical settings over a LAN switch
  had RTT/2 values 1 ms apart. Treat sub-millisecond differences measured over
  a LAN as noise.

## The PC: where the 6 ms goes

The first question was which stage takes the PC's 6 ms. One guess was that
about 2.5 ms was hiding in encryption or in handoffs between threads. Splitting
the time per stage ruled that out:

| stage | time (1440p test display) |
|---|---|
| capture | 0.19–0.27 ms |
| encode | 3.2–3.8 ms |
| encrypt + `write` | 0.06–0.07 ms (max 0.28) |

Encode time grows with pixel count. At the Mac's 6 MP, which is 1.6× the 1440p
test display, it is 4.3–5.9 ms. Nearly all of the PC's time is NVENC itself.
Nothing on the output path is worth optimizing.

## The hidden 0–8 ms

The capture loop ran on its own fixed 120 Hz timer and took whatever frame
Windows had last drawn to the virtual display. That frame could already be up
to 8.3 ms old when it was captured. This wait happens *before* the capture
timestamp starts, so no existing metric included it.

To make it visible, the PC now logs each frame's age when it is captured: the
current time minus the frame's `LastPresentTime` from Desktop Duplication.
Four sessions with identical settings showed four different results:

| session | average age | max |
|---|---|---|
| 1 | 0.7–1.3 ms | 8.5 ms |
| 2 | 7.4 ms | 8.4 ms |
| 3 | 5.3–5.8 ms | 6.4 ms |
| 4 | 2.4–2.9 ms | 3.4 ms |

The timer's phase was set by whenever the first frame arrived. After that it
ran freely against the display's refresh at the same nominal rate, drifting
about 0.5 ms every 5 seconds. Each session therefore drew a random 0–8 ms of
extra latency and kept it. In a bad session this wait was larger than the
encode.

### The fix: a steady timer, servoed to the display

The capture thread checks for a new desktop frame every 200 µs and keeps the
newest one. It hands frames to the encoder on a steady tick, one per frame
interval, and steers that tick's phase so it lands just after the virtual
display draws (1.2 ms after, at first):

- Each tick corrects a quarter of the phase error, and never moves by more than
  0.4 ms, so the frame interval stays even.
- The tick is only steered when two consecutive ticks saw a new frame. With
  30 or 60 fps video on screen, where a tick happens to land within the content
  is not a phase error.
- If the thread falls behind, it resumes from the current time instead of
  sending a burst of frames.

Result over three sessions: the frame age at capture was **1.20 ms in every
session** (max 1.6), down from a random 0.7–7.4 ms. On the Mac, the mean time
to screen barely moved, but the p95 dropped by 1.8 ms. The uneven delivery was
gone.

Two later changes tightened this further. The capture and output threads now
run at high priority, so a game's own threads can't delay a poll. With the
display's jitter measured at under 1 ms once locked, the target was lowered
from 1.2 ms to 0.8 ms. The frame age now settles at 0.5–1.0 ms.

Code: `host/src/native_nvenc.rs`, `CaptureLoop::step`.

### Two simpler fixes that failed

**Waiting inside `AcquireNextFrame`.** The obvious fix is to block until the
next frame arrives. That made every encode take exactly one frame interval,
8.1 ms. With `ID3D11Multithread` protection on, the waiting thread holds the
D3D11 device lock. NVENC needs that lock to read its input, so it couldn't
finish the previous frame until the wait returned. This is why the capture
thread polls instead.

**Sending each frame the moment it appears.** This gave a 0.55 ms frame age,
0.7 ms better than the servoed tick. But the virtual display's refresh comes
from a software timer in the driver, and that timer jitters by milliseconds.
Frames arrived bunched together, the Mac's decode rate swung between 110 and
130 fps, and motion visibly juddered. An even frame interval is worth more
than 0.7 ms.

## The Mac: decode and present

The first client handed compressed frames to `AVSampleBufferDisplayLayer`,
which decides when to decode and when to show a frame through its own queues.
It now has two stages it controls directly:

1. **Decode.** A real-time `VTDecompressionSession` decodes on the hardware
   decoder into IOSurface-backed buffers. Every compressed frame is decoded in
   order, because any of them may be a reference for later frames. A decoder
   generation counter discards output from a decoder that has been replaced.
2. **Present.** A single-slot mailbox holds the newest decoded image: a new
   frame replaces an unshown one instead of queuing behind it. A dedicated queue
   waits for a `CAMetalLayer` drawable (two drawables at most) and draws one
   aspect-fitted quad. The decoded YUV planes become Metal textures over the
   same IOSurface, with no copy. The color matrix and range come from the
   buffer's own attachments. The presenter replaced an earlier Core Image pass,
   which rebuilt a filter graph every frame.

With the overlay hidden and the layer opaque, macOS can present the video layer
directly to the display. The remaining gap between decode and present is mostly
the wait for the Mac's next refresh. The PC's tick and the Mac's refresh run on
independent clocks.

**One read per message.** The receive loop used to issue a 4-byte read for the
length, then a second read for the body. Now each read is sized to finish the
current message, and every complete message already in the buffer is handled
before the next read (`FrameReader.swift`). Mean time to screen dropped by
0.7 ms and p95 by 2.6 ms; most of the p95 gain was less jitter.

## Measured and rejected

| idea | result |
|---|---|
| Intra-refresh instead of periodic keyframes | Mac mean / p95 4.84 / 7.28 ms vs 4.15 / 5.31 ms. Every frame gets a little larger and slower to decode. With a keyframe every 2 s, 1 frame in 240 is large, and the p95 barely notices it. Off by default. |
| Converting BGRA → NV12 on the GPU before NVENC | Encode time was identical to feeding NVENC ARGB: 4.4 / 6.2 ms both. NVENC's own conversion is effectively free on Ampere. Reverted. |
| `THREAD_PRIORITY_TIME_CRITICAL` for capture | The realtime priority starved the desktop compositor and the GPU scheduler. The virtual display almost stopped drawing (a handful of new frames per 600). `HIGHEST` is used instead. |
| Blocking `AcquireNextFrame` | Encode took a full frame interval; see above. |
| Sending each frame as soon as it appears | 0.7 ms faster but visibly uneven; see above. |

## Found along the way: color

NVENC converts ARGB to YUV with BT.601 coefficients, but the stream didn't
signal that, and decoders assume BT.709 for HD video. Colors were slightly
oversaturated. The native encoder now writes the color description into the
stream (BT.601 matrix, BT.709 primaries and transfer, limited range). This was
checked with `ffprobe` for both HEVC and H.264. The Mac's shader reads the
matrix from the decoded buffer, so the client needed no change.

## Still open

- **Screen-to-screen latency with a camera**, the only way to measure what the
  user actually sees.
- **Locking the Mac's refresh to the PC's tick.** The Mac would report its
  vblank phase and the PC would align capture to it. This would remove most of
  the remaining wait for the next refresh. It needs a protocol change.
- **`--scale 0.75`.** Not measured yet; it encodes and decodes about half
  the pixels.

## HEVC vs H.264 (2026-10-10)

RTX 3080 Ti, M3 Pro, gigabit cable, 3024×1964@120, 120 Mbps, about a minute
of moving content each, one run per codec (`--latency-stats`, the Mac's
`Latency:` log lines every 5 s, medians of the eleven full-window readings):

| ms | HEVC | H.264 |
|---|---|---|
| PC work p50 / p95 | 6.14 / 6.73 | 6.09 / 6.56 |
| RTT/2 | 1.45 | 1.45 |
| Mac receive → decoded p50 | 2.68 | 3.65 |
| Mac receive → on screen, mean / p95 | 5.30 / 10.80 | 6.00 / 10.86 |
| Decode fps | 120 | 120 |

NVENC's encode time is not the PC's limit at this preset, and the Mac decodes
H.264 about 1 ms slower, so HEVC stays the default; `--codec h264` (Mac) or
`--codec h264` (PC) remains for measurements and for GPUs without an HEVC
encoder. The Mac decoded H.264 at a steady 120 fps despite the mode being
beyond H.264's common levels. Both runs showed occasional on-screen p95
spikes (16–19 ms, one or two per run, and ~30 ms while the first window
filled), so they are not the codec's.

## Picture options and the HUD on the real Mac (2026-10-17)

RTX 3080 Ti → M3 Pro over the cable (USB 2.5G adapter, `en11`), 3024×1964 @
120 Hz, 120 Mbps (automatic), VSync off, observe mode (no input sent), the
installed service. The PC's screen had moving content (113–115 fps shown at
Fastest), the same for every run; no Netflix or other video tab open on the
Mac. Seven conditions, each differing from the baseline in one setting, 45 s
per session, run twice: forward order, then reverse, so drift over the
13 minutes affects every condition equally. Each value is the two runs'
mean, from the session reports.

| setting | PC work p50 / p95 | RTT/2 p50 | receive → decode p50 | receive → screen p50 / p95 | shown | replaced per run |
|---|---|---|---|---|---|---|
| Fastest, 4:2:0, 8-bit, HUD on (baseline) | 4.5 / 5.0 ms | 0.9 ms | 2.3 ms | 3.5 / 8.3 ms | 114.0 fps | 258, 239 |
| Balanced | 18.7 / 19.4 ms | 0.8 ms | 2.2 ms | 3.5 / 6.7 ms | 102.1 fps | 189, 173 |
| Best quality | 22.7 / 23.6 ms | 0.9 ms | 2.3 ms | 3.9 / 6.9 ms | 85.5 fps | 91, 72 |
| 4:4:4 | 6.8 / 7.7 ms | 0.8 ms | 3.4 ms | 4.7 / 8.3 ms | 114.9 fps | 214, 186 |
| 10-bit | 4.5 / 5.1 ms | 0.8 ms | 2.2 ms | 3.5 / 7.3 ms | 114.4 fps | 250, 199 |
| 4:4:4 + 10-bit | 7.0 / 7.6 ms | 1.0 ms | 3.7 ms | 5.1 / 9.2 ms | 113.1 fps | 300, 253 |
| HUD off (baseline otherwise) | 4.5 / 5.0 ms | 0.7 ms | 2.1 ms | 3.4 / 17.0 ms | 110.9 fps | 437, 329 |

Adding PC work, RTT/2 and receive → screen (p50) as a rough per-frame
comparison (not input-to-photon): baseline 8.8 ms, 10-bit 8.7 ms, 4:4:4
12.3 ms, 4:4:4 + 10-bit 13.1 ms, Balanced 23.0 ms, Best 27.4 ms.

- **Balanced and Best can't keep up at this size.** They delivered 102 and
  86 fps, and PC work rose to 18.7 and 22.7 ms, far past the 9.6 and 11.6 ms
  extrapolated from 1440p (below). Once encoding takes longer than the 8.3 ms
  frame interval, frames presumably wait for the single NVENC engine, so PC
  work includes that queueing; the frame rate is the cleaner measure. Fastest
  stays the default.
- **4:4:4 costs about 3.5 ms**: 2.3 ms more on the PC and 1.1 ms more decode
  on the Mac, at full frame rate. With 10-bit added it is 4.3 ms.
- **10-bit on its own costs nothing measurable** at either end (4.5 ms PC
  work, 2.2 ms decode, 3.5 ms to screen, as the baseline). The 10-bit
  presenter path (`bgr10a2Unorm` layer) is not slower.
- **The in-frame HUD costs nothing measurable.** Median time to screen was
  3.5 ms with it on and 3.4 ms off. The two HUD-off runs had the worst p95
  and the most replaced frames of the whole set, the opposite of what a HUD
  cost would cause. They ran back to back in the middle of the sequence, so
  that is presumably variation in the PC's content; across all runs p95 varied
  from 5.9 to 10.0 ms within a single setting, so p95 differences of a few
  milliseconds between runs are noise.
- Not measured: image quality, other bitrates, glass-to-glass latency, a
  static desktop, or Wi-Fi.

## Encoder quality, 4:4:4 and 10-bit on the PC (2026-10-10)

RTX 3080 Ti, a `--no-vdd` dev host streaming the PC's own 2560×1440@120 primary
monitor to `probe` over loopback, 120 Mbps, about 8 s per setting. The desktop
was mostly static (a terminal and this app updating), so these are not the
Mac's moving-content numbers. PC work (capture + encode + send) comes from
about 240 FRAME_TIMING samples per run, the same sum the Mac's overlay shows;
encode is the host's 600-frame average.

| setting | profile, pix_fmt | `video_format` | PC work p50 / p95 | encode avg | fps |
|---|---|---|---|---|---|
| Fastest (P1), 4:2:0 8-bit | Main, yuv420p | 0x01 | 4.08 / 4.39 ms | 3.36 ms | 117.6 |
| Balanced (P4) | Main, yuv420p | 0x02 | 6.16 / 6.25 ms | 5.96 ms | 119.1 |
| Best (P6) | Main, yuv420p | 0x03 | 7.39 / 7.50 ms | 7.18 ms | 117.5 |
| Fastest, 4:4:4 | Rext, yuv444p | 0x05 | 5.68 / 5.93 ms | 4.92 ms | 119.1 |
| Fastest, 10-bit | Main 10, yuv420p10le | 0x09 | 3.91 / 4.42 ms | 3.26 ms | 119.2 |
| Fastest, 4:4:4 10-bit | Rext, yuv444p10le | 0x0d | 5.82 / 6.07 ms | 5.11 ms | 119.1 |
| H.264, Best, both flags asked | High, yuv420p (flags ignored) | 0x03 | 6.07 / 6.28 ms | 5.66 ms | 116.7 |

- 10-bit costs nothing measurable. 4:4:4 adds about 1.6 ms of encode, Balanced
  about 2.6 ms and Best about 3.8 ms over Fastest.
- Encode time grows with pixel count (the Results above: 1440p 3.2–3.8 ms, 6 MP
  4.3–5.9 ms). Scaled by the Mac's 1.61× pixel count, Fastest would be about
  5.4 ms, 4:4:4 about 7.9 ms, Balanced about 9.6 ms and Best about 11.6 ms.
  This is an estimate, not a measurement. If it holds, Balanced and Best can't
  keep 120 fps at 3024×1964, because the GPU has a single NVENC engine, and
  4:4:4 has little headroom. This is why the real-Mac A/B matters and why
  Fastest stays the default.
- Every dump decoded in ffprobe/ffmpeg without errors, with the BT.601 matrix,
  BT.709 primaries and transfer and limited range intact. In the 4:4:4 dumps
  the U plane differs from its own 2×2-averaged copy (PSNR 39.8 dB; an
  upsampled 4:2:0 plane would be identical), so NVENC encodes full-resolution
  chroma straight from the ARGB input.

## Reproducing

PC, without the virtual display (doesn't black out the PC's monitors):

```powershell
relay-host --no-vdd
probe --hz 120 --wiggle
probe --quality balanced --444 --out x.hevc    # picture options; prints PC work p50 / p95
```

The installed service's worker holds the single-host mutex and `identity.key` is
readable only by Administrators and SYSTEM, so stop the service and run the dev
host from an elevated prompt (`Stop-Service Relay`, then `Start-Service Relay`).

Mac, against a real session:

```sh
cd client
swift run -c release Relay --latency-stats
```

Stream for at least a minute, leave with ⌃⌥⌘Q and copy the session report
(it opens by itself when the HUD was on).
