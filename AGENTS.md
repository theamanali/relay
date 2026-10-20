# Relay — working notes for coding agents (read on every machine)

Use a MacBook as the *only* display of a Windows PC over a direct Ethernet cable
(hotel travel router / home LAN / Tailscale also work). One Rust binary on the PC,
one Swift app on the Mac, a small encrypted TCP protocol between them. Deliberately
smaller than Sunshine + Moonlight: no config UI, no game launcher; pairing is the one
piece of ceremony and it is intentional.

## Layout and which machine builds what

| path | what | builds/tests on |
|---|---|---|
| `host/` | Rust host: driver control, NVIDIA-only GPU selection, native DXGI → NVENC capture/encode, display topology, TCP + mDNS, input, crypto | **Windows PC only** (`cargo build --release`, `cargo test`, `cargo clippy --all-targets`) |
| `host/src/bin/probe.rs` | fake client in Rust; the way to test the host without a Mac | Windows |
| `host/src/bin/browse.rs` | prints what Relay hosts advertise over mDNS, TXT included (`browse --seconds 5`); Windows has no `dns-sd` and its resolver does not answer mDNS TXT | Windows |
| `client/` | Swift 6 package, Apple silicon/macOS 26+: Bonjour, handshake/pairing, VideoToolbox decode, kiosk window, input | **Mac only** (`swift build`, `swift run Relay`, `./bundle.sh` for a .app) |
| `client/Tools/fakehost/main.swift` | fake host in Swift (the app's own `Noise.swift` + `CPace.swift`, real v4 handshake and pairing, PIN `000000` or `--pin`); the way to test the client's connect/pair paths without a PC — busy, rate-limited, wrong PIN, accept; `--legacy-pair` simulates an older v4 host; `--clip <file.hevc> --size WxH --fps <n>` streams a looped clip on a fixed schedule (60 fps by default; 120 for 120 Hz checks); `--no-frames` sends STREAM_START and then nothing | Mac (`swiftc … Tools/fakehost/main.swift Sources/Relay/{Noise,Field25519,CPace,Protocol,VideoBitrate}.swift`: with several files only `main.swift` may hold top-level code; advertise with `dns-sd -R`; `./Tools/test-pair-name.sh` runs isolated HostConnection loopback checks) |
| `tools/` | elevated installer (`install-host.ps1`), driver settings template | Windows |
| `docs/PROTOCOL.md` | the wire contract, including the handshake **test vector** | both — this is the source of truth |
| `SESSION-HANDOFF.md` | the only place for Mac ↔ PC handoffs: open items, steps, results | both — read after every `git pull` |

Two sessions, one repo: the PC session owns `host/` + `tools/`, the Mac session owns
`client/`. Both work on `main`; commit small, push often, `git pull` before starting.
Protocol changes go host-first (verified with `probe` + tests), then the spec, then the
client. Never change `docs/PROTOCOL.md` and only one side.

Handoffs between the machines go in `SESSION-HANDOFF.md` and nowhere else: read its
Open items after every `git pull`, add an item (and push) before stopping when the
other side or the user has work to do, and delete an item once its outcome is in the
README status and here. Do not create other handoff or retest files.

## Status

- True 10-bit SDR host implementation (2026-10-19): negotiated `video.ten_bit`
  reaches VDD attach; SDR10bit/HDRPlus are journaled before override, applied
  before enable, restored after disable and recovered after a crash. The installed
  MTT 25.7.23 package is INF 11.30.4.434 (`oem49.inf`), VDDPATH
  `C:\VirtualDisplayDriver`. Non-exclusive on/off/on tests reported 10/8/10
  SDR bits/channel, but DuplicateOutput1 still returned BGRA8. Thus true 10-bit
  uses WGC FP16 linear scRGB with Windows cursor composition, same-GPU sRGB
  OETF to R10G10B10A2, RGB10 slots and NVENC **ABGR10**. DDA observes output recovery there;
  8-bit/H.264 keep BGRA8/ARGB. SYSTEM uses a signed-in-user capture-source
  process from the same binary (WGC activation fails under SYSTEM). A
  PID-authenticated local pipe transfers only an explicitly duplicated RGB10
  texture handle; keyed-mutex GPU sharing keeps pixels off the CPU. SYSTEM
  retains NVENC, keys, input and topology; the user helper captures the cursor
  with its FP16 desktop. DDA pointer metadata can omit a cursor already baked
  into its discarded BGRA8 image, so WGC includes it and no DDA overlay is
  drawn on true 10-bit frames. In a selected 10-bit session,
  Winlogon uses temporary DDA/BGRA8/ARGB input and Default uses true FP16/RGB10.
  The Main10/Rext output and 10-bit VDD stay fixed; desktop changes recreate
  capture in either direction without reconnecting. This secure-desktop
  exception was explicitly requested by the user after the first deployment;
  unknown desktops wait, and Default WGC failures never downgrade. H.264 and
  unselected 8-bit sessions retain their existing behavior. Integer XOR fixes the old masked cursor's
  replacement pixels being modified by its XOR pass. Capabilities include WGC,
  FP16 load, RGB10 render/blend and ABGR10 input; trials register/map slots and
  construct the converter; 10-bit trials also register/map BGRA8 input with
  unchanged 10-bit output for Winlogon. HDR is refused.
  On an unchanged physical desktop, native ramps retained 64/64 codes before
  and after GPU conversion/cursor, max error 0; legacy capture retained 16/64,
  max ramp error 2. Actual production 4:2:0 and 4:4:4 10-bit dumps decoded with
  finer precision, correct channel/range controls and unchanged SDR VUI.
  Windows fmt, 243 unit tests + 2 probe tests + integration, strict clippy and
  release build pass; the separate read-only NVENC/WinRT lifetime regression
  also passes. Four ordinary-user no-VDD protocol sessions pass, as does the
  shared-GPU helper diagnostic (64/64 source codes, max error 0). Implemented
  in `ecb33ee`, secure-source policy in `c060d0f`, actual WGC cursor fix in
  `20ea60a`, then unified source timing in `792bca7`; installed with release/installed SHA-256
  `09E95E2D9F4B97EC3479F6BCF1D51B8A145E3095EF1B86E13D8BBF22F1E3E276`.
  Guarded SYSTEM no-VDD sessions passed both chroma modes on the unchanged
  2560×1440@120 primary; latest decoded ramps retained 36/40/35/52 and 34/44/32/54
  R/G/B/gray codes (max errors 6/6), with correct SDR controls/VUI. Actual
  pointer pixels and zero trails pass in direct and GPU-shared capture;
  disabling the WGC cursor makes the negative control fail. Normal
  service restored, Running, `enc=q,444,10`; pair-only passed and both capture
  helpers exited. The latest harness completed successfully after caching the
  scene process handle fixed its earlier blank ExitCode. Forced secure-input
  diagnostics passed both 10-bit output chroma modes; actual Winlogon and
  same-connection desktop switches remain user/Mac qualification. One unintended exclusive 8-bit test session
  restored both physical monitors/layout; details and corrected no-VDD guard
  are in SESSION-HANDOFF.md.
  `precision` + `tools/check-precision.py` reproduce the numeric check.
  WGC SystemRelativeTime now uses the same `present_us`/Mac calculations and
  HUD labels as 8-bit, per the user. The helper publishes a tagged sequence +
  source QPC record before releasing the RGB10 slot; the host consumes both
  before returning ownership. New helpers reset pipe/sequence; partial,
  mismatched, backwards and error records cannot supply a timestamp. Preserve
  the raw stamp for cadence, but omit it from wire/stats if later than submit
  (observed on this stack); never invent 0 age, substitute pipe/arrival time
  or delay video. Re-encodes without fresh source stay unknown. Installed
  SYSTEM probes received 9/99 known source stamps in 466/465 timing records,
  zero out of order; clock/work telemetry remained available. No wire layout,
  capability or Mac runtime change. Real-Mac HUD/performance remains pending.
  Logs report unknown source age as unavailable, not 0 ms. The Mac HUD's
  false "clock not synced" label and hidden encode/send detail are fixed on
  the Mac (follow-up below); real-PC qualification remains open.
  VDD source precision with the new WGC path, SYSTEM/secure desktop/recovery,
  exclusive restore and real-Mac 3024×1964@120 performance remain pending in
  SESSION-HANDOFF.md; older “10-bit free” results are encoding-only baselines.


- Mac SDR timing/precision follow-up (2026-10-19; `1181e72`): HUD sync
  comes from ClockSync state, independently of source samples (the rolling
  window is ten seconds since `4e04071`).
  Synced idle streams use receive → screen with “source timing idle”; fresh
  source timing resumes without reconnecting. Submit → sent is a separate
  Encode & send metric in HUD/report, independent of source/sync; PC work
  retains capture + encode + send. Unknown/future/reversed stamps do not
  create source-to-screen measurements. Local M3 Pro/macOS 27.0 hardware
  decode + native Metal RGB10 readback preserves 64/64 consecutive 10-bit
  codes, max gray RGB error 0; 8-bit controls retain 17/64. HEVC all four
  depth/chroma formats and H.264/8-bit pass channel/range controls. This is
  decoder/render-target proof, not exclusive VDD or physical-panel precision.
  Isolated fakehost static/moving/recovery/moving/static keeps 21 clock
  replies across an actual two-second frame gap. `f91377a` also rejects a
  drawable of the wrong depth if the mailbox changes streams during its wait.
  Desktop sparkline points expire with the rolling window, including
  after sparse-source idle/resume. The 2026-10-20 correction joins timing
  (including missing source stamps) and presentation by frame sequence to
  append one real or carried point per displayed frame, in either callback
  order. Carried points never enter histograms or renew real sample age.
  208 Swift tests, debug/release builds and bundle signature verification pass.
  Initial real-PC 8-bit run showed variable presentation stalls despite a
  foreground app/closed video apps; cause remains unresolved. Exact commands/builds,
  real-PC results and remaining user checks are in SESSION-HANDOFF.md.

- Platform migration 2026-10-10: Mac SwiftUI/Swift 6, Apple silicon/macOS 14,
  mandatory Metal/hardware decoding implemented. 107 unit tests (112 after the
  picker restoration below), isolated
  fakehost checks, local release/signature and picker/PIN/Forget smoke tests
  pass on macOS 27.0. The Windows half of the platform migration
  is done (2026-10-17): phase A (NVIDIA enforcement), phase B (recovery gate,
  U1–U6 passed) and phase C (one native backend, installed, real-Mac latency
  with no regression), all below. Minimum / latest stable macOS qualification
  and Developer ID notarization remain pending (README roadmap).

- NVIDIA enforcement, phase A (2026-10-17, handoff steps 1–4; `0eb98fa`,
  `f1a9297`, `70e6ad0`, `728f547`): `gpu::choose` considers only `gpu::eligible`
  adapters (NVIDIA, not software, not the IDD proxy), most VRAM then lowest
  DXGI index; an explicit `--gpu` must match one; `describe` still lists all.
  `NvApi::load` calls `NvEncodeAPIGetMaxSupportedVersion` first and refuses
  below `REQUIRED_DRIVER_API` = `(12 << 4) | 1` (not `NVENCAPI_VERSION`); the
  DLL is an RAII `Library`, and a test shows it unloaded after a refusal.
  `RELAY_TEST_NVENC_DRIVER_API=0xb1` forces that refusal (test hook).
  `native_nvenc::query_caps` fills the pure `nvenc_caps::EncoderCaps` from a
  `CapsSession` (D3D11 device for the LUID, no duplication, RAII destroy):
  lists, caps and which of P1/P4/P6 return a ULL preset config. Startup
  refuses to serve without a usable codec (the service's backoff retries).
  `server::plan_session` (pure) intersects client mask × `codec_mask` ×
  preference, negotiates flags, checks size/rate/preset; `trial_encoder`
  runs the real `EncoderSession::configure` at that size (~180 ms on this PC,
  driver-bound) — all before the displays are woken. A refusal is
  STREAM_STOP 1 + drain (`refuse_stream`). `revalidate_plan` after attach
  requires the display on `caps.luid` and re-checks/re-trials a changed mode;
  failure drops the lease first. `NativeNvenc::spawn` runs
  `encoder::check_capture` (adapter LUID + size) on every start/restart;
  `CaptureMismatch` goes to the recovery loop. `cross_adapter` compares
  LUIDs. `relay-host encoder-caps` prints it all. Verified on Windows: fmt,
  204 unit tests + the probe integration test, clippy `-D warnings` on 1.98
  and 1.99, release build; `encoder-caps` on the RTX 3080 Ti (driver 616.56,
  NVENC API 13.1, Windows 11 26200.9711) initializes every HEVC/H.264 preset
  and picture option at 3024×1964@120; 9000×9000, `--gpu radeon` and the
  driver hook fail as intended. NVIDIA's rated `MB_PER_SEC_MAX` (983,040,
  ≈42 fps at 3024×1964) is shown as a rating only: this GPU measured
  102–118 fps there.
- Phase B, PC half (2026-10-17): see `host/NVIDIA-RECOVERY-RETEST.md`. 17
  `--no-vdd` dev-host + probe cases pass on `cd93619` (installed as the
  service, hash `D7C7F314...004345F9`). Found and fixed: `is_desktop_not_capturable`
  walked `chain()` and never matched a `.context()` marker, so a non-SYSTEM
  host's lock-screen wait never engaged (use `downcast_ref` on the
  `anyhow::Error`). Also `session_gpu` (`49341a8`): each session re-selects the
  GPU, since a driver restart changes its LUID. Open for phase C: a second
  `DuplicateOutput` on an output this process still duplicates fails with
  E_INVALIDARG (confirmed in-process); a session starting while the previous
  one's capture is still retiring hits it (fixed in phase C, below).
  B03's bt470bg/sRGB colour tags came from the ffmpeg fallback it caused, not
  from native H.264 (finding 5, resolved; no code change).
  `RELAY_TEST_FAULT=trial,display-gpu` and `probe --progress` /
  `--codec-mask` exist for these cases. User-run U1–U6 all passed on
  2026-10-17 on the installed `54e400c` (hash `A3E248D3...518F1112`):
  real-Mac 4:2:0 and 4:4:4 10-bit sessions, lock/unlock, Win+Ctrl+Shift+B
  (recovered in 1.7 s, LUID unchanged), worker kill (service restored and
  respawned in 5 s), simulated hybrid mismatch on the VDD (rolled back in
  1.4 s), oversized mode refused untouched. Gate B passed; phase C (removal)
  awaits the user's go-ahead. After a killed worker the Mac's picker needed
  Relay reopened to see the PC (no mDNS goodbye; finding 6). Host side
  (`e8f929d`): mdns-sd 0.11.5 announces a registration only at 0 and 1 s,
  so `Advertisement::reannounce_if_due` re-`register`s the same
  `ServiceInfo` (no goodbye, same TXT) 3, 8, 16, 32 and 60 s after each
  registration, on the readvertise thread's tick; nothing after a minute.
  Installed (`7074914…9CF97724`); it is **not enough**: on 2026-10-18 both
  real-worker kills (F6b) left the Mac's picker without the PC for good
  while host.log showed all five re-announcements. A `--no-vdd` dev host
  killed the same way never lost the row (F6a). Mac diagnosis/fix
  (`d79fb94`, `232805f`; 2026-10-17 Pacific / 2026-10-18 UTC): simultaneous
  `dns-sd -B`, `dns-sd -L`, mDNSResponder and app captures establish an
  app-side lost TXT update. The PTR never left either interface; after a
  real mid-session kill at 18:11:58 Pacific, resolve returned full TXT at
  18:12:05.429 and mDNSResponder delivered TXT remove/add to both queries,
  but `NWBrowser` reported only `txt=false,key=false` at 18:12:05.430.
  The debouncer correctly expired grace at 18:12:08.161; the browser supplied
  no full TXT during the remaining ~3 minutes before relaunch. Other kills
  deliver full TXT within grace, so
  this is timing dependent. `BrowseRecovery` now recreates the browser at
  2.5/10/30 s after a previously discovered keyed row is removed, or after
  a picker dial never reaches `.ready` (alongside reconfirm). Duplicate
  triggers coalesce, full TXT cancels remaining retries, and the debouncer
  survives restarts so other rows retain grace. Stop cancels recovery;
  retired browser callbacks are generation guarded. No pairing, wire or
  TXT change. Verified: 164 Swift tests, isolated `test-pair-name.sh`,
  signed local release build, isolated SIGKILL/restart fakehost smoke
  (forced failed-dial recovery, generation 2, same-key verify without PIN,
  other PC row preserved; local records cannot reproduce the real flush).
  Fixed-client F6b on the home LAN: idle kill + gap Connect streamed without
  PIN (01:16:05.779 UTC; dial reached ready, so no failed-dial timer); a
  mid-session kill kept the row and reconnected without PIN; a repeat
  removed the row at 01:18:27.652 UTC and restored it at 01:18:27.982,
  10.9 s after reset, cancelling the pending restart. PIN-free reconnect
  streamed 01:18:59.920 without reopening. A timed-out dial at 01:21:56.758
  exercised reconfirm and browser generations 2–5. PTR flush at 01:22:03.450
  also appeared in `dns-sd -B`; the row returned at 01:22:45.652 (39.5 s
  after row removal, slower than the approximate 10–30 s target), and
  reconnected without PIN. The auxiliary browse was still active; its effect
  on the shared daemon question is an unproven hypothesis. After closing it,
  a mid-session kill reproduced stuck TXT: reset 01:23:55.426, row removed
  01:24:06.239, recovery generation 6 at 01:24:08.864, full TXT and Paired row
  at 01:24:08.895 (**13.5 s after reset**, no app restart); PIN-free reconnect
  streamed 01:24:31.189. Thus real browser
  replacement fixes the reproduced TXT failure, and the slow PTR-flush case
  also recovered, but a universal 30 s bound is not established. All these
  later times are 2026-10-18 UTC. Detailed Mac evidence:
  `client/README.md#worker-crash-rediscovery-finding-6`. The PC session owns
  updates to `host/NVIDIA-RECOVERY-RETEST.md`.
- Phase C (2026-10-17, handoff steps 6–7; `391f815`, `e5b2ecd`, `c537ee5`):
  one native backend. `Encoder::retire` counts teardowns in `RETIREMENTS`
  and `Encoder::spawn` waits up to 3 s for them, then retries `NativeNvenc::spawn`
  every 100 ms for 2 s while `create_capture` reports `OutputBusy`.
  `duplicate_output_error` marks DuplicateOutput's E_INVALIDARG and
  NOT_CURRENTLY_AVAILABLE as busy; E_ACCESSDENIED stays a refused desktop.
  Any other failed first start puts the session in the recovery loop
  (`Encoder::waiting`), like a restart; `classify_start_failure` labels
  each failure in the log. Removed: the ffmpeg child, AMF/QSV/software command
  lines, `--ffmpeg`, `--no-native`, `VideoCaps::FFMPEG`, `encoder_name`,
  `driver/parsec.rs`, `DriverKind`/`--driver`, and the installer's
  `-Driver parsec`/`-Resolutions`. Kept: Annex-B parser, bounded queues,
  desktop wait, async retirement, capture restart, same-adapter requirement,
  the `VirtualDisplay` trait, MTT devnode switching. Verified: unit tests,
  clippy, release build; `a_second_duplication_starts_once_the_first_is_released`
  (opt-in, `--ignored`) passes on this PC. The dev-host regression (16 checks,
  `host/NVIDIA-RECOVERY-RETEST.md` Phase C) passed and installed the build:
  hash `C5EA77A8...3A754A7442`. Real-Mac A/B at the LATENCY.md Balanced
  settings: PC work 18.5 / 18.6–18.9 ms (baseline 18.7 / 19.4), decode 2.2 (2.2),
  screen p50 3.5–3.8 (3.5), 107 fps shown (102): no regression. The baseline's
  desktop was mostly static (1–4% fresh frames in host.log), not moving as that
  section had said; corrected there.

- Display scale, host + probe + spec (2026-10-18; `0c5828d`; Mac side in
  SESSION-HANDOFF.md). Windows keeps a per-monitor scale **per user** in
  `HKCU\Control Panel\Desktop\PerMonitorSettings\<EDID id>\DpiValue`, as
  steps from the scale it recommends (100, 125, 150, 175, 200, 225, 250,
  300, 350…); the id has no resolution or devnode instance in it, so the
  user's one manual setting (`DpiValue=2` for `MTT1337…`) survived every
  devnode disable/enable. `DisplayConfigGetDeviceInfo` packet -3 returns
  min/current/max relative to the recommendation (min = the step of 100%);
  `SetDeviceInfo` -4 sets it **live** (no sign-out) and writes the calling
  user's HKCU at once. Measured here: both physical monitors recommend 100%
  (max 175% / 225%). SERVER_HELLO cap `0x08` `CAP_DISPLAY_SCALE` (caps
  `0x0f`); CLIENT_HELLO `u16 display_scale` (percent, 0 = Windows' own)
  after the picture options. `scale.rs`: pure step math (nearest step, tie
  to the smaller, clamped to the monitor's range), `apply` saves the
  previous step to `%ProgramData%\Relay\display-scale.txt` *before* setting
  and reads it back; the lease restores it first (the virtual monitor must
  still be active), then the layout. `scale::recover_saved` runs before
  `drv.cleanup()` in `put_displays_back` and `restore`, and before each
  acquisition; a monitor already gone is logged and the file dropped (its
  stale value affects only the virtual monitor and the next session sets
  it). A reasserted topology reapplies it. `--no-vdd` never applies it
  (physical monitor). Failure to set is a warning, never a refused session.
  `relay-host display-scale [--try \.\DISPLAYn <percent>]`,
  `attach-test --scale`, `probe --display-scale`. Verified on Windows: fmt,
  229 unit tests + 2 probe tests + the probe integration test, clippy
  `-D warnings` on 1.98 and 1.99, release build. Elevated `display-scale
  --try \.\DISPLAY1 125` (the VG240Y): set, read back 125%, snapshot
  written, restored from the file to 100%, file cleared (the test's
  `DpiValue=0` key was then deleted, so the physical monitors are exactly
  as before). Elevated `--no-vdd` dev host + `probe --display-scale 200`:
  caps `0x0f`, logged "display scale 200%" and "dev mode: not applying",
  118 fps; the 0 / 999 / absent requests were logged correctly but refused
  busy (the probes reconnected before the first session had drained; a
  script error, not a host one). Installed with `install-host.ps1
  -SkipDriver`: hash `1E8620F4AF67DB45BDA90FA9405CC7CD62CD17BCC8A1E9AC6203B66EA844F2CF`
  (= release), service Running. **Not verified:** the SYSTEM worker on the
  real virtual display (which hive it writes, whether a sign-in mid-session
  keeps the value, the login-screen desktop), the virtual monitor's
  recommended scale at 3024×1964 (the user's `+2` suggests 150%), and the
  real Mac: SESSION-HANDOFF.md "→ user".
  Mac side (2026-10-18): `StreamMode.displayScale` = requested pixel width
  ÷ the stream screen's `frame.width` × 100, rounded, **never under 100**
  (a reduced mode on a 1× screen would send 50/75, which the host ignores
  as 0 and so keeps a stale scale); 0 only for a zero size.
  `HostConnection.Options.displayScale` goes out only with
  `supportsDisplayScale` (cap 0x08), after the picture-option bytes, which
  are then always sent (0, 0 without `CAP_VIDEO_OPTIONS`); older hosts get
  the old CLIENT_HELLO. fakehost advertises 0x08 unless
  `--no-display-scale` and prints size, extension and scale for every
  CLIENT_HELLO, including the one after pairing. Verified: 195 Swift tests,
  `test-pair-name.sh` 22 PASS (new: `display-scale` → 150%,
  `display-scale-old-pc` → no extension), and the debug app via `--host`
  against fakehost on the 1× ED273UR: 2560x1440 / 1920x1080 / 1280x720 all
  sent 100%. The Retina 200/150/100 values are unit-tested only (the app
  picked the external screen); the real-PC check covers them.
  Display scale settings (same day, user request; in Video right under
  Bitrate, not a section of its own, user decision): Automatic scaling
  (`SessionPrefs.displayScaleAutomatic`, default on) and a Scale menu of
  `DisplayScale.steps` (100–300), disabled while automatic and then showing
  `PickerModel.effectiveDisplayScale` (the automatic value snapped like the
  host: nearest step, tie to the smaller); turning Automatic off keeps the
  shown step, picking one turns it off. A manual choice is sent as is.
  `requestedDisplayScale` decides what CLIENT_HELLO carries. Checked in the
  bundled app on the Retina panel: 200% greyed, enabled with Automatic off.
- Clock sync + frame timing, host + probe + spec (2026-10-18;
  PROTOCOL.md "Clock sync and frame timing").
  SERVER_HELLO caps `0x07` (`CAP_TIMING` 0x04). `clock.rs`: QPC µs
  (u128 math), the `LastPresentTime` base; never `SystemTime` (PING still
  is). `read_loop` stamps TIME_REQUEST 0x88 and queues it in
  `SessionTiming` (≤ 16); `pump` writes TIME_REPLY 0x09 before the next FRAME
  (and in the recovery loop), and from its first reply sends
  FRAME_TIMING_EXT 0x0A (68 bytes) after every FRAME instead of FRAME_TIMING
  (every 4th, unchanged for other clients). `present_us`/`submit_us` ride
  `CaptureInfo` → `EncoderTiming`; `present_us` is `u64::MAX` when
  `pending_present_qpc` is None (re-encode or cursor only); `submit_us` is
  after NvEncEncodePicture returns; `copy_gpu_us` always 0xffffffff.
  `inputs_applied` counts every 0x90–0x93 after the first request (Observe
  and short payloads too) under one mutex with its time. `network_rtt` moved
  into `SessionTiming`. New payloads parse as ">= N bytes". Verified on
  Windows: fmt, 223 unit tests + 2 probe tests + the probe integration test,
  clippy `-D warnings` on 1.98 and 1.99, release build. Elevated `--no-vdd`
  dev host (port 18468, service stopped, 2560×1440@144 primary) with
  `probe --timing`: offset 0–4 µs, min delay 35–66 µs, 0 fresh frames out of
  order over ~3,000 (present→submit p50 0.8 ms, submit→sent 2.8–4.6 ms,
  sent→received 7–39 µs), re-encoded/cursor-only ticks `u64::MAX` (81 of
  1,068 with `--wiggle`), inputs 357 sent / 356 reported at the end with one
  in flight, input → applied p50 0.13 ms; without `--timing` FRAME_TIMING
  still every 4th frame; 4:4:4 10-bit fine. The first run lost Desktop
  Duplication twice ~2 s into sessions (`no DXGI output is named
  \\.\DISPLAY2`); a rerun of the old (`5b04101`) and new builds side by side
  had no losses on either, with the same fps and PC work (130.6 / 4.37 ms
  vs 130.9 / 4.41). The desktop was never fully static (on-screen
  animation: 597–600 of 600 fresh), so the `u64::MAX` case is from
  re-encoded and cursor-only ticks. Installed with `install-host.ps1
  -SkipDriver`: hash `107FDB553A7F0FA1AA02973795E1034330FB326381E0C2B1C8D631521C8B84F3`
  (= release), service Running, `probe --pair-only` sees caps `0x07`.
  Then, with the user's go-ahead, `probe --timing --wiggle` against the
  service at 3024×1964@120 (virtual display `\\.\DISPLAY75`, monitors dark
  ~9 s): 93.6 fps over 8 s (first frame after 1.8 s), offset 5 µs, min
  delay 42 µs, 534 fresh frames 0 out of order, 214 `u64::MAX`,
  present→submit p50 0.9 ms, submit→sent 5.2 ms, sent→received 31 µs,
  input → applied p50 0.14 ms (p95 1.1), inputs 369 sent / 368 reported;
  host.log: physical monitors and layout restored.
  Mac side (2026-10-18, `599ea4c`, `8d07763`): `ClockSync` (pure; 8
  samples, lowest delay wins, delay > 50 ms or broken stamps dropped),
  `InputLedger` (counts 0x90–0x93 from the first TIME_REQUEST; nil-event
  sends counted, not sampled), `FrameEndToEnd`. HostConnection sends
  requests only with CAP_TIMING (5 × 50 ms after STREAM_START, then 1/s),
  pairs each EXT with the FRAME before it, feeds PC work/network from
  `ext.basic`. `LatencyStats` joins present (Mac µs) with Metal's
  `presentedTime` by the Mac's frame sequence in either order. All Mac
  clocks share one base (`systemUptime`, `CACurrentMediaTime`,
  `DispatchTime` within µs). Sent → received ends when the whole frame is
  in, not at its first record (the PC stamps `sent_us` after the last
  byte). fakehost `--clock-offset-ms` / `--no-timing`. Verified: 182 Swift
  tests, `test-pair-name.sh` 17 PASS (it now compiles ReceiveTiming and
  ClockSync, which it had missed), fakehost offset +250.5 → estimated
  +250.508 ms and −3000 → −2999.999 ms with the same end-to-end rows,
  `--no-timing` rows blank. Real PC over the cable (`en11`, 1 GbE, home
  LAN), installed `107FDB55`, 3024×1964@120 Fastest 4:4:4 10-bit, 40 s
  with synthetic 125 Hz pointer motion for the last 25 s: 119.7 fps;
  Desktop → screen p50 14.9 / p95 23.3 ms, content age 3.3 / 11.7, PC work
  7.1 / 7.1, sent → received 0.4 / 0.6, RTT/2 0.9, frame transfer (est.)
  0.8 / 1.4, receive → decode 3.0, receive → screen 4.4 / 5.5, input →
  sent 0.5 / 1.9, input → applied 1.1 / 2.4; best sync delay 0.50 ms. The
  parts add up (3.3 + 7.1 + 0.4 + 4.4 ≈ 15.2). Whether a video tab was open
  in a browser was not checked.
- Picture options, host + spec (2026-10-10; the Mac side shipped first by user
  decision): the proposal landed unchanged and is now in
  `docs/PROTOCOL.md`. TXT `enc` comes from `VideoCaps::detect` at startup
  (`native_nvenc::query_caps`, a short NVENC session: HEVC GUID present,
  `SUPPORT_YUV444_ENCODE`, `SUPPORT_10BIT_ENCODE`; RTX 3080 Ti → `q,444,10`;
  the phase A record replaced this detection). SERVER_HELLO's
  capability byte is now `0x03`. `ClientHello` has optional `encoder_quality` /
  `video_flags`. STREAM_START's last byte is `VideoFormat`. `--quality` is an
  `Option` override (`quality_override`): host flag > client > Speed
  (`negotiate_video`). Flags apply only to HEVC on the in-process path with
  the display on the encoding GPU (there is no other encoder since phase C).
  A GPU without
  HEVC gets H.264 (`choose_codec`). Native NVENC uses profile Rext / Main10 /
  Main, `chromaFormatIDC` 3 and `pixelBitDepthMinus8` 2. SDK 12.1's HEVC
  config has no input-depth field, so the input depth comes from the ARGB
  buffer format. `probe` gained `--quality fastest|balanced|best`, `--444`,
  `--10bit` and `--codec`, and prints `video_format` and PC work p50/p95.
  Verified on Windows 2026-10-10:
  - fmt, 161 unit tests plus the probe integration test (the desktop test
    ignored), clippy `-D warnings` on 1.98 and 1.99, release build.
  - An elevated `--no-vdd` dev host (service stopped; 2560×1440@120 primary)
    with `probe`: no extension / balanced / best / `--444` / `--10bit` / both.
    STREAM_START 0x01 / 02 / 03 / 05 / 09 / 0d. ffprobe: Main yuv420p, Main
    10 yuv420p10le, Rext yuv444p, Rext yuv444p10le. Every dump decoded without
    errors and kept the color description. H.264 with flags → High yuv420p,
    0x03, logged as not applied.
  - Elevated `install-host.ps1 -SkipDriver`; service Running, installed
    SHA-256 matches the release (`1DF94C59...2320D2E7`). The SYSTEM worker
    logged the same caps, and `browse` shows `enc=q,444,10`.

  Real-Mac A/B at 3024×1964 done 2026-10-17 (`docs/LATENCY.md`): Balanced
  102 fps / 18.7 ms PC work, Best 86 fps / 22.7 ms, 4:4:4 +3.5 ms, 10-bit
  free. Not verified: the host `--quality` override end to end (unit-tested only),
  and a GPU without HEVC or 4:4:4.
- Displays off (2026-10-17): with Windows' displays asleep, connecting hung
  ("Connecting…"/"Starting…" for ever). Mac side done: `HostConnection` ends
  the attempt 20 s after CLIENT_HELLO without STREAM_START ("the PC didn't
  start the stream") and 10 s after STREAM_START without a FRAME ("the PC sent
  no picture"); `Tools/test-pair-name.sh` covers both. Host side done
  (`6ab02a3`): `handle_session` sends one zero-distance relative `SendInput`
  move (`input::wake_displays`, inside `with_input_desktop("wake displays")`)
  after the display claim and before `acquire_display`, logs `woke displays
  before session setup`, and only warns if it fails. Never `ES_DISPLAY_REQUIRED`
  (see `KeepAwake`). Verified on Windows 2026-10-17: fmt, 161 unit tests plus
  the probe integration test, clippy `-D warnings` on 1.98 and 1.99, release
  build, installed hash `6335D274...52D5941`. With the display-off timeout at
  1 min and the monitors dark, real-Mac Observe connects from the desktop and
  from the lock screen captured in about 2 s; monitors and layout restored on
  each disconnect. An Observe session then froze once the timeout passed
  mid-stream (0 fresh frames from 60 s after the last input); a zero-distance
  nudge resumed capture with the device-disabled physical monitors still dark.
  Fixed with `DisplayKeepAlive` (`360f9e0`, user request): a per-session
  thread nudges after 30 s of `GetLastInputInfo` idle time, at most every
  30 s, and stops before restore. It is preemptive on purpose: fresh-frame
  counts cannot tell a static desktop from displays that are off. It also
  holds off the screen saver and inactivity lock during a session. Real Mac,
  Observe, 1-minute timeout: no freeze over 3 minutes, idle never above
  29.9 s, monitors dark, 11 nudges logged, restore fine; installed hash
  `5B6DBD61...CA9EDB60`.
- Milestones 0–3 and 5 are done and verified on the real hardware: the virtual display becomes
  the only display at the Mac's exact mode, layout is restored on disconnect/Ctrl-C/hard kill,
  in-process DXGI → NVENC runs at 3024x1964@120, PIN pairing + encryption, real sessions over
  the cable from the Mac client (Metal presenter).
- Milestone 4 is in progress: tray icon and Windows service are done. On 2026-10-09,
  lock/unlock during streaming and connecting to an already-locked PC passed; one
  reboot → login-screen connect → sign-in from the Mac passed. An earlier reboot and
  sign-out/reconnect failed virtual-display setup until local sign-in. The topology
  context fix below passes Windows tests/build/clippy. Later on 2026-10-09 the user
  reported all three retests passed once (reboot-before-login, sign-out/reconnect,
  lock/unlock), with no observed failure. Installed/release executable hashes match.
  Logs confirm normal disconnect restore, shutdown restore bound to Winlogon,
  lock/unlock capture recovery and 3024×1964@120 streaming; the reboot connection
  followed SessionLogon, so that log does not independently prove setup before any
  user session exists. Repeat runs and service crash-restore verification remain
  pending. Still to do: DPI (host side done 2026-10-18, see "Display
  scale"), installers/signing. Latency measurements, what was
  rejected and what is still open: `docs/LATENCY.md`.
- Protocol v4 (2026-10-08): Noise XX handshake, CPace PIN pairing and chunked records
  (`docs/PROTOCOL.md`). Host and spec are done (`crypto.rs`, `cpace.rs`, `field25519.rs`; the
  v4 test vector matches line for line). The Mac side is wired in too (`Noise.swift`,
  `CPace.swift`, `Field25519.swift`, `HostConnection`); a v3 Mac app cannot connect to a v4 PC
  (`host.log`: "the Mac app speaks the v2 handshake; update it") and a v4 Mac reports that an
  older PC "hung up during the handshake". Mac side verified 2026-10-08 against `fakehost`
  in every mode through the real app (pair with the right PIN, wrong PIN caught from
  PAIR_REPLY with nothing stored, rate limit, pairing while busy, STREAM_STOP 4 then re-pair)
  and through the picker's launch-time check (still paired → digest stored; forgot →
  forgotten locally; a different key behind the advertised `pk` → closed after msg2, no msg3)
  and PC ▸ Forget in the bundled app (UNPAIR straight after msg3 → UNPAIRED, the row back to
  Available, "Forgot Fake PC"). Real PC ↔ Mac v4 streaming with the existing pairing
  verified 2026-10-09: 3024x1964@120, host measured 118.2 fps, encrypt/send avg 0.05 ms,
  and physical monitors/layout restored on disconnect; reconnect without a PIN also passed.
  Mac-side Forget (UNPAIR), wrong-PIN rejection, fresh CPace pairing with the correct PIN,
  streaming afterwards and PC-side Forget propagating to the Mac picker also passed.
  Picker flicker during these transitions was fixed by holding TXT withdrawals through
  the discovery grace period; verified by the user with section-header animations retained.
  PC side verified against the installed service
  with `probe`: not paired / pair / already paired / unpair / re-pair (PIN rotates),
  `--abandon-pair` and wrong PINs counted, the sixth attempt refused with 599 s, TXT `v=4`,
  and a 1080p60 session at 60.2 fps with encrypt/send avg 0.07 ms (max 0.38 ms).
- Pair-only name fix (host-first, 2026-10-09): host advertises optional
  SERVER_HELLO capability `0x01` and accepts PAIR = Ya + u8 name length + UTF-8.
  The complete name suffix is CPace ADa; the name is stored only after valid
  confirmation and before PAIR_RESULT. Legacy PAIR remains accepted; unnamed new
  pairings use “Paired MacBook”, and unnamed re-pair preserves an existing name.
  Probe supports `--name` / `--legacy-pair`; isolated probe tests cover named,
  legacy, wrong-PIN and abandoned pairing without touching displays or the service.
  Mac implementation and `docs/PROTOCOL.md` are now updated: HostConnection
  negotiates the capability per attempt, binds the Unicode-safe suffix to CPace,
  and keeps legacy hosts on empty ADa. The shared named vector, malformed names,
  Unicode boundaries and tampering are covered by Swift tests; fakehost advertises
  the capability by default and offers `--legacy-pair` for old-host checks.
  Mac verification on 2026-10-09: `swift test` (99 tests), isolated
  `Tools/test-pair-name.sh` (pair-only named/legacy/busy/empty/Unicode, wrong PIN,
  rate limit, already-paired, verify-only, UNPAIR and pair-then-stream), and
  `./bundle.sh` all passed; the bundle's ad-hoc signature verifies.
  Real-Mac/installed-host pair-only naming passed on 2026-10-10: the user confirmed
  the Mac name appeared in the PC's Forget submenu before Connect; the host log
  names the Mac in a tray Forget before the first stream on this build. A real-Mac
  service-restart persistence check remains unreported (SESSION-HANDOFF.md).
  Old “paired <IP>” entries need named re-pair or streaming
  to refresh. Keep this rollout separate from topology work.
- The README status table is the source of truth for status; keep it current.
- Forget diagnostics (2026-10-09): a real Mac attempt remained preparing and
  timed out after 6 s; Network.framework logs showed every resolved endpoint
  as `Local network prohibited`, even though Relay's Local Network switch was
  enabled. The app was running across bundle rebuilds. Quitting/reopening the
  rebuilt bundle cleared that block: real-PC TCP + Noise and the PIN sheet
  now pass without changing pairings. The client now preserves
  failure reasons, reports explicit local-network denials when Network.framework
  exposes them, and says an unconfirmed PC may still remember the Mac rather
  than asserting it does. UnpairTask's timeout/reply completion is serialized
  on the connection queue. Swift tests (102) and isolated real-UnpairTask checks
  (confirmed/busy/timeout/changed key) pass; no host or protocol change.
  A separate host gap was reproduced: after local-only Forget, the PC still
  knew this key, so `server.rs` left the initial request at HELLO_TIMEOUT
  (5 s). The PC closed the Mac's PIN sheet before manual re-pair could complete;
  only unknown keys got PAIR_TIMEOUT (120 s). This is fixed in the installed
  `eb2f280` build as of 2026-10-10; clearing the PC's entry is no longer needed
  to obtain the full PIN-entry window.
  The Mac must not send CLIENT_HELLO
  or guess a PIN just to hold that socket open.
  The user initially requested a Windows-session handoff, then authorized the
  source fix. On 2026-10-10 the Mac session moved PAIR_TIMEOUT before every
  client's first encrypted request and added three production-handler loopback
  regressions (known/unknown/busy, six-second PIN delay, durable name storage,
  display/session preservation). No client or wire change. Windows verification
  on 2026-10-10 passed: fmt, 145 unit tests plus the probe integration test (one
  opt-in desktop test ignored), strict all-target clippy and release build.
  Elevated `install-host.ps1 -SkipDriver` succeeded; service Running and installed
  executable SHA-256 matches the release (`EEEEA9E0...B3A5C460`). Installed-service
  probe checks passed: named pair-only, known-key re-pair after 12 seconds,
  delayed wrong-PIN rejection and delayed correct retry, immediate UNPAIR.
  A temporary loopback proxy delayed the unchanged probe's first encrypted
  request; no CLIENT_HELLO was sent. Only a dedicated temporary identity was
  paired and then removed; the original peer list was preserved. On 2026-10-10
  the user reported all five real-Mac checks passed: delayed PIN-sheet entry,
  wrong-PIN retry, confirmed Forget, pair-only tray naming, and ordinary
  Connect/disconnect with physical monitors/layout restored. Logs support delayed
  known-key pairing, a failed-PIN attempt followed by successful pairing, UNPAIR,
  the Mac name before streaming, 3024×1964@120 streaming and successful restore.
  Full 120-second expiry and real concurrent-stream pairing were not exercised;
  repeat counts were not specified.

## How the host and client work (details you need before changing them)

- The host is windowless (`windows_subsystem = "windows"`). `serve` = tray icon +
  `%ProgramData%\Relay\host.log`; from a terminal it attaches to that terminal instead
  (`AttachConsole`, with the inherited std handles put back so `> file` still works).
  Subcommands print after the prompt returns — a GUI process is not waited on.
- Tray (`host/src/tray.rs`): hidden **top-level** window, not `HWND_MESSAGE` — message-only
  windows never get `TaskbarCreated`, `WM_SETTINGCHANGE` or `WM_ENDSESSION`, all of which
  it relies on. Menu is built on each click from `status::HostStatus` (server writes,
  tray reads): status line, `Disconnect` while streaming, separator, `PIN: 123 456` (copies),
  `Get new PIN` (the menu **stays open**: a Win32 popup closes on any choice, so a
  `WH_MSGFILTER` hook on the tray thread swallows that item's click/Return, rotates the PIN
  and `ModifyMenuW`s the open item; the `#32768` popup window does not repaint on its own,
  `InvalidateRect` it), `Forget paired MacBook ▸` (one id per entry, Yes/No `MessageBoxW`,
  `PeerList::remove`), `Start on system boot` checkbox, `Exit` (2026-09-19). The PIN
  rotates after every successful pairing and is never logged. The tooltip follows the
  session (1 s timer, `NIM_MODIFY` only when the text changes; `szTip` is 127 units, the
  client name is clamped). The tray ends a session by storing a `stop_reason` in
  `SessionInfo::end_request` (`AtomicU8`, `NO_END_REQUEST` = none); `pump` polls it at its
  stop checks, sends the STREAM_STOP, half-closes and lets the reader drain for up to 2 s
  (the RST rule below). Disconnect = reason 0 (the Mac already shows "The PC ended the
  session"), Forget of the streaming Mac = reason 4. **Dark menu:** Win32 popup menus
  are light unless the process calls uxtheme's undocumented ordinal 135
  `SetPreferredAppMode` (2 = ForceDark, 3 = ForceLight; on 1809 that ordinal is a
  different function, so gated on build ≥ 18362) and 136 `FlushMenuThemes`; done at
  start and on `ImmersiveColorSet`, following the taskbar theme like the icon.
  MessageBox stays light. **Exit** = `ControlService(STOP)` on the Relay service from the
  worker (SYSTEM may); the service's stop path sets the quit event and the tray loop
  quits as before — nothing Relay is left running. **Start on system boot** =
  `QueryServiceConfigW`/`ChangeServiceConfigW` start type with `SERVICE_NO_CHANGE`
  (`windows_service::change_config` would rewrite the binary path); while it is off the
  service also skips the `SessionLogon`/`ConsoleConnect` respawn, `Start-Service Relay`
  is the manual way in, and so is a **double-click on the exe**:
  `main.rs::hand_off_to_service` — no console, no `--no-vdd`, service installed but stopped
  → relaunch elevated as `relay-host service start` (`ShellExecuteW runas`;
  `service::start`) and exit, instead of a user-session dev run. From a terminal a dev run
  still happens (that is how `Stop-Service Relay` + `relay-host` is used). Greyed in a dev
  run (`under_service` = the quit event exists).
- **Pairing digest `pg` in the TXT record (host + spec done 2026-09-20; Mac side done
  2026-09-19).** `PeerList::digest()` = first 4 bytes of SHA-256 over `DIGEST_LABEL` + the
  sorted paired keys (the label keeps a lone client's digest from being its fingerprint),
  hex; renames do not move it. The `readvertise` thread in `server.rs` ticks every
  second: `PeerList::reload_if_changed()` (mtime; picks up `relay-host paired --forget`
  from another process, which the running host used to overwrite on its next save),
  then re-registers the record when the digest or (every 5th tick) the IPv4 set moved.
  A tray Forget is on the air in about 1.5 s. Mac side: `DiscoveredHost.pairingDigest`
  (carried forward by `HostListDebouncer` on a TXT-less report like `pk`, and not part of
  `PickerRows.Appearance`, so a digest change alone redraws nothing);
  `verified-digests.txt` next to `hosts.txt` holds the last digest the handshake
  confirmed per host key (cleared by `ClientState.forget`). `AppDelegate.checkPairings`
  (on every browse update, at launch, and after a session, cancel, forget or check
  ends) picks the next known host whose advertised digest is neither verified nor
  already attempted this run (`PairingVerifier`, pure; one attempt per digest value so
  an unreachable host is not re-dialled on every update) and runs one `VerifyTask`
  (`HostConnection.verifyOnly`: msg1–msg3, read `paired` from SERVER_HELLO, close; never CLIENT_HELLO, so
  it never touches the display or another Mac's session). `paired` 1 stores the digest;
  0 forgets the host locally, reloads the picker and flashes "PC forgot this MacBook".
  Checks only run while no connection or unpair is in flight, one host at a time, and
  an answer that lands after a Connect/Pair/Forget started is dropped (`retract`).
  Same outcome from a plain Connect whose handshake says `paired` 0 for a known host
  (`HostConnection` forgets it itself, next to where it `remember`s; an explicit Pair
  still gets the PIN sheet) and from STREAM_STOP 4 mid-session; `--host` mode forgets
  and the re-dial then asks for the PIN as for an unknown host. Verified 2026-09-19 against
  `fakehost --forget` / `--pg` / `notpaired`
  (all four paths) and on the hardware over the cable: the launch-time check stored the
  PC's digest, a tray Forget on the PC moved the row to Available within seconds with
  nothing touched on the Mac, and Pair from the picker brought it back (same digest as
  before, since the PC's list held the same one key). Each check shows up in `host.log` as
  `connection with … ended with
  error: waiting for the first message` (the client hangs up after SERVER_HELLO);
  a quieter line is the host's to add. Spec: PROTOCOL.md Discovery + Forgetting.
- The Relay service (`relay-host service run`, LocalSystem, session 0) spawns
  `relay-host worker` into the **console session as SYSTEM**: duplicate our token,
  `SetTokenInformation(TokenSessionId)` (needs SE_TCB — only LocalSystem has it),
  `CreateProcessAsUserW` on `winsta0\default`. Desktop Duplication and `SendInput` only
  work from a thread bound to the *input* desktop (`OpenInputDesktop` +
  `SetThreadDesktop`, `host/src/desktop.rs`); a user process may not open `Winlogon`,
  which is why a dev run gets `E_ACCESSDENIED` at the lock screen — the session then
  waits (`DesktopNotCapturable`, no 15 s limit) until the desktop changes.
  Threads that own windows (the tray) can never bind. Worker exit 0 = down
  until the next `WTS_SESSION_LOGON`/`CONSOLE_CONNECT`; non-zero = service runs
  `restore` in-session and respawns (5 s / 60 s backoff). `Stop-Service` sets the
  `Global\Relay.quit.<session>` event the worker's tray loop waits on. At the login
  screen there is no Explorer: `NIM_ADD` fails, the icon arrives on `TaskbarCreated`.
  SCM's own recovery restarts a crashed *service*; Task Scheduler's
  `RestartOnFailure` never restarted a crashed process — that is why the logon-task
  design (2026-09-17) was replaced.
- **Topology context (2026-10-09, one user-reported pass per retest):** setup used the connection
  thread's inherited `Default` desktop; shutdown restore could run on the tray thread,
  which owns a window and cannot rebind. `desktop::with_input_desktop` now uses a fresh
  scoped thread for acquisition, CCD snapshots, exclusive setup/reassertion and restore,
  validates the actual process session against the console and requires `WinSta0`.
  Each operation opens the current input desktop; the handle stays alive until the
  thread switches back. Capture/input binding is unchanged. The worker's quit event
  uses its actual process session, not a potentially changed console id.
  Error 5 is a context/access failure, not evidence of a bad mode; it no longer falls
  through to another topology API. Removed the invalid `0x24a0` retry:
  `SDC_ALLOW_PATH_ORDER_CHANGES` requires `SDC_TOPOLOGY_SUPPLIED`, not
  `SDC_USE_SUPPLIED_DISPLAY_CONFIG`. Read-only query/empty-layout waits are bounded;
  no modeset retry loop was added. Failed restore snapshots survive and must recover
  before the next acquisition replaces them. Diagnostics include process/thread ids,
  actual/console sessions, station, thread/input desktops, paths/modes and virtual
  monitor presence. The logs establish successful worker launch and handshake, but
  cannot prove context was the sole cause. The later retest log confirms restoration
  on Winlogon and no recurrence of topology error 5/87 or DISP_CHANGE -1. A shutdown
  recovery attempt briefly found no virtual monitor while cleanup disabled it; the
  subsequent restore succeeded. Repeat runs must still distinguish true pre-session
  setup from a locked user session (SessionLogon preceded the reboot connection in
  this log). Retest steps and log reading: SESSION-HANDOFF.md.
- State is `%ProgramData%\Relay` (SYSTEM has no meaningful `%LOCALAPPDATA%`): Users
  RX, `identity.key` SYSTEM/Admins only (`restrict_to_admins` after creation). The
  installer and the first run as a user migrate the old `%LOCALAPPDATA%\Relay`. So
  `pin --new` / `paired --forget` need an elevated prompt; the tray does both as SYSTEM
  (`Get new PIN`, `Forget paired MacBook`).
  One serving host per session is enforced with the `Local\Relay.host` mutex + a
  message box (SYSTEM worker and a user dev run share session 1's namespace).
- Tray icons are `host/assets/relay-{light,dark}.ico`, embedded with `include_bytes!`
  and chosen by `SystemUsesLightTheme`. They are rendered **on the Mac** from the
  picker's glyph: `swift run Relay --render-icons ../host/assets` (done 2026-09-17;
  rerun after any change to `Glyphs.swift`). The Mac app icon is the same glyph:
  `swift run Relay --render-app-icon Assets` writes `client/Assets/AppIcon.icon` (an
  Icon Composer document — blue fill + the glyph as a 1024 px layer — that `bundle.sh`
  compiles with Xcode's `actool` into `Assets.car`; **the system renders the light, dark,
  clear and tinted appearances from it**, which is the only way a macOS icon gets a dark
  mode: an `.icns` has no appearance slot and an asset catalog silently drops dark
  variants for macOS icons) plus `Relay.icns`, the same drawing flattened, used when
  actool is missing and as `applicationIconImage` for a bundle-less `swift run`. Both
  are checked in. `bundle.sh` also stamps `CFBundleVersion` with the commit count, so
  About says "0.1.0 (134)".
  About Relay is the standard panel plus the repo link as credits; copyright is
  `NSHumanReadableCopyright`. Licence: MIT (`LICENSE`, `host/Cargo.toml`).

## Running it

PC: `host\target\release\relay-host.exe`, installed as the `Relay` service with a tray icon;
subcommands `pin`, `paired`, `service install/uninstall`, `gpus`, `encoder-caps`, `displays`, `layout`,
`restore`, `attach-test`. Installer once, elevated: `tools\install-host.ps1`. See
`host/README.md`.

Mac: `swift run Relay` opens the picker; flags are in `client/README.md` (or `--help`).
User-visible behaviour (pairing, connect, rename, forget, menus, shortcuts, settings) is
documented there. What follows is only the mechanics that are easy to break:

- Control / Observe is PC ▸ Control / Observe. Mid-session it goes through the local event
  monitor, saves the pref, releases held keys when turning off, and flashes
  "Controlling/Observing <PC>". ⌃⌥⌘K sits on whichever item is not current, so it always
  switches.
- A dropped session returns to the picker; the kiosk window opens on the first decoded frame.
- The picker is now SwiftUI (`RelayApp`, `PickerModel`, `HostPickerView`);
  `HostPickerWindowController` only adapts native window/screen callbacks.
  `PickerModel` and UI callbacks are main-actor isolated. `SessionPipeline`
  keeps frame/config/decoder work off the main actor, serializes reset with
  cancellation, and rejects retired connection callbacks. First-frame and
  frame-size UI updates also verify the decoder generation.
- Rename commits on Return/focus loss and cancels on Escape. Do not let the
  default Connect/Pair button consume Return while editing. Row single taps
  explicitly select the host; the double-tap handler alone consumes native
  list selection. PC ▸ Connect is disabled while renaming so Return reaches
  the field. The picker keeps the pre-SwiftUI layout and wording (2026-10-10,
  user request): hidden title bar, 410 wide (narrowed from the old 460 so the
  footer mode row has even gaps; the resolution popup takes the slack) and as
  tall as the list (`PickerLayout`: rows, titles, 20 pt of list insets,
  a minimum of both section titles plus two full rows, so zero PCs, one
  available PC and one paired PC use the same window size; scrolling past
  five PCs at half a row taller so a cut row
  shows there is more, scroller hidden unless it overflows;
  the window grows downward). Once any PC is known both sections are
  always listed: Paired shows "No paired devices yet" when empty, Available a
  "Searching for other PCs…" row with the spinner in the icon column (the title's
  own spinner shows only when that row does not). Clicking a title folds
  its section (`PickerModel.toggle`, in memory only); a section folds only
  while it lists two or more PCs (no chevron, not a button otherwise) and
  reopens when it drops below two (2026-10-17, user request); a folded-away selection
  moves to the first visible PC, unfolding with none selects the first, and
  `preselect` unfolds its PC's section. The list is one `ForEach` over
  `PickerModel.listItems` with stable IDs (titles by section, PCs by section +
  name) and its rows update in place with animations off; only the window
  height animates (`withAnimation` in `reloadPairing`). Position-matched rows
  cross-faded titles, and List's insert/remove/move animations slid rows over
  fading ones while the window snapped to size. Available always listed with a mini spinner (no
  "Looking for PCs…" text, user request). With no PC at all there are no
  titles: a centered "No PCs Found" empty state (title, spinner, instruction)
  sits over the empty list at that same minimum size. No PC count in
  the footer (status only), `Style` metrics, tower
  glyph rows with "via <link>", plain header rows (not `Section`, whose header
  floats on a band), hover card (`HoverCard`: AppKit panel, SwiftUI grid,
  `HoverCardAnchor` tracking area behind each row), the old settings popover,
  six-box PIN entry (`PINEntryView`, AppKit, wrapped by `PINEntry`) and Forget
  alert wording. Keep the SwiftUI colors: the inset list's own background spans
  the window (its selection inset is fixed at 10 pt; a painted background did
  not match the list's translucent fill), and the footer has no material.
  Settings (2026-10-18, user request: the popover was too tall and folding
  sections cost clicks) is SwiftUI's `Settings` scene in `RelayApp`: a
  window with toolbar tabs Video / Input / Monitoring (`SessionSettingsView`,
  a `TabView`, last tab in `@AppStorage("settingsTab")`). The footer gear is
  a `SettingsLink` (disabled with the rest of the mode row until a paired PC
  is selected); Relay ▸ Settings… (⌘,) is SwiftUI's own item, always
  enabled; View ▸ Bitrate ▸ Custom… is a `SettingsLink` too. It replaced the
  gear's popover (its right/below placement, `showSettings`,
  `settingsFitsRight`) and the folding sections. `NoInitialFocus` still
  clears the bitrate field's first responder once when the window becomes
  key. The toolbar's band and separator are each form's top scroll edge
  effect, drawn only once the form counts as scrolled, or on hover: a probe
  (2026-10-18) found Video's top inset 88.125 pt against an 88 pt offset
  (always "scrolled", always banded) and Input's 88/88 (banded on hover
  only), so hovering and switching tabs flashed the header.
  `.scrollEdgeEffectStyle(.hard, for: .top)` on every pane draws the band
  at rest everywhere (user request). `toolbarBackgroundVisibility` and
  `scrollEdgeEffectHidden` did not change it. The user confirmed the band
  stays steady on hover and when switching tabs. Video starts with Resolution and Refresh rate pickers bound to the
  same `PickerModel.mode` as the footer (user request; Refresh rate is
  disabled when the screen offers one rate). Each tab is one untitled
  `.formStyle(.grouped)` Section, like a
  System Settings pane: mini switches (`SettingSwitch`) with the detail as
  the toggle label's second Text (the form draws it as a subtitle; it dims
  a disabled switch but not its label, so `SettingSwitch` dims both Texts
  from `isEnabled`), Encoder as a form Picker, Bitrate as a LabeledContent
  row (slider + rounded-border field: a grouped form draws fields
  borderless; disabled while Automatic bitrate is on, user request).
  `Style.settingsWidth` 420 pt (at 380 "Show session performance report on
  disconnect" wrapped), `scrollDisabled` + vertical `fixedSize`, so the
  window sizes to each tab. Subtitles describe the current choice
  (`SettingDetail`, `EncoderQuality.detail`); an unavailable option shows
  its reason instead. A test keeps every subtitle within the widest seen on
  one line. Subtitles stay on one line (user request; ⌘⌥⌃ glyphs render
  wider than they look, measure). Checked in the bundled app: all three
  tabs, ⌘, in the Relay menu.
  Control the PC sits first under Input and disables the options that only
  matter while forwarding; while it is off they show off (user request) but
  keep their saved values. VSync flips `displaySyncEnabled` on the
  live layer; Natural scrolling follows the Mac (`com.apple.swipescrolldirection`)
  until chosen, and the sign is decided per event from
  `isDirectionInvertedFromDevice`, since AppKit's deltas already follow the Mac.
  Connect when Relay opens (auto-connect to the last PC) was removed on
  2026-10-18 at the user's request, with its General section. Keeping the
  Mac awake needs no setting: `enterKiosk` holds a display/system idle-sleep activity.
  `--codec h264|hevc` (hidden, for measurements) narrows CLIENT_HELLO's
  codec mask; the PC already falls back to whatever the Mac offers.
  Picture options (2026-10-10, Mac side ahead of the host by user decision;
  the host and PROTOCOL.md followed the same day with no wire change, see
  Status): Encoder / Full color (4:4:4) / 10-bit color are enabled only
  when the selected PC's TXT `enc` lists them and, for color, when
  `VideoCapabilities` (hardware-only VT sessions for canned parameter sets)
  says this Mac decodes them; disabled ones show why in their note. The
  CLIENT_HELLO extension goes only to hosts with SERVER_HELLO cap `0x02`.
  The decoder is asked for exactly one output format chosen from the SPS
  (`HEVCStreamFormat`): given a list, VideoToolbox may pick 8-bit 4:2:0 and
  convert 10-bit/4:4:4 down. 10-bit planes are MSB-aligned in 16 bits
  (`r16Unorm` reads code × 64 / 65535), so `conversion(for:)` scales by
  65535 / 64. 8-bit streams keep the `bgra8Unorm` layer that latency was
  measured on; 10-bit frames switch it to `bgr10a2Unorm` (unmeasured).
  Automatic bitrate (`VideoBitrate.automatic`) keeps 120 Mbps' bits per pixel
  at 3024×1964@120, 20–200, 80 over Wi-Fi. A missing `bitrateAutomatic`
  key with a saved bitrate other than 120 stays manual (every old save wrote
  the bitrate). `setBitrate` ignores the value already shown: the field
  writes it back on focus loss, which turned Automatic off. Verified end to
  end with `fakehost --clip` (420v/x420/444v/x444 outputs, 4:4:4 text sharp
  where 4:2:0 smears); the real PC streams all four since 2026-10-10 (probe +
  ffprobe), and the real Mac streamed all of them on 2026-10-17
  (`docs/LATENCY.md`).
  A disabled segmented control still draws its selection in the accent
  color, so the refresh-rate picker has no selection (an optional binding
  returning nil) while it is disabled; a gray tint looked odd. Its background
  stays brighter than the disabled popup and gear (dark: 61 vs 50 on a 41
  footer): macOS never dims a disabled NSSegmentedControl's bezel, in any
  segment style (checked in plain AppKit on 27.0). Kept as the system draws it
  (user decision); filters cannot match both bezel and text.
  Use `Text(verbatim:)` for numbers: SwiftUI's localized interpolation groups
  digits ("3,024 × 1,964").
- Latency HUD (2026-10-17): user-facing names since 2026-10-18 (user
  request): Settings ▸ Monitoring (last tab; named Performance until
  2026-10-18, renamed because it changes nothing) ▸ Show performance overlay / Show
  session performance report on disconnect, View ▸ Performance Overlay and
  Last Session Performance Report, window "Session Performance Report".
  Code names (`StatsHUD`, `SessionReport`, `showLatency`, `--latency-stats`)
  are unchanged. Never put a view over the stream's Metal layer;
  that blocks direct-to-display and cost ~2.5 ms of time to screen. `StatsHUD`
  draws the HUD with CoreGraphics/CoreText off the main thread (4 Hz, only
  while on); `MetalPresenter.setOverlay` uploads it as a new texture and
  `encode` blends it as a second quad in the same pass (premultiplied, nearest
  sampling, pixel margin). It refreshes only when a video frame arrives.
  HUD layout (2026-10-18, user request): the headline is Desktop → screen
  ("PC → your screen", colored against three refresh intervals) once
  synced, else receive → screen (one interval). Header (2026-10-18, user
  review): median + fps on one line, then "p95:" under the median and
  "N skipped/s" (decoded − shown, only past 1/s or 5 %) under the fps; no
  description line (the report still uses `Summary.label`), no divider
  before the sparkline. A receive-fallback caption (`Summary.unsyncedNote`)
  says “clock not synced” only without an accepted exchange, or “source timing
  idle” when source samples have expired while sync remains healthy. The sparkline plots each point column's worst
  frame (`columnMaxima`) and labels the budget "25 ms" on a chip. Detailed
  = a proportional bar (PC/Network/Mac split, not budget-scaled: user
  decision; short segments get 4 pt) and three groups (PC = content age +
  PC work, Network = "one way" or RTT/2, Mac = decode and display), then
  input → PC and the stream as label/value rows: Video, Picture, Display
  only when VSync is on, Link, Data (drawn brighter: the only live value). What to show is `StatsHUD.Summary` (pure, tested); the
  developer figures (offset, RTT/2, frame transfer, decrypt, p99, counters)
  live in the session report's Details page. The report (same day) uses
  `SessionReport.summary` (= `StatsHUD.Summary` over the session's
  histograms) for its header, histogram and breakdown, plus
  `SecondMedians` (median per second of the headline measure) for a
  timeline. Summary mirrors the HUD (2026-10-18, user review): HUD-style
  header instead of tiles (median + "p95:", fps + "% skipped"), the
  timeline in the text color and red above the budget (`runs` cuts it at
  the crossing), budget labelled "25 ms" on both charts (the histogram's
  adds the share of frames over), "ms" on axis values, chart titles above
  each chart at body size with ~10 pt measured to the first mark (the
  breakdown title's 1.5 pt bottom padding evens it), "Latency split by
  stage, median", then Input → PC / Data as label/value rows. Details
  (same review) groups `report.rows` by name (`detailSections`): Desktop →
  screen bold, then PC / Network / Mac with the Summary's dots and Input
  (clear dot for alignment); Network (RTT/2 est.) only replaces Sent →
  received when that is empty (user request; the Markdown keeps every
  row). Frames / Link / Clock are label/value rows; counts use grouping.
  Details is ~60 pt taller than Summary. Summary/Details is a segmented control that swaps content in
  place: a folding Details grew the window to 1,129 pt, taller than a
  MacBook screen. Never put a `GeometryReader` in the report: in the
  self-sizing window it looped constraint passes until AppKit crashed the
  app (`NSGenericException`, 2026-10-18); the bar is sized from the fixed
  width. Panel alpha 0.9 so bright content behind it
  does not show through. Clock sync: see Status, "Clock sync + frame timing".
  The first 3 s after STREAM_START (`LatencyStats.warmUp`) are not recorded
  and the HUD stays hidden until they pass.
  Mac-only stages (2026-10-18): `ReceiveTimer` (pure, in
  `ReceiveTiming.swift`) follows the receive loop's reads; a FRAME's
  transfer is estimated from bytes that arrived *after* its first record
  over that time, scaled to the whole frame (single-record or already
  buffered frames give none: buffered is the Mac reading late, not a fast
  link). Decrypt is timed around `SecureChannel.open`. Input → sent is
  `NSEvent.timestamp` → `sendRaw` on the connection queue (both
  `systemUptime`). The read pattern is unchanged: no extra read per frame.
  `LatencyStats` records into fixed 0.1 ms histograms (per-second ring for the
  10 s HUD window, plus whole-session); `takeSessionReport` runs once per
  STREAM_START on the first end path, logs `Session report:` and opens the
  report window when `showSessionReport` is set (settings: Show session
  report on disconnect; default off and independent of the HUD since
  2026-10-18, user request: latency is measured either way). Prefs keep `showLatency` and add
  `latencyDetailed`; quitting mid-session also logs the report. Unit-tested
  (stats, HUD bitmap, overlay pixels) and checked live against
  `fakehost --clip` with an isolated `CFFIXED_USER_HOME`: HUD in the frame,
  ⌃⌥⌘L cycling, its 50 fps matching fakehost's 49.8 sent, and the report
  opening over the picker after ⌃⌥⌘Q. Real PC, 2026-10-17: median time to
  screen 3.5 ms with the HUD on, 3.4 ms off.
- Status text (2026-10-18, user request): the stream window shows only the
  1.5 s "Controlling/Observing <PC>" flash; connection steps, "Starting…",
  "Streaming…" and "Disconnected:" go to the log (`--host` mode included),
  and an identity-key failure flashes in the picker. Every footer line must
  fit whole: `SessionText.footerWidth` (255 pt of 11 pt system: window −
  margins − gap − a ~99 pt Connect) and `nameWidth` (105 pt) are measured
  widths, not character counts; `fit` only clips outside text (unknown
  reasons, names). `SessionText.starting` drops picture settings from the
  right until the line fits. Settings are `formatSettings` joined with
  commas, never " · ". Tests measure every footer line with the widest name.
- Every Connect (footer button, Return, double-click, PC menu, context menu)
  goes through `PickerModel.requestConnect()`: a paired PC whose
  `DiscoveredHost.connectsOverWiFi` gets the Wi-Fi alert first, unless
  `SuppressWiFiConnectionWarning` is set by its "Don't ask again". The alert
  lives in its own `WiFiConnectAlert` view because `dialogSuppressionToggle`
  applies to every dialog presented within the modified view (Forget showed
  the checkbox too). Pairing and Cancel never warn. After it (or straight
  away), `LargerDesktopAlert` (2026-10-18, user request) asks when
  `PickerModel.desktopEnlargement` is set: the stream's pixel width is
  under 95% of the screen's width in points (75% / 50% on a 1× screen;
  never on Retina), so Windows at its 100% floor looks larger. Connect /
  Cancel (a Use Native button was removed, user request), a short message
  ("Windows will look about 2× larger on this display. For normal size,
  choose Native."); suppressed by `SuppressLargerDesktopWarning`. The Wi-Fi alert's Connect
  calls `confirmWiFiConnect`, which presents this one on the next main
  actor turn (one alert at a time). Titles are plain Strings: localized
  interpolation would group "2,560". Checked in the bundled app on the
  ED273UR at 75% (before the text was shortened): "Connect at 1920 ×
  1080?", "about 1.3× larger".
- Menus are SwiftUI commands in `RelayApp.swift`; contribute to the existing
  View command group to avoid duplicate View menus. Validate against picker
  focus. `StreamView.performKeyEquivalent` still swallows command shortcuts
  during streaming; the local monitor handles exit/control/latency shortcuts.
- The stream still uses the native `StreamWindow`/`StreamView` and Metal layer.
  SwiftUI never wraps the full-screen video or observes individual frames.
- Refresh rates (2026-10-18, user decision): the footer offers the picker
  screen's top rate and 60 Hz (`StreamMode.refreshRates`; two segments so
  the footer fits), following the window between displays. A user-reported
  stream at 2560×1440@144 to an external monitor worked on the real PC;
  165 Hz has not been streamed. `--max-fps` picks the highest offered rate
  at or under it. Optional **Extra frames** (2026-10-20) is a persisted switch
  below Refresh rate in Video, default off: `SessionPrefs.requestedRefresh`
  asks for ceil(selected × 1.2), capped at 240 and any explicit `--max-fps`.
  Both the picker bitrate preview and the connection use this requested
  rate; Windows' VDD/encoder use the existing CLIENT_HELLO refresh field.
  The selected Mac cadence stays separate in `StreamInfo.displayRefresh`
  for HUD/report budgets and the Display row. Carries and FPS counting are
  unchanged; oversupplying can intentionally replace frames. 211 Swift
  tests, 24 isolated loopback checks, release bundle/signature and live
  Settings checks pass (120 → 144,
  60 → 72, dynamic bitrate, restored to off). Real-PC 144-on-120 latency,
  pacing, load and restore remain pending in SESSION-HANDOFF.md.
  Per user request, the HUD's headline FPS text has a fixed 120 ceiling;
  raw rates in telemetry/report and skipped-frame calculations are unchanged.
- Build arm64 only, minimum macOS 26 (raised from 14 on 2026-10-18, user
  decision: 14 was never tested, and every Apple silicon Mac runs 26;
  swift-tools-version 6.2). Latest stable OS is the
  qualification target, not automatically the deployment floor. Never claim
  qualification from compiling with that deployment target. Metal and hardware
  VideoToolbox decoding are required; no AVSampleBufferDisplayLayer fallback.

## Hard-won facts — do not relearn these

- **Renamed from TravelDisplay to Relay (2026-09-16).** Every user-visible name and identifier
  changed except the HKDF info string and the `TDH2` handshake magic, which stayed so pairings
  survived; protocol v4 replaced both (2026-10-08) and keeps the identity keys, so pairings
  survive it too. State directories move from the old name automatically on first run;
  re-run the installer once on the PC (it removes the old task and firewall names). The GitHub repo is
  `theamanali/relay`; a local clone directory may still be called `travel-display`.
- **MTT Virtual Display Driver's control pipe must never be used.** `SETDISPLAYCOUNT` /
  `RELOAD_DRIVER` crash its user-mode host; after 5 crashes Windows parks the device at
  Code 43. The device node is the switch: the host enables/disables it in-process
  (`host/src/devnode.rs`, CfgMgr32 `CM_Disable_DevNode`/`CM_Enable_DevNode`, needs
  admin — the SYSTEM worker or an elevated prompt). The physical monitors a session
  disabled are listed in `%ProgramData%\Relay\physical-locked.txt` so `restore` can
  re-enable them after a crash. There is no `Restart-PnpDevice`; use Disable/Enable.
- The driver keeps one monitor whenever enabled (count 0 == 1), so "invisible when idle"
  means the device is **disabled** between sessions. Enabling takes ~2 s.
- `SetDisplayConfig(SDC_TOPOLOGY_SUPPLIED)` fails with ERROR_GEN_FAILURE (31) for a layout
  Windows has never stored. Attach the monitor normally first, read back its modes with
  `QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS)`, then apply a complete one-path config with
  `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES`. Never save the virtual-only layout
  to the database. The snapshot for restore lives in `%ProgramData%\Relay`.
- DXGI lists the driver's proxy adapter with the **same name and VRAM as the real GPU**;
  D3DKMT's `IndirectDisplayDevice` flag tells them apart (`gpu.rs`).
- **Never block inside `AcquireNextFrame`** on the native path. With `ID3D11Multithread`
  protection on, the waiting thread holds the device lock and NVENC cannot finish the
  previous picture until the wait returns (encode time becomes one frame interval).
  The capture thread polls `AcquireNextFrame(0)` on a sub-ms timer instead.
- When the PC's monitors are asleep, Desktop Duplication delivers zero frames: a capture
  test that suddenly produces nothing is that, not a bug. Send an input event first.
- `attach-test`, `probe` sessions and anything that goes through `topology::exclusive`
  **black out the PC's monitors** (and any agent app running on it) for the duration. Use
  `--no-vdd` for pipeline tests; let the user run the exclusive ones.
- The mDNS TXT record is static once registered: `server.rs` re-registers the service
  when the host's IPv4 set changes (polled every 5 s) so the advertised `ip` facts follow
  a late 169.254 self-assignment or a switch↔cable move, and when the pairing digest
  `pg` changes (polled every 1 s).
- **A PC that vanishes without a goodbye stays in Bonjour's cache until its TTL runs
  out.** `mdns-sd` announces SRV/A with a 120 s TTL (PTR/TXT 75 min; the setters are
  `pub(crate)`, even in 0.21, so the host cannot shorten them); mDNSResponder re-queries at
  80-95 % of the TTL and, unanswered, flushes the SRV and then reconfirms the PTR, so the
  row lives 24-120 s after a cable pull (measured 2026-09-20). A dial to such a row never
  ends on its own (Network.framework only times out a SYN it has sent; the connection sits
  preparing/waiting), so picker attempts carry `HostConnection.Options.dialTimeout`
  (`AppDelegate.pickerDialTimeout`, 12 s, one deadline for the pinned attempt and its
  unpinned retry; --host mode has none) and end "couldn't reach the PC"; when the attempt
  never reached `.ready` (`everConnected`), `BonjourReconfirm.reconfirm(host)` sends
  `DNSServiceReconfirmRecord` for the PTR (rdata = the instance's full name in wire
  format) on every interface the host was seen on. mDNSResponder re-queries and flushes it
  ~7 s later; the browse drops the row. Verified on the hardware: Pair on the unplugged
  PC's row, footer at 12.6 s, PTR gone at +7 s. A record this Mac registered itself
  (`dns-sd -P` proxies, `fakehost`) never flushes: this Mac answers its own re-query.
- **Unplugging the Mac's cable makes mDNSResponder purge the TXT, not the host.** It
  drops everything learned on the vanished interface; the PTR usually survives on Wi-Fi
  but the TXT (with `pk`) was cached on the cable alone and is not re-fetched until its
  TTL (measured 2026-09-18: 53 s TXT-less on Wi-Fi, until the cable came back). That
  looks exactly like a host's goodbye (TXT gone, PTR still there), so `HostListDebouncer`
  tells them apart by whether the result's interface set changed in the same update and
  carries the last key/facts forward. A same-link TXT withdrawal now gets the normal
  2.5 s removal grace too: re-registering after a pairing digest or address change must
  not briefly remove the host's row. Repeated TXT-less reports do not extend that grace;
  a returning TXT updates the facts and cancels removal. A picker row is re-rendered on every
  `NWPathMonitor` update too: a freshly plugged cable is seen by Bonjour (IPv6
  link-local) seconds before it has an IPv4, and Bonjour never fires for the latter.
- **An open Netflix tab in Chrome (2026-10-17), even paused, throttles
  presentation to one frame every 20–25 ms** while decode keeps up; Metal
  still says Direct and the panel stays at 120 Hz. Open/closed A/B against
  fakehost: ~20–30 ms vs 3.6–3.7 ms p50. It looked like a regression in three
  builds until the tab was closed. Close such tabs before measuring
  (`docs/LATENCY.md`). Relay opts into Game Mode (Info.plist games category +
  `GCSupportsGameMode`), which only partly helps. `CFFIXED_USER_HOME`
  isolates Relay's files but not its UserDefaults: a "fresh" test run still
  uses the real HUD/prefs settings, and fakehost writes `fakehost.key` into
  its working directory.
- **Never `NSCursor.hide()` during a stream (2026-10-17).** With the cursor
  hidden, any pointer motion, even on another display, held VSync-off
  presentation to ~50 fps and ~25 ms to screen (idle: 111 fps, 2.5 ms).
  `StreamView.hidesCursor` sets a transparent cursor rect instead
  (`docs/LATENCY.md`, "the hidden cursor").
- `StreamView.flagsChanged` decides press vs release from its own held-key record
  **and** the event's flags: the record alone tells left from right, but forwards the
  release of a modifier it never sent down (control turned on by ⌃⌥⌘K with ⌃⌥⌘ still
  held) as a press, which sticks on Windows.
- **The PIN sheet belongs to one connection attempt.** `PINPrompt` is one-shot;
  invalidate it before dismissing when the socket ends, so the SwiftUI
  `onDisappear` callback cannot cancel a later attempt. The picker uses a
  SwiftUI sheet and `--host` uses the same view inside a native sheet;
  `PINEntryView` takes the keyboard when its window becomes key, which is what
  makes the native sheet work. Preserve six-digit paste/autosubmit, wrong-PIN
  retry and cancellation; accessibility value/selected-text setters type into it. Do not reset
  connection deadlines merely because the sheet redraws.
- **SwiftUI opens the picker only on a LaunchServices launch** (Finder, Dock,
  `open`). Run directly (`Relay.app/Contents/MacOS/Relay --scale 0.75`), a
  binary linked against the macOS 26+ SDK got no window at all; SDK-14-stamped
  debug builds were unaffected, and `defaultLaunchBehavior(.presented)` did
  not help. `RelayCommands` hands `openWindow` to `AppDelegate`, which opens the
  picker after launch when SwiftUI did not. Judge picker visuals with an
  SDK-stamped build (`bundle.sh`'s flags): debug builds render older control
  metrics (20 pt popups beside a 24 pt segmented control; all 24 pt on 27.0)
  and a 28 pt title bar instead of 32. Under the 26+ SDK, SwiftUI menus (the
  row context menu and the PC/View commands) show text only, as the system's
  own menus do on 27.0 (Finder keeps icons for just Move to Trash, Share, Tags
  and Quick Actions). Do not force `.labelStyle(.titleAndIcon)`; debug builds
  still draw the symbols, which is not what users see.
- `ClientState` uses a recursive lock around read/modify/write transactions to
  preserve its existing file formats across UI/network concurrency. VerifyTask
  and UnpairTask serialize timeouts and delegate replies on connection.queue.
- **A final STREAM_STOP must be half-closed and drained when client data can be in
  flight.** Closing with unread bytes can draw a Windows RST that discards the stop
  from the receive buffer (probe saw 10053, not the reason). BUSY is now a reply to
  CLIENT_HELLO, but the client becomes input-ready when it sends that hello, so the
  host still `shutdown(Write)`s and drains until close/timeout before returning.
- A session-less host in the same session as the SYSTEM worker cannot be run for
  tests (`Local\Relay.host` mutex): redeploy with `install-host.ps1 -SkipDriver`
  (elevated) and test against the service instead, or stop the service and run
  the `--no-vdd` dev host **elevated** (`identity.key` is Administrators/SYSTEM
  only), then start the service again. Picture options were tested that way on
  2026-10-10 (one UAC prompt for a script that stopped the service, ran the dev
  host on port 18468 until told to stop, then installed).
- **Historical encoding-only 10-bit path (superseded 2026-10-19):** NVENC
  (API 12.1) turned the 8-bit ARGB input into HEVC 4:4:4 and/or 10-bit
  itself: `chromaFormatIDC = 3`, `pixelBitDepthMinus8 = 2` with
  `NV_ENC_BUFFER_FORMAT_ARGB` unchanged. That path needed no shader conversion;
  its 4:4:4 chroma was full resolution (checked against a 2×2-averaged copy). The probe's persisted identity
  is paired with it again since the v4 checks (2026-10-08; the list had been empty since
  2026-09-19); `probe --unpair` removes it.
- **Every stream's VUI is primaries 1, transfer 1, matrix 6, limited range**
  (smpte170m / bt709 / bt709), HEVC and H.264 alike: `signal_colour`,
  unit-tested. A dump tagged bt470bg / iec61966-2-1 came from the ffmpeg
  encoders that phase C removed (2026-10-17), not from NVENC. ffprobe reports
  the SPS as is; `ffmpeg -bsf:v trace_headers` shows the raw fields.
- **v4 records and the receive loop.** Senders fill every record but a message's last
  (65,519 plaintext bytes), so once a message's first record is decrypted its header says
  exactly how many wire bytes remain; `HostConnection.receiveMore` asks for all of them in one
  read (`SecureChannel.remainingWireBytes`), keeping the one-read-per-frame property
  `docs/LATENCY.md` measured. `FrameReader` caps frames at 65,535, so a hostile length never
  allocates more. The pinned-key check sits between msg2 and msg3: a PC with another key never
  sees the Mac's identity.
- Pairing is CPace (a PAKE) inside the Noise channel since v4: someone in the middle gets one
  online guess per attempt, nothing to test offline, and the PC proves the PIN back. The
  host counts every attempt as a failure until PAIR_CONFIRM checks out (`PairLimiter::
  undo_failure`), so a client that leaves after PAIR_REPLY still spent a guess.
  Keys/pairings: `%ProgramData%\Relay`, `~/Library/Application Support/Relay`.
- **snow's default `Dh25519` accepts an all-zero DH result** (plain `mul_clamped`), which
  Relay has always refused (the Mac's Noise.swift too), so the host checks every key a peer
  sends with `Identity::refuse_low_order`. snow's `std` feature turns on `ring/std` (not
  `ring?/std`) and so builds ring; the host uses `default-features = false` with just the
  four `use-*` features its suite needs.

## Conventions

- Rust: `anyhow` errors, `log` macros, no async (one thread per concern), Windows APIs via
  the `windows` 0.58 crate, keep clippy clean. Swift: SwiftUI + AppKit stream/window bridge + Network.framework +
  CryptoKit only, no third-party packages.
- Defaults are 120 Hz and the Mac's native pixel size; `--scale 0.75`/`0.5` are the
  cheaper same-aspect modes.
- Keep the README's status table honest; note anything verified on real hardware.

`CLAUDE.md` only imports this file; edit here.
