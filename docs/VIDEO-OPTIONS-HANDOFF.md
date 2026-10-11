# Handoff for the PC session: picture options (encoder quality, 4:4:4, 10-bit)

**Status (2026-10-10): host and spec done.** The proposal below landed as
written: no byte, value or name changed, so `client/` needed nothing. The
contract is now `docs/PROTOCOL.md` (Discovery `enc`, SERVER_HELLO `0x02`,
CLIENT_HELLO "Picture options", STREAM_START `video_format`). The optional
H.264 fallback for a GPU without an HEVC encoder is in too, but untested on
such a GPU. Verification and PC-side numbers: `AGENTS.md` status and
`docs/LATENCY.md`. Still open: step 4 below, the real-Mac A/B.

The Mac app now offers three picture options in its settings popover: an
encoder quality choice (Fastest / Balanced / Best quality), Full color (4:4:4)
and 10-bit color. They are greyed out ("Needs Relay to be updated on the PC.")
until a PC advertises them. This handoff is the host and spec half.

**Order, and one exception.** AGENTS.md says protocol changes go host first.
With the user's agreement, the Mac side was written first against the proposal
below, so that it works as soon as the host does. Treat the proposal as the
draft spec:
- Implement it on the host and verify it with `probe` and tests.
- Then write it into `docs/PROTOCOL.md`.
- If you change any byte or name, change `client/` to match (the places are
  listed at the end) or leave a note for the Mac session.

Do not change `docs/PROTOCOL.md` without the host.

## Why

- Your RTX 3080 Ti's encoder can produce HEVC 4:4:4 and 10-bit.
- The Mac (M3 Pro) decodes HEVC Main, Main10, 4:4:4 8-bit and 4:4:4 10-bit in
  hardware. This was checked with VideoToolbox, requiring hardware decoding, on
  2026-10-10, and end to end with `fakehost --clip`.
- 4:4:4 keeps full color resolution, so colored text and thin colored lines stay
  sharp. Today the stream halves color resolution in both directions (4:2:0).
- 10-bit cuts banding in gradients. The desktop is 8-bit, so the gain is small;
  it mainly removes rounding in the RGB → YUV step.
- Encoder quality: the host uses NVENC P1 by default (`--quality speed`,
  ultra-low-latency tuning). P4 and P6 look better at the same bitrate but take
  longer to encode.

None of this is measured on the real PC yet. All three stay off (Fastest) by
default until it is.

## Proposed wire changes

### Discovery: TXT `enc`
A comma-separated list of what this PC can do. Omit the key when the host
supports none of it.

| item | meaning |
|---|---|
| `q` | honours `encoder_quality` |
| `444` | can encode HEVC 4:4:4 (8-bit, and 10-bit when `10` is also listed) |
| `10` | can encode HEVC 10-bit |

- Derive the list once at startup on the native NVENC path from
  `nvEncGetEncodeCaps`: `NV_ENC_CAPS_SUPPORT_YUV444_ENCODE` and
  `NV_ENC_CAPS_SUPPORT_10BIT_ENCODE` for `NV_ENC_CODEC_HEVC_GUID`.
- The ffmpeg fallback advertises `q` only.
- `enc` is informational like the other facts; the Mac uses it only to enable
  the controls.
- It goes in the same TXT record as `cpu`/`gpu` (`sysinfo.rs` /
  `discovery.rs`). It never changes while the host runs, so the readvertise
  path needs nothing new.

### SERVER_HELLO: capability bit `0x02` (`CAP_VIDEO_OPTIONS`)
- OR it into the existing capability byte next to `CAP_PAIR_NAME`
  (`protocol.rs::server_hello_with_capabilities`).
- It means the host reads CLIENT_HELLO's extension.
- Advertise it whenever the host has this code, even if `enc` is empty. The
  extension then just carries quality 0 / no flags.

### CLIENT_HELLO extension
Two bytes after `name`, sent only when SERVER_HELLO has `0x02`:

| offset (after name) | type | field |
|---|---|---|
| 0 | u8 | `encoder_quality`: 0 = host default, 1 = fastest (P1), 2 = balanced (P4), 3 = best (P6) |
| 1 | u8 | `video_flags`: bit 0 = wants 4:4:4, bit 1 = wants 10-bit; other bits 0, ignore unknown |

- `ClientHello::parse` already ignores trailing bytes (`protocol.rs:172`), so
  old hosts are unaffected.
- Parse the two bytes when present (`Option<u8>` each). A missing extension
  means 0 / 0.
- The Mac sets the flags only when it decodes them in hardware.
- The host applies a flag only if the GPU supports it and the session codec is
  HEVC. H.264 ignores both flags.
- **An explicit host `--quality` wins**, like `--bitrate` (`selected_bitrate`).
  Make the clap field `Option<Quality>` with today's default (`Speed`) applied
  when neither side asks.

### STREAM_START: the reserved last byte becomes `video_format`

| bits | meaning |
|---|---|
| 0–1 | quality used: 1 / 2 / 3 as above, 0 = not reported |
| 2 | stream is 4:4:4 |
| 3 | stream is 10-bit |

- Old hosts send 0, which the Mac reads as "not reported".
- The Mac does not need this to decode: it reads chroma format and bit depth
  from the SPS. It uses the byte for its status line and logs (`Stream: HEVC
  3024×1964 @ 120 fps, 120 Mbps · 4:4:4 · 10-bit · Balanced`).
- Update `protocol.rs::stream_start` to take it.

## Host implementation

`native_nvenc.rs`:
- **Preset:** `cfg.quality` already maps to P1/P4/P6 (`native_nvenc.rs:525`).
  Feed it from the negotiated value.
- **Profile** (`profile_guid`, `native_nvenc.rs:1376`):
  - `NV_ENC_HEVC_PROFILE_FREXT_GUID` for 4:4:4 (with or without 10-bit)
  - `NV_ENC_HEVC_PROFILE_MAIN10_GUID` for 10-bit 4:2:0
  - Main otherwise
- **Chroma:** `encodeCodecConfig.hevcConfig.chromaFormatIDC = 3` for 4:4:4.
  NVENC converts the ARGB input to 4:4:4 itself. Keep the
  `NV_ENC_BUFFER_FORMAT_ARGB` input.
- **Bit depth:** `inputPixelBitDepthMinus8 = 0` (ARGB is 8-bit) and
  `pixelBitDepthMinus8 = 2` for 10-bit output.
- **Color description:** keep it as is (BT.601 matrix, BT.709 primaries and
  transfer, limited range). The Mac's shader reads the matrix and range from
  the decoded buffer, and handles 10-bit video and full range.
- **Caps:** check them before enabling a flag. On a GPU without them, ignore
  the flag (and don't advertise it).
- **Optional, same caps query:** if `NV_ENC_CODEC_HEVC_GUID` is missing from
  `nvEncGetEncodeGUIDs` (e.g. GTX 750 Ti), use H.264 even when the Mac offers
  HEVC. Today the session would most likely fail with an encoder error. This is
  untested on such a GPU.

`server.rs`:
- Negotiate quality and flags after the codec choice (`server.rs:729`).
- Pass them into the encoder config.
- Report them in STREAM_START.
- Log them in the existing "capturing … via …" line.
- **Bandwidth:** the reason-7 check is unchanged. 4:4:4 needs more bitrate for
  the same luma quality, and the Mac's automatic bitrate does not raise it yet.

`encoder.rs` (ffmpeg fallback): quality only. Flags are ignored and not
reported (bits 2–3 = 0).

`probe`:
- Add `--quality fastest|balanced|best`, `--444` and `--10bit`, which send the
  extension when the host advertises `0x02`.
- Print STREAM_START's `video_format`.
- Add an option to write the received stream to a file for `ffprobe`.

## Tests and verification (Windows)
1. Unit tests:
   - `ClientHello` with and without the extension
   - `server_hello` capability byte (`0x01 | 0x02`)
   - `stream_start` `video_format`
   - quality precedence: host flag > client > default
   - flags ignored for H.264, or when the GPU caps are missing
2. `probe --no-vdd` against a dev run, for each of: no extension; balanced;
   `--444`; `--10bit`; `--444 --10bit`:
   - `ffprobe` the dump: profile Main / Main 10 / Rext, and pix_fmt yuv420p /
     yuv420p10le / yuv444p / yuv444p10le
   - STREAM_START's byte matches
3. `cargo fmt`, `cargo test`, `cargo clippy --all-targets`, release build,
   `install-host.ps1 -SkipDriver`.
4. Then on the real Mac:
   - In the settings popover the options become enabled for GAMING-PC (TXT
     `enc=q,444,10`).
   - Run the A/B with the Mac's latency log lines. Launch with `--latency-stats`
     and redirect stdout/stderr to a file. The Mac logs a `Stream:` line and a
     `Latency:` line every 5 s while the overlay is shown.
   - Compare Fastest vs Balanced vs Best, and 4:2:0 vs 4:4:4, at the same
     bitrate:
     - PC work p50/p95 should stay well under 8.3 ms at 120 Hz
     - Mac receive → decoded p50
     - receive → on screen
     - frame rate
   - Record the results in `docs/LATENCY.md`.

## Where the Mac side lives (for matching changes)
- `client/Sources/Relay/Protocol.swift`: `capVideoOptions`, `VideoRequest`,
  `clientHello(…, video:)`, `StreamStart.videoFormat`
- `client/Sources/Relay/HostConnection.swift`: sends the extension only after
  `0x02`
- `client/Sources/Relay/VideoOptions.swift`: `EncoderQuality` (wire values),
  `VideoFeatures` (TXT `enc` parsing), `VideoFlags`
- `client/Sources/Relay/HostBrowser.swift`: `HostFacts.videoFeatures` from
  TXT `enc`
- `client/Sources/Relay/VideoCapabilities.swift`,
  `client/Sources/Relay/VideoRenderer.swift` and
  `client/Sources/Relay/MetalPresenter.swift`: hardware probe, decoder output
  format from the SPS, 10-bit / 4:4:4 rendering
- `client/Tools/fakehost/main.swift`: `--clip`, `--format`, `--enc` act out
  the host side of all of this
