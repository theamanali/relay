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
10-bit stream. This handoff was prepared on the Mac; implementation and
Windows verification have not been done.

**Current behavior, confirmed in source**

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

**Implementation, in order**

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

References: [MTT's SDR10bit option](https://github.com/VirtualDrivers/Virtual-Display-Driver/wiki/How-to-configure-the-driver#options-section),
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
