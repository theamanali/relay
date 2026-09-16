# Client latency status and next step

**For the Mac session (`client/`).** The host is not the bottleneck; the remaining
perceptible latency is in the Mac presentation path. The client now owns an explicit
real-time `VTDecompressionSession`; decoded IOSurface-backed frames are submitted to
`AVSampleBufferDisplayLayer` for immediate display. The wire format remains unchanged
(see `docs/PROTOCOL.md`).

## Why (measured, 2026-09-16)

Host-side per-stage instrumentation now logs, at 3024×1964@120 on the real PC:

```
native latency avg over 600 frames: capture 0.23 ms, encode 3.30 ms
120.0 fps, encoder wait avg 8.27 ms, encrypt/send avg 0.06 ms
```

So the host contributes ~3.5 ms (capture + encode) plus ~one 120 Hz frame of
pipeline, and the network is ~0.06 ms on the wire. The `encoder wait avg 8.27 ms`
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
   drawable and drop any older undecoded backlog. If two frames are ready, show the
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
