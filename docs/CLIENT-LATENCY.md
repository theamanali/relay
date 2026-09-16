# Client latency plan — replace AVSampleBufferDisplayLayer with VTDecompressionSession

**For the Mac session (`client/`).** The host is not the bottleneck; the remaining
perceptible latency is in the Mac decode/present path. Do this on the Mac; the wire
format must not change (see `docs/PROTOCOL.md`).

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

`AVSampleBufferDisplayLayer` (current renderer, `client/Sources/TravelDisplay/VideoRenderer.swift`)
owns its own decode queue and presentation scheduling. Even with
`sampleBufferRenderer` + `flush(removingDisplayedImage:)` and immediate display, it
buffers frames internally and times presentation to its own clock, which adds one
to a few frames we cannot see or control. We want frame-in → frame-on-glass with no
discretionary queueing.

## Goal

Decode each access unit ourselves and present it to the screen as soon as it is
decoded, with no internal reorder/display queue. Target: remove ≥1 frame (~8 ms)
versus the sample-buffer layer, and cut its variable presentation jitter.

## What to build

Replace the `AVSampleBufferDisplayLayer` renderer with an explicit
`VTDecompressionSession` feeding a `CAMetalLayer` (or an `IOSurface`-backed layer):

1. **Format description.** Build a `CMVideoFormatDescription` from the parameter
   sets delivered in the `CODEC_CONFIG` message.
   - HEVC: `CMVideoFormatDescriptionCreateFromHEVCParameterSets` with VPS, SPS, PPS
     (in that order), `nalUnitHeaderLength: 4`. H.264:
     `CMVideoFormatDescriptionCreateFromH264ParameterSets` with SPS, PPS.
   - The host sends parameter sets as length-prefixed NALs; the wire already uses
     4-byte length prefixes, which is exactly `nalUnitHeaderLength: 4`. Rebuild the
     format description (and the decompression session) whenever `CODEC_CONFIG`
     changes — the host re-sends it after every capture restart.

2. **Decompression session.** `VTDecompressionSessionCreate` with:
   - `kVTDecompressionPropertyKey_RealTime = true`
   - destination pixel-buffer attrs requesting `kCVPixelBufferMetalCompatibilityKey`
     and an appropriate format (e.g. `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
     or `...10BitBiPlanar` if we ever send 10-bit; HEVC main is 8-bit today).
   - Prefer hardware: on Apple silicon the HEVC/H.264 hardware decoder is default.

3. **Feed frames.** For each `FRAME` message, wrap the NAL data in a `CMBlockBuffer`
   and a `CMSampleBuffer` (the wire NALs are already 4-byte length-prefixed AVCC/HVCC
   style, so no Annex-B start-code conversion is needed), then
   `VTDecompressionSessionDecodeFrame` with flags
   `._1_EnableAsynchronousDecompression` and, to minimise latency, handle output in
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

Add a lightweight client-side timestamp: when a `FRAME` is received vs. when its
image is presented (CADisplayLink/`CAMetalLayer` present time), log a rolling
average. Compare AVSBDL vs. the VideoToolbox path on the same session. Also do the
subjective mouse-feel test in Valorant/FC 26 (host on defaults, native path).

## Fallback

Keep the `AVSampleBufferDisplayLayer` renderer behind a flag (e.g. `--renderer avsbdl`)
during bring-up so a decode/present regression is one flag away from the known-good
path, mirroring how the host keeps `--no-native`.
