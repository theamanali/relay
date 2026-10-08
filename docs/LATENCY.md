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
- **Mac.** The latency overlay (⌃⌥⌘L or `--latency-stats`) shows the received
  → decoded p50 and the received → on screen mean and p95, computed over the
  last 600 frames. "On screen" is the time Metal reports for each drawable
  through `addPresentedHandler`.
- **Not measured.** Network transit (the protocol's RTT/2 is only an
  estimate), the decryption before the Mac's timestamp, and the display
  panel's own response time. Summing the stages does not give an end-to-end
  number. Measuring from screen to screen with a camera is still to do.

There are also two traps in reading the Mac's numbers:

- **The overlay inflates what it shows.** It is a view on top of the Metal
  layer, so while it is visible macOS can't present the video directly to the
  display. With the overlay up, the mean was 7.92 ms; after hiding it for a
  full 600-frame window, the mean was 5.47 ms. To get a clean reading, hide the
  overlay, wait six seconds, then show it and read the first snapshot.
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
- **`--codec h264` and `--scale 0.75`.** Neither has been measured yet. H.264
  might encode faster at the same quality preset, and 0.75 scale encodes and
  decodes about half the pixels.

## Reproducing

PC, without the virtual display (doesn't black out the PC's monitors):

```powershell
relay-host --no-vdd
probe --hz 120 --wiggle
```

Mac, against a real session:

```sh
cd client
swift run -c release Relay --latency-stats
swift run -c release Relay --renderer avsbdl --latency-stats   # the old presentation path
```

Hide the overlay with ⌃⌥⌘L, wait six seconds, then show it and read the first
snapshot.
