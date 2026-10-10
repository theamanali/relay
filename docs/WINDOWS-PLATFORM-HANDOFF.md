# Windows implementation handoff: NVIDIA-only Relay

The user approved `docs/PLATFORM-REVIEW.md` and asked to implement it. The Mac
session is implementing Apple-silicon-only packaging, a macOS 14 minimum
(Observation), Swift 6 ownership, SwiftUI controls and mandatory Metal/hardware
decoding. NVIDIA enforcement below is still **unimplemented**. Per `AGENTS.md`,
the PC session owns `host/` and `tools/` and must build/test those changes on
Windows. Pull main before starting; keep client changes intact.

## Deliver in the PC session

1. Filter `gpu::choose` automatic candidates to real NVIDIA adapters. Keep all
   hardware adapters in enumeration/diagnostics for hybrid output mapping. A
   matching explicit `--gpu` must also pass the NVIDIA policy. Preserve indirect
   proxy/software filtering and LUID identity. Test AMD with more VRAM, hybrid
   NVIDIA+iGPU, no NVIDIA, invalid explicit selection and multiple NVIDIA GPUs.
2. Extend `NvApi::load` to query `NvEncodeAPIGetMaxSupportedVersion` before
   creating the API 12.1 function list; report a driver-update error when too old.
   Compare the driver's `(major << 4) | minor` result, **not** `NVENCAPI_VERSION`
   (the open-session API uses a different encoding). Preserve DLL cleanup on
   every failure. No SDK upgrade is required merely for new NVIDIA models.
3. Add a capability query on a D3D11 device for the selected adapter, without
   opening Desktop Duplication or changing display topology. Use a temporary
   encode session with RAII teardown. Enumerate codec GUIDs, profile GUIDs,
   input formats and presets. Query async encoding, max width/height, CBR,
   custom VBV and intra-refresh support when requested. Validate ARGB input and
   Relay's HEVC Main/H.264 High, P1/P4/P6 and ultra-low-latency configuration.
   A vendor ID does not prove that NVENC exists. Expose results with an explicit
   diagnostic subcommand, including adapter name/LUID and driver API version.
4. Before `acquire_display` in `server.rs`, intersect client codec mask, supported
   host codecs and host preference, and validate the requested mode/features.
   Revalidate actual capture dimensions and adapter LUID after attachment and
   on capture restart; roll back on mismatch/failure. Keep 120 Hz capability
   separate from measured sustained throughput. Add unit tests around a pure
   capability record; exercise the driver calls on the installed NVIDIA PC.
5. Verify native failure/recovery **before** deleting fallback code: unsupported
   GPU/driver/codec/mode, inaccessible desktop, capture loss, GPU/session reset,
   hybrid mismatch and physical-display restoration. Use `probe --no-vdd` for
   safe pipeline checks. The user runs exclusive-display cases, since those
   black out the PC's physical monitors and the active Windows session.
6. Once that gate passes, remove FFmpeg NVENC, AMD AMF, Intel QSV and software
   production encoders, process/pipe plumbing, `--ffmpeg` and `--no-native`, and
   corresponding installer/docs dependencies. Keep the Annex-B parser and
   access-unit types used by native NVENC, bounded queues, desktop-wait behavior,
   asynchronous retirement and capture restart. Replace fallback with explicit
   native retry/error classification. Keep same-adapter capture/encode required.
7. Remove the unverified Parsec driver and installer/CLI option. Keep MTT's
   device-node enable/disable, dynamic modes, saved topology, SYSTEM worker,
   input-desktop binding and crash restore. Never use MTT's control pipe.

## Wire compatibility

The Mac still speaks v4 and uses the existing codec mask, now derived from
hardware decoder availability. Pairing keys/files, named CPace pairing and
Noise/chunked records are unchanged. No protocol edit is needed for vendor
filtering or SwiftUI. The current STREAM_STOP cannot carry detailed encoder
failure text; do not pretend socket closure delivers the host log to the Mac.
If adding an optional error-detail message/capability, implement and test host
first, update `docs/PROTOCOL.md` and hand off the matching client implementation
in the same coordinated change. Otherwise retain the existing generic stop and
explicit PC diagnostic, and record the remaining UI gap.

## Acceptance and reporting

Run `cargo fmt --check`, `cargo build --release`, `cargo test` and
`cargo clippy --all-targets -- -D warnings`. Run the probe integration suite and
capability diagnostics against NVIDIA, then redeploy through the established
installer/service workflow. Record GPU model, driver, OS, codec/mode/bitrate and
which recovery cases passed. Update README's status honestly, distinguishing
unit tests from installed-service and physical streaming results. Compare
capture/encode latency against `docs/LATENCY.md` at identical settings. Commit
and push small steps; do not claim fallback removal qualified without the real
failure/recovery gate.
