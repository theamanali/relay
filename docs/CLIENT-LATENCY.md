# Client latency status and validation

## Metal implementation (2026-09-16)

The client now defaults to `--renderer metal`. VideoToolbox still decodes all
compressed frames in order. A single-slot mailbox keeps the newest decoded
image, rejects late callbacks, and is invalidated on decoder generation changes.
A dedicated user-interactive queue waits for a `CAMetalLayer` drawable. The
decoder's 8-bit biplanar 4:2:0 output is wrapped as two Metal textures over the
same IOSurface through a `CVMetalTextureCache` (no copy) and drawn as one
aspect-fitted quad by a fixed YCbCr→RGB shader; the buffer's matrix attachment
(601/709/2020) and pixel format (video/full range) choose the constants. This
replaced a Core Image pass, which rebuilt a filter graph per frame. There are
two drawables and one GPU command buffer in flight. VSync is off by default (`--metal-vsync` turns it on). `--renderer avsbdl`
selects the previous backend; lack of a Metal device also falls back to it.

The overlay shows post-decrypt receive→decode-callback p50 for both backends.
Metal receive→present mean and p95 use the last 600 valid drawable presentation
timestamps, with the sample count shown. AVFoundation instead reports cumulative
delay relative to prescribed presentation times; with DisplayImmediately this is
not a validated receive→present measurement. It is explicitly labeled scheduling
delay and must not be compared directly with Metal receive→present. Its average
divides by total frames minus reported dropped frames, matching the delay's
displayed-frame population.

Metal counters distinguish intentional pending-frame replacement, late decoded
output, unavailable drawable/command, zero-time presentation callbacks, GPU
errors, and invalid timing samples. These are session counts; zero-time callbacks
are only observed callbacks, not a complete accounting of every unpresented frame.
AVFoundation's reported drops have a different scope. Decode FPS counts decoded
outputs, not display refreshes. Sampling continues with the overlay hidden.
Unavailable metrics clear old values. Metal timing samples clear on decoder reset.

The previous overlay's Total estimate has been removed: summing unrelated host
medians, RTT/2 and a client mean did not measure end-to-end latency. RTT/2 includes
protocol processing and is only an estimate. The receive timestamp starts after
decryption, excluding earlier socket/receive/decrypt delay. Software presentation
timestamps do not measure physical panel response or full input-to-photon latency.

Verified: release compilation and tests for frame replacement, out-of-order
callbacks, decoder generation changes, renderer selection, and offscreen GPU
renders of synthetic NV12 buffers (limited/full range colour, orientation,
letterboxing). Still pending:
real stream color/orientation, mode switches, reconnect, and latency A/B testing.
Run from `client/`, keeping the host settings unchanged between runs:

```
swift run -c release TravelDisplay --renderer metal --latency-stats
swift run -c release TravelDisplay --renderer avsbdl --latency-stats
```

To compare Metal with VSync enabled, run:

```
swift run -c release TravelDisplay --renderer metal --metal-vsync --latency-stats
```

The default (VSync off) permits earlier presentation but may cause tearing;
`--metal-vsync` trades that for tear-free output. The flag affects only Metal;
startup logs report its actual state.

Compare the client timings under motion and after load spikes. Verify letterboxing,
pointer alignment, capture restarts, reconnect and the quit shortcut. No specific
millisecond improvement has been measured yet. The notes below record the original
motivation and implementation plan.

**For the Mac session (`client/`).** Mac presentation is a candidate for reducing
the remaining latency. The previous client owns an explicit
real-time `VTDecompressionSession`; decoded IOSurface-backed frames are submitted to
`AVSampleBufferDisplayLayer` for immediate display. The wire format remains unchanged
(see `docs/PROTOCOL.md`).

## Why (measured, 2026-09-16)

Host-side per-stage instrumentation now logs, at 3024×1964@120 on the real PC:

```
native latency avg over 600 frames: capture 0.23 ms, encode 3.30 ms
120.0 fps, encoder wait avg 8.27 ms, encrypt/send avg 0.06 ms
```

So the measured capture and encode work contributes ~3.5 ms. Encrypt/send time
does not establish network transit time. The `encoder wait avg 8.27 ms`
is just the gap between 120 Hz frames, not added latency. That leaves the Mac
client as the place with the most latency to reclaim.

The original renderer gave compressed frames directly to
`AVSampleBufferDisplayLayer`, which owned both decoding and presentation scheduling.
The current renderer has removed the opaque decode queue by decoding asynchronously
through its own `VTDecompressionSession`, rebuilding that session explicitly after
codec changes, and dropping output from obsolete decoder generations. The display
layer now receives decoded pixel buffers with the display-immediately attachment.
Its final presentation queue is the remaining opaque part of the client pipeline.

## Goal

Preserve the explicit decoder and present each decoded frame directly through Metal,
with no internal display queue. Target: remove at least one frame (~8 ms) versus the
current decoded-buffer display layer and cut variable presentation jitter.

## What to build

The explicit decoder work in steps 1–3 is complete. The remaining work is to feed
its decoded pixel buffers to a `CAMetalLayer`:

1. **Format description (complete).** Build a `CMVideoFormatDescription` from the parameter
   sets delivered in the `CODEC_CONFIG` message.
   - HEVC: `CMVideoFormatDescriptionCreateFromHEVCParameterSets` with VPS, SPS, PPS
     (in that order), `nalUnitHeaderLength: 4`. H.264:
     `CMVideoFormatDescriptionCreateFromH264ParameterSets` with SPS, PPS.
   - The host sends parameter sets as length-prefixed NALs; the wire already uses
     4-byte length prefixes, which is exactly `nalUnitHeaderLength: 4`. Rebuild the
     format description and decompression session whenever `CODEC_CONFIG` arrives;
     the host re-sends it after every capture restart.

2. **Decompression session (complete).** `VTDecompressionSessionCreate` with:
   - `kVTDecompressionPropertyKey_RealTime = true`
   - IOSurface-backed destination pixel buffers, which the current display layer can
     consume without a copy. Add `kCVPixelBufferMetalCompatibilityKey` when the Metal
     presentation path lands.
   - Prefer hardware: on Apple silicon the HEVC/H.264 hardware decoder is default.

3. **Feed frames (complete).** For each `FRAME` message, wrap the NAL data in a `CMBlockBuffer`
   and a `CMSampleBuffer` (the wire NALs are already 4-byte length-prefixed AVCC/HVCC
   style, so no Annex-B start-code conversion is needed), then
   `VTDecompressionSessionDecodeFrame` with flags
   `._EnableAsynchronousDecompression` and, to minimise latency, handle output in
   the callback rather than draining a queue. Timestamps: we don't reorder (host
   encodes with `zeroReorderDelay`/no B-frames), so presentation order == decode
   order; you can pass simple monotonically increasing PTS or even invalid timing.

4. **Present immediately.** In the decode output callback you get a
   `CVImageBuffer`. Render it straight to a `CAMetalLayer` drawable (a trivial
   textured-quad blit, or `CIContext`/`MTKView`). Do **not** wait on a display link
   for a "correct" presentation time — present the newest decoded frame on the next
   drawable and drop older decoded presentation candidates. Never skip arbitrary
   compressed P-frames, which may be needed as references. If two frames are ready, show the
   newest and discard the older (never queue).

5. **Kiosk window unchanged.** Keep the existing borderless full-screen
   `StreamWindow`, cursor hiding, and input forwarding from `AppDelegate.swift` /
   `StreamView.swift`. Only the layer/renderer changes: swap `renderer.layer`
   (currently the `AVSampleBufferDisplayLayer`) for the new Metal layer.

## Keep / don't break

- **Wire format is frozen.** No protocol changes; this is decode/display only.
- Keep `--max-fps`, `--scale`, `--modifiers`, `--no-input`, the PIN dialog, and the
  ⌃⌥⌘Q exit hotkey working exactly as now.
- Keep tolerating `CODEC_CONFIG` arriving again mid-stream (capture restarts) and
  keyframe-flagged `FRAME`s; on a decode error, wait for the next keyframe.
- CryptoKit/Network/AppKit only — no third-party packages.

## How to measure the win

The optional `FRAME_TIMING` telemetry and `--latency-stats` client overlay provide
host capture/encode/send time, estimated one-way network time, receive-to-present
client time where AVFoundation exposes it, rolling FPS and dropped frames. Preserve
those measurements in the Metal renderer and replace the AVFoundation presentation
metric with `MTLDrawable.addPresentedHandler`, which reports the exact drawable
presentation time. Compare AVSBDL vs. the VideoToolbox path on the same session.
Also do the subjective mouse-feel test in Valorant/FC 26 (host on defaults, native
path).

## Fallback

Keep the `AVSampleBufferDisplayLayer` renderer behind a flag (e.g. `--renderer avsbdl`)
during bring-up so a decode/present regression is one flag away from the known-good
path, mirroring how the host keeps `--no-native`.
