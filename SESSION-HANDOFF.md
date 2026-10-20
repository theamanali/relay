# Session handoff (Mac ↔ PC)

The one file for passing work between the Mac session (`client/`) and the PC
session (`host/`, `tools/`). Do not create other handoff or retest files.

## How to use it

- **Before you start:** `git pull`, then read **Open**. Anything addressed to
  your machine is yours to do first, unless the user says otherwise.
- **Handing off:** add an item under Open: who it is for (→ PC / → Mac /
  → user), the date, what is needed and why, the steps, and what counts as
  done. Commit and push it before you stop.
- **Picking up:** work the item and write results into it as you go (dates,
  commits, installed hashes, what passed, what failed, what was not checked).
- **Closing:** once it is done, move the outcome into the README status table
  and the AGENTS.md status bullet, and delete the item here. Git history keeps
  the old text; nothing is archived in this file.
- Protocol changes still go host-first and land in `docs/PROTOCOL.md`; an item
  here only says what to implement or verify, never the wire contract itself.

## Open

### → PC: true 10-bit SDR display and capture when 10-bit color is enabled (2026-10-19)

**User request:** make the existing Mac **10-bit color** setting select a
10-bit Windows virtual display and preserve that precision through capture,
composition and NVENC input. This is SDR work; HDR remains a separate roadmap
item. The user sees **8-bit** in Windows Advanced display during a current
10-bit stream. The implementation and user-process/shared-GPU Windows checks are done
(2026-10-19; implementation `ecb33ee`). Final SYSTEM installation/verification
is pending an accepted Windows administrator prompt; do not mark this item complete.

**Before this implementation (source audit from the Mac handoff)**

- `tools/vdd_settings.template.xml` sets `SDR10bit=false` and
  `HDRPlus=false`. `driver/mtt.rs::render_settings` merges the GPU and modes
  but does not connect color settings to the negotiated session.
- `native_nvenc.rs::create_capture` uses `IDXGIOutput1::DuplicateOutput`;
  `create_texture` makes BGRA8 composition and encoder-slot textures.
  `EncoderSession::configure`, initialization and resource registration use
  `NV_ENC_BUFFER_FORMAT_ARGB`. The existing 10-bit flag changes HEVC's
  output depth, so NVENC currently encodes an 8-bit capture into a 10-bit
  bitstream. A Main10 SPS alone does not establish 10-bit capture.
- The Mac already sends the request, selects hardware VideoToolbox's 10-bit
  output from the SPS, and renders 10-bit buffers to a `bgr10a2Unorm` layer
  (`VideoRenderer.swift`, `VideoCapabilities.swift`, `MetalPresenter.swift`).
  That is client support, not a new real-Mac qualification of this feature.

**Original implementation requirements**

1. **Prove the source path on the actual Windows machine first.** Read the
   installed MTT version and the live XML under the registry's `VDDPATH`;
   the installer pins 25.7.23, and a template is not proof of live settings.
   MTT documents `SDR10bit=true` for 10-bit SDR, mutually exclusive with
   `HDRPlus`. Check the installed version's actual XML schema and behavior.
   Verify Windows' active bit depth/color space and what Desktop Duplication
   actually returns. Do not assume enabling the setting forces every
   acquired frame to use a particular DXGI format. If MTT/Windows cannot
   expose a usable high-precision SDR capture, record the evidence here
   before choosing an alternative; do not substitute HDR without the user
   requesting it.
2. **Carry negotiated depth into display acquisition.** Reuse the existing
   CLIENT_HELLO picture option and `SessionPlan.video.ten_bit`; H.264 and a
   negotiated 8-bit session must keep the 8-bit path. Thread the effective
   depth through `server::acquire_display`, the `VirtualDisplay` trait and
   MTT `attach`/settings merge, including test doubles and diagnostic callers.
   Set the applicable VDD color options before enabling the device. Preserve
   unrelated XML, keep the merge idempotent, and make on → off → on select
   the correct settings each time. Use devnode disable/enable when needed;
   never the MTT control pipe. Define cleanup for temporary color overrides
   and recover them if required by that ownership model. `--no-vdd` must
   inspect the physical display as-is, without changing its color settings.
3. **Negotiate and retain a high-precision capture format.** Use
   `IDXGIOutput5::DuplicateOutput1` with supported formats appropriate to the
   actual SDR desktop, retaining BGRA8 compatibility where the API requires
   it. Inspect the duplication description and acquired texture descriptors;
   select the path from actual format/color-space information. Candidate
   formats include `R10G10B10A2_UNORM` and FP16, but the supported/returned
   format must be established on the installed driver. Allocate composition
   textures and encoder slots accordingly. `CopyResource` is not a format
   conversion: use a GPU conversion when source/destination formats differ.
   If FP16/scRGB is returned, correctly convert its linear values into the
   intended SDR transfer/range before encoding; do not clamp through BGRA8
   or treat scRGB as PQ. Keep conversion and composition on the selected GPU.
4. **Keep cursor composition and NVENC input at the selected precision.**
   Audit `cursor_overlay.rs`, composition targets, slot allocation, all
   resource copies, registration/mapping and picture submission. An 8-bit
   cursor shape is fine; the desktop target must retain its precision.
   Preserve normal, masked and monochrome/XOR cursor behavior. Query and
   trial an actually supported 10-bit NVENC input format, with correct
   DXGI/channel packing (ARGB10 and ABGR10 are not interchangeable), or use
   a supported 10-bit YUV input with GPU conversion. Update `nvenc_caps.rs`,
   `query_caps`, `trial_initialize`/`trial_encoder` and `encoder-caps` so
   preflight exercises the input format the real session uses. Cover both
   HEVC Main10 4:2:0 and Rext 4:4:4 10-bit. NVENC API 12.1 is our floor;
   check its actual bindings instead of copying newer SDK fields.
5. **Make capability reporting, color and recovery honest.** Log requested
   and negotiated depth, active display bit depth/color space, duplication
   format, composition/slot format and NVENC input/output formats separately.
   Gate 10-bit support on the usable high-precision input path as well as
   output-depth/profile support. For a negotiated 10-bit session, an
   unsupported capture path must fail clearly with layout restoration rather
   than silently reuse the current BGRA8-to-Main10 path. Preserve existing
   codec negotiation semantics for H.264/unsupported picture options. Keep
   normal capture recovery for lock/unlock, display changes and GPU restart,
   revalidating the actual format when capture is recreated; a transient
   unavailable desktop is still recoverable. Preserve SDR colorimetry where
   possible; if conversion changes matrix/range, signal the actual values
   in VUI and arrange the matching spec/client verification. Do not label SDR
   as HDR. No new wire field is expected: the existing request and
   STREAM_START bit already describe depth. Any necessary protocol change
   must follow AGENTS.md's host-first/spec/client sequence.

**PC implementation and measured results (2026-10-19)**

- Installed driver: `oem49.inf`, MTT `11.30.4.434`, matching the cached
  `VirtualDisplayDriver-25.7.23-x64.zip` INF. Registry VDDPATH is
  `C:\VirtualDisplayDriver`; live XML uses `<colour>`, while the release's
  shipped XML uses `<options>`. Both contain SDR10bit / HDRPlus; the merge
  preserves their location and unrelated XML. Non-exclusive extended VDD
  trials at 1920×1080@60 (07:22–07:25 UTC) read **10/8/10 bits/channel**, all
  `RGB_FULL_G22_NONE_P709`, for on/off/on. Device disable/enable loads each
  change. Both physical monitors stayed active, and original colour switches
  and layout were restored after success and refusal. This proves the display
  toggle, **not** the final WGC virtual-display source qualification below.
- Those trials found DuplicateOutput1 still returned **BGRA8** for
  RGB10+BGRA8, FP16+BGRA8 and BGRA8-only lists. First attempts also returned
  DXGI_ERROR_UNSUPPORTED during setup; later probes opened but remained
  BGRA8. This evidence was recorded here before selecting an alternative.
  When DuplicateOutput1 is unsupported, classic duplication is used for the
  **cursor only**; neither duplication API supplies 10-bit desktop pixels.
  The high-precision desktop source is therefore **Windows Graphics Capture
  FP16**, with its cursor disabled. DDA supplies pointer position/shape only.
  The same D3D11 device/GPU performs linear-scRGB → sRGB OETF into RGB10,
  cursor composition and same-format copies into NVENC **ABGR10** slots
  (DXGI R10G10B10A2 has R in the low bits). No BGRA8 expansion is used.
- Negotiated `SessionPlan.video.ten_bit` reaches display acquisition and MTT
  attach. Every virtual 10-bit acquisition/recovery checks active depth/SDR
  colour. The original colour tags are journaled to `%ProgramData%\Relay\vdd-colour.xml`
  **before** overriding SDR10bit/HDRPlus, and restored after disable on normal
  cleanup or crash recovery; GPU/mode merges are retained. Failed attach runs
  cleanup. Tests cover both XML schemas, on/off/on and durable recovery.
  Unsupported colour/source formats end and restore; no silent 8-bit desktop
  fallback is permitted. H.264 and unnegotiated/legacy 8-bit use DDA/BGRA8/ARGB.
- `query_caps` and TXT 10-bit support require WGC, FP16 shader-load,
  RGB10 render/blend and NVENC ABGR10 in addition to HEVC output/profile caps.
  Trials initialize **and register/map** the actual input format and create
  the converter for Main10 and Rext. `encoder-caps` passed every P1/P4/P6
  8-bit HEVC/H.264 and both 10-bit chroma variants on the RTX 3080 Ti,
  driver 616.56 / NVENC API 13.1, with real input-resource and converter trials
  at 3024×1964@120; the implementation uses the API 12.1 bindings.
- The numeric source test is `precision.exe`: a native RGB10 flip-model
  SDR window presents four 64-patch ramps (codes **400–463**, step 1) and
  black, white, RGB primary, near-black and near-white controls through DWM.
  It reads actual captured pixel values, converts through the production
  GPU shader, reads the RGB10 composition target, and checks all cursor kinds.
  Tests on the unchanged **2560×1440 physical desktop** (connector still
  reports 8-bit; no display colour/DPI changes) retained **64/64 distinct
  codes in all four ramps**, before and after GPU conversion/composition,
  **maximum error 0**. DDA 8-bit captured/composed only **16/64**, max ramp
  error 2. This is actual desktop capture, not an encoder-only synthetic test;
  the FP16 source can retain a native application's precision independently
  of connector bit depth. Ordinary 8-bit content does not gain precision.
- GPU cursor checks cover colour replacement, masked replacement/inversion,
  monochrome black/white/transparent/inversion on both destination depths.
  They found and fixed an existing masked-cursor defect: replacement pixels
  retained RGB in the XOR pass. XOR now uses integer operations against a
  same-format GPU copy of the original desktop, at 8 or 10 native bits.
- Final release production dumps use actual capture → conversion → cursor → NVENC, 12
  frames, Best, 200 Mbps, 30 fps. `tools/check-precision.py` decodes frame 10
  with ffmpeg to RGB48 at the CSV pixel centres, using the signalled BT.601
  limited-range matrix. 10-bit 4:2:0 / 4:4:4 retain R/G/B/gray ramp counts
  **38/44/32/54** / **38/44/31/54** after lossy encode/decode, versus
  **9/12/9/14** for 8-bit HEVC and H.264. Across ramp + range/primary
  controls, maximum RGB code error is **6 / 5 / 14 / 14**; mean absolute
  error **1.226 / 1.198 / 6.167 / 6.167** (all in 10-bit RGB code units).
  Black decodes to 0; 10-bit white to 1019 (4 codes below 1023), showing the
  small NVENC/lossy conversion bias explicitly. Both 10-bit formats decode
  as yuv420p10le / yuv444p10le, with unchanged `tv / smpte170m / bt709 / bt709`
  range/matrix/transfer/primaries. No HDR tags or channel swap.
- WGC is recreated with capture on desktop changes, DXGI loss, monitor closure
  and size changes; acquired FP16 descriptors are checked on each conversion.
  The SYSTEM worker cannot activate the per-user CaptureService itself
  (`0x80070424`); thread impersonation also failed. It therefore launches the
  same `relay-host.exe capture-source` as the signed-in user. This helper
  captures FP16 and converts directly into an NT-shared RGB10 texture. The
  SYSTEM host authenticates the local pipe client PID before duplicating
  only that texture handle into the child; remote pipe clients are rejected.
  A keyed mutex transfers GPU ownership without CPU pixel copies or blocking
  waits. SYSTEM keeps cursor composition, NVENC, input, topology and keys.
  Helper exit/desktop change enters normal capture recovery; teardown kills
  the child. User-process sessions use WGC directly. Objects close on their
  capture thread before its WinRT apartment ends.
  A repeated query/input-trial hardware regression protects the process-wide
  MTA lifetime (one process-lifetime CoIncrementMTAUsage pin, balanced
  per-thread RoInitialize/RoUninitialize): a startup crash in the first candidate was caught by the safe
  no-VDD deployment gate, before installation, and fixed before proceeding.
- Timing deliberately preserves the existing wire contract: WGC's
  SystemRelativeTime drives cadence only; `present_us` is **unknown** on this
  source because it is not DWM LastPresentTime. Desktop → screen / content-age
  HUD rows stay blank for true 10-bit. Encode/work, receive → screen, transfer,
  clock sync and input timing remain available. No wire or client change.
- Windows fmt, **237 unit tests** (desktop/hardware tests opt-in), **2 probe
  tests**, the probe pairing integration test, strict all-target clippy and
  release build pass on Rust **1.98.1**. The read-only NVENC/WinRT lifetime
  regression is also run separately. The user-owned exclusive qualification
  suite has not been run. One unintended exclusive **8-bit** session occurred
  at 08:06:35–08:06:39 UTC: a temporary service environment no-VDD flag was lost
  by CreateEnvironmentBlock before worker launch. Logs confirm both physical
  monitor devices restored at 08:06:38.266 and layout at 08:06:39.088. This
  violated the test boundary and was reported to the user. Service mode now
  forwards `--no-vdd` explicitly from service CLI to worker CLI. The guarded
  test requires the newest worker's explicit no-VDD log before any probe.
  This unintended session does not qualify 10-bit exclusive behavior.
- Earlier candidate installed with `tools/install-host.ps1 -SkipDriver`,
  **2026-10-19 07:58:53 UTC** (superseded; final SYSTEM verification pending). Release and `%ProgramFiles%\Relay\relay-host.exe` SHA-256:
  **`F5164D7BF0937E327F819D78511E465A25648D6EDD37D0E5199EC8A6A98CC225`**.
  That candidate ran with 10-bit withheld under SYSTEM, so it was not a
  completed service implementation. Service **Running**, installed-service `probe --pair-only` passed (v4,
  already paired, capabilities `0x0f`); sorted pairing keys/names unchanged.
  The initial candidate was never installed. A byte-order guard in the safe
  test script also stopped before deployment because normal session naming
  re-saves the unordered peer map; the final installer check compares entries.
- Safe release `--no-vdd --no-input` host + persisted, already-paired probe,
  2560×1440@144 physical primary, three-second sessions, all exit 0:
  legacy hello/no picture extension → HEVC `0x01`; 10-bit 4:2:0 → `0x09`;
  10-bit 4:4:4 → `0x0d`; H.264 with both colour flags requested → `0x01`
  (flags logged as not applied). Counts including startup: **361 / 343 /
  331 / 359 frames**; PC work p50/p95 **2.96/3.12 / 2.94/3.26 /
  4.63/4.85 / 3.20/3.95 ms** respectively. These short static-desktop checks
  prove protocol compatibility, not sustained 3024×1964@120 performance.
  Both 10-bit timing sessions replied to all 7 clock requests and sent
  unknown present stamps on every frame as intended. The probe now labels
  these as **DWM present unknown**, rather than incorrectly calling all WGC
  frames reused. No pairing/UNPAIR or display-mode/colour/DPI change was sent.
- Local evidence is under ignored `host/target/precision-evidence/`: final
  `release-physical-*` CSV/HEVC/text/decoded JSON, `probe-*`, `dev-host-error.txt`,
  `final-caps*`, `install-final*` and `installed-pair-only*`. The numeric method
  and results above are durable; these local diagnostic dumps are not committed.

**Current deployment / outstanding PC step**

The helper-backed release (`ecb33ee`) is built but **has not been installed or
verified as SYSTEM**. Its SHA-256 is
`2A36B9CD1AAD29055832DBEF29B8042801968A7645BDA6CC26A1B2466C96F9AA`.
On resuming after the usage limit, fmt, all 237 unit + 2 probe + integration
tests, the separate NVENC/WinRT lifetime regression, strict clippy and release
build passed again. The sandboxed attempt could not open loopback sockets or
rename a temporary journal; the unrestricted rerun passed all checks.
The user authorized reopening elevation, but Windows again returned
"operation was canceled by the user" (2026-10-19 Pacific / 2026-10-20 UTC).
The guarded script never started; no service command or display changed in
that retry. The installed
intermediate candidate is SHA-256
`ABD08DCC1DCD5073206A5AA58DFE38015BC0B76AE8AD1EA1295662B011B3B20D`;
its SYSTEM WGC activation still fails and it honestly advertises `enc=q,444`
with 10-bit withheld. It is not the final feature build. The earlier `F516…`
hash above is historical, not the current or proposed final binary.

While elevation was pending, `RELAY_TEST_FAULT=capture-broker relay-host
capture-probe --dump ...` tested the exact helper/pipe/shared-texture path as
an ordinary user: **64/64 codes**, max error **0**, before/after cursor, both
helpers retired on teardown. Its real production Main10 dump retained
**37/44/31/54** R/G/B/gray ramp codes after decode, max error **5**, mean
absolute error **1.207**, correct SDR VUI/range/channels. This is a shared-GPU
process test, **not** a SYSTEM pass. The final **release** binary's same
diagnostic was also run after resuming: source/composition **64/64**, maximum
error **0**; decoded ramp counts **35/43/31/54**, max error **5**, mean absolute
error **1.218**, correct SDR VUI/range/channels. Evidence:
`release-broker-user.*`. New regression covers positive-HRESULT keyed-mutex
timeout versus actual ownership.

The reviewable local script `host/target/system-guarded.ps1` installs the new
release, temporarily uses the exact SCM binary command
`"C:\Program Files\Relay\relay-host.exe" --no-vdd service run`, and checks
that the latest SYSTEM worker logs no-VDD **before** any probe. It holds a
native ramp on the unchanged primary, captures 10-bit 4:2:0 and 4:4:4 dumps,
then restores the original SCM command and normal service in finally. Resume
after the local Windows elevation is accepted (the user already authorized
reopening it; check the pending prompt-visibility reply before retrying). Decode the
`system-420/444` dumps against their copied scene CSV, confirm `enc=q,444,10`
on the restored normal worker, recheck hashes/pairings/no orphan helper, then
replace this pending paragraph with final results and installed SHA-256.

True 10-bit WGC requires a signed-in user's **Default** desktop. There is no
BGRA8 fallback for login/secure screens; 8-bit retains the existing SYSTEM DDA
path. The 10-bit path waits as a recoverable unavailable desktop and can resume
when Default returns. Before-login use should select 8-bit. Secure-desktop,
sign-out/user-switch recovery and performance still need user qualification.

**Still pending — user / Mac / PC follow-up (keep this item open)**

1. User: run exclusive on/off/on sessions at 3024×1964@120, both 4:2:0 and
   4:4:4 10-bit. Confirm Windows active 10/8/10 depth and SDR, and host logs
   showing WGC FP16 desktop, RGB10 composition/slots and ABGR10 input only
   for negotiated 10-bit. Confirm the actual virtual-display native ramp
   through `precision --display \\.\DISPLAYn --dump ...` while the VDD is
   active; the **final WGC virtual-display pixel precision is still pending**.
   Alternatively, elevated with the service stopped, `precision --virtual-display`
   extends rather than blacks out the physical outputs. A Windows label or
   Main10 SPS alone is insufficient. A later elevation prompt for this final
   source probe was cancelled; it has not been silently retried.
2. User: cursor (normal/masked/monochrome), quick reconnect, lock/unlock,
   login-screen connect, capture/GPU restart, disconnect and failure restore
   with the SYSTEM worker. Check physical monitor colour settings, positions,
   primary, DPI and refresh rates return as before, and that the colour journal
   is removed only after restoration. The WGC secure-desktop path is **unqualified**;
   older DDA lock/recovery passes do not qualify this source.
3. Mac: rebuild current client, verify real VideoToolbox 10-bit output buffers,
   normal colours/gradients and no double cursor. At 3024×1964@120 Fastest,
   compare fps, PC work, receive → screen and input latency for both chroma
   modes against 8-bit. All earlier “10-bit free” measurements used the old
   8-bit source and must not be treated as a result for WGC/FP16 capture.
4. PC + Mac: qualify a content-present timestamp for WGC before restoring its
   Desktop → screen/content-age rows. Do not substitute SystemRelativeTime
   for LastPresentTime without checking semantics; any contract change follows
   host/spec/client rollout. This does not block pixel precision, but the new
   path's full desktop-to-screen latency remains unmeasured.

**Verification and acceptance**

- Add focused regressions for session depth propagation, idempotent VDD XML
  changes and on/off transitions, texture/NVENC format selection and packing,
  capability refusal, and failure cleanup. Run Windows fmt, unit/probe tests,
  strict all-target clippy and a release build. Keep the 8-bit HEVC and H.264
  paths working, including older clients without picture options.
- First use `--no-vdd` for safe pipeline tests on a suitable existing display;
  this may demonstrate correct refusal if that display is only 8-bit. Any
  synthetic encoder-only test must be identified as such, not called a
  virtual-display capture pass. Coordinate service stop/start as in AGENTS.md.
- Prove precision with a controlled **native high-precision SDR** test image
  or ramp containing differences below one 8-bit step. Inspect numeric values
  after actual desktop capture and after composition/conversion to show the
  distinctions survived; an expanded 8-bit ramp also has nonzero low bits,
  so texture format or low-bit occupancy alone is insufficient. Check an
  encoded/decoded dump at adequate quality against the 8-bit baseline, with
  channel, range and color checks. Account for lossy quantization; do not
  require bit-exact reproduction of every 10-bit code. Record the diagnostic
  method and results here without creating another handoff/retest file.
- The user runs exclusive virtual-display sessions because they black out
  the PC's physical monitors. Check 10-bit on/off/on, Windows reporting the
  intended active depth, capture/encoder logs, 4:2:0 and 4:4:4 10-bit, cursor,
  quick reconnect, lock/unlock, capture/GPU restart and disconnect/failure
  restore. Physical monitors, their color settings, layout, DPI and refresh
  rates must return as before. A Windows 10-bit display label is necessary
  evidence, not a substitute for the capture precision check above.
- Install the verified host using the existing installer and record the
  installed/release hashes. Hand back real-Mac A/B at 3024×1964@120, Fastest,
  both chroma modes: actual 10-bit decoder buffers, correct colors/gradients,
  fps, PC work and end-to-end latency against the existing 8-bit-source
  baseline. Earlier results saying 10-bit was free measured the old capture
  path and do not qualify this implementation. Keep unrun checks explicitly
  pending in this item.

Done when source precision, Windows display behavior, compatibility, restore
and performance are supported by recorded evidence. Update README status and
the AGENTS.md 10-bit notes to distinguish old encoding-only support from the
new capture path; remove this item only after all required outcomes are
recorded there. Keep any remaining Mac/user checks open here. Commit small
and push on `main`; no implementation change is part of this Mac handoff.

References: [Microsoft WGC capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture),
[Microsoft DirectX Advanced Color](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range),
[MTT's SDR10bit option](https://github.com/VirtualDrivers/Virtual-Display-Driver/wiki/How-to-configure-the-driver#options-section),
[Microsoft's DuplicateOutput1 formats and behavior](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_5/nf-dxgi1_5-idxgioutput5-duplicateoutput1).

### → user, on the PC: display scale on the real virtual display (2026-10-18)

The Mac sends the scale since 2026-10-18 (rebuild/`./bundle.sh` from
`main` first): the requested pixel width over the Mac screen's width in
points, never under 100. These black out the PC's monitors.

1. Note `Get-ItemProperty 'HKCU:\Control Panel\Desktop\PerMonitorSettings\*'`
   (the virtual monitor's `MTT1337…` entry was `DpiValue=2` on 2026-10-18;
   the physical monitors have none).
2. Connect from the Mac at 3024×1964@120. The Windows desktop should look like
   the Mac's own "looks like 1512 × 982": 200%. host.log: `display scale of
   \\.\DISPLAYn set to …` (or `already … as asked`), with what Windows
   recommends and allows.
3. While streaming, sign out and back in from the Mac (the SYSTEM worker set
   the value; the open question is whether a sign-in keeps it or reloads the
   user's own). Also lock/unlock once.
4. Disconnect. host.log: `display scale of … restored` before `display layout
   restored`. Both physical monitors back at 100%, same layout and refresh
   rates. Repeat step 1: note which hive changed (the user's `HKCU` or
   `HKEY_USERS\S-1-5-18`).
5. Connect at `--scale 0.75` (expect 150%) once.

Agents read host.log afterwards. Done when recorded; then tick the README
checklist item and update the AGENTS.md "Display scale" bullet.

### → user, on the PC: Windows service retests (from 2026-10-09)

Reboot-before-login, sign-out/reconnect and lock/unlock each passed once on
2026-10-09. Still needed: repeats, proof that setup works **before any
Windows user session exists** (in the one pass, a `SessionLogon` preceded the
post-reboot connection), and a crash of the **service process** itself. A
killed *worker* already restored correctly (U6, 2026-10-17). These black out
the PC's monitors, so the user runs them; agents read the logs afterwards.

**Setup**

1. Elevated, at the repo root: `.\tools\install-host.ps1 -SkipDriver`. Confirm
   **Start on system boot** is on and auto-login is off.
2. Copy `%ProgramData%\Relay\host.log` aside. Note the start time and the
   time of every step below.
3. Signed in locally, connect at 3024×1964@120, disconnect, and check that
   both physical monitors, the primary, positions and refresh rates return.

**Reboot before login (3 times)**

1. Reboot. Do not sign in at the PC or restart Relay by hand.
2. Connect from the Mac as soon as the PC appears; note the delay after the
   reboot. The login screen should show and take input.
3. Disconnect at the login screen; the physical monitors should show it.
4. Reconnect, sign in from the Mac; streaming should survive sign-in at the
   same mode. Disconnect, check the layout, reconnect without a PIN.
5. If a connect fails: stay signed out, retry after 15 s and after 60 s, note
   each result, only then sign in locally and retry. Save host.log.

**Sign out while streaming (3 times)**

1. Stream at 3024×1964@120, sign out of Windows from the Mac.
2. Back at the picker, reconnect as soon as the PC appears; note the delay.
   Login-screen video and input should work.
3. Disconnect while signed out and check the monitors. Reconnect, sign in
   from the Mac, disconnect, check the layout. Same 15/60 s retries on failure.

**Lock regression (once):** lock and unlock while streaming; disconnect while
locked, connect to the locked PC, unlock from the Mac, disconnect, check the
layout.

**Service process crash (new):** while streaming, elevated:
`Stop-Process -Id (Get-CimInstance Win32_Service -Filter "Name='Relay'").ProcessId -Force`.
Record whether the service manager restarts the service, whether the monitors
and layout return, and whether the Mac reconnects. The expected behaviour is
not specified anywhere yet; dark monitors are a finding, not a mistake.

**Reading host.log**

- Before-any-session proof: for each reboot run, the connection's topology
  lines must come **before** any `SessionLogon` line.
- Good topology operations log matching nonzero `session`/`console`,
  `station=WinSta0` and a `bound` desktop equal to the input desktop
  (`Winlogon` at login/lock, `Default` after sign-in).
- `OpenInputDesktop`/`SetThreadDesktop` failures, mismatched sessions or
  SetDisplayConfig error 5 mean context/access. An old worker rejected after
  the console changes is expected; the new worker must retry the saved restore.
- Zero active paths or changing query sizes mean readiness/churn. A missing
  virtual monitor or a mode mismatch after a good binding points at driver or
  topology state: keep the exact error and the path/mode counts before it.
- Error 87 with flags `0x24a0` means the old binary is still running. A
  successful restore clears the snapshot; a failed one must keep it.

Done when every run above has a recorded result and the logs have been read;
then update the README checklist item and the AGENTS.md "Topology context"
and Milestone 4 notes.

### → user: pair-only name survives a service restart (from 2026-10-10)

The Mac's name already shows in the PC's tray Forget menu right after
Pair-only. Check that it is still there after a restart:

1. On the Mac, Forget the PC, then Pair (enter the PIN) and stop; do not
   Connect.
2. PC tray ▸ Forget paired MacBook: the Mac's name is listed.
3. Elevated: `Restart-Service Relay`. Open the submenu again: the name is still
   there.

Done when reported; then tick the README checklist item and update the
"Pair-only name fix" bullet in AGENTS.md.
