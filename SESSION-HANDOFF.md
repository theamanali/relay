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

### → user / Mac: verify fixed SDR timing HUD on installed host (2026-10-19)

The user reports no image age / encode & send detail and "clock not synced"
in 10-bit sessions. **Update:** the host now supplies valid WGC source stamps
through the same `present_us` contract as 8-bit, per the user's instruction
to keep identical Mac metrics/labels. No Mac runtime change or rebuild is
required to consume them. Installed SYSTEM checks and the bounded future-
timestamp case are recorded under "Unified 10-bit timing" below. This Mac
follow-up still covers frames genuinely lacking source timing.

PC source audit: `StatsHUD.Presentation.init` uses
`desktopToScreen.p50 != nil` to decide both whether end-to-end data exists
and whether the clock is synced. A WGC frame deliberately has unknown
`present_us` on repeated/invalid-source pictures; this makes the message
misleading even with a valid clock.
`clockOffsetMs` / `clockDelayMs` already distinguish actual sync. The
`contentAge.p50.map` also hides the numerical encode/send detail whenever
source presentation time is absent. Host FRAME_TIMING_EXT still supplies
capture/encode/send, submit and sent stamps; HostConnection forwards basic
timings before examining the present stamp. Guarded PC probes kept 7/7 clock
replies and received valid work / submit→sent metrics with unknown present.
That establishes host/protocol availability, not this Mac's measured sync.

Mac-owned follow-up (PC updated only the two source-timestamp comments in
`client/`; no Swift logic/UI change):

1. In `StatsHUD.swift`, use actual clock state for "clock not synced".
   With a valid clock but no source presentation time, explain that source
   timing is unavailable and show receive → screen. Never manufacture image
   age / desktop → screen from receive time. Keep the existing user-facing
   labels for both 8-bit and 10-bit, as explicitly requested by the user.
2. Show PC work independently of content age. For the separate **encode &
   send** duration, derive `sentMicros - submitMicros` in `FrameEndToEnd`
   whenever both stamps are known and ordered: it uses one host clock and
   needs neither clock sync nor `presentMicros`. Record/expose it in
   `LatencyStats` and the HUD even while image age is unknown. Keep it distinct
   from basic capture+encode+send work; do not silently rename their sum.
3. Tests: synced + unknown present; genuinely unsynced; valid encode/send with
   unknown present and no sync; broken/unknown stamps; ordinary 8-bit DWM
   timing; source transitions without stale image-age/end-to-end values. Run
   Swift tests, fakehost checks and a bundled real 10-bit PC session.

Real-Mac image-age / Desktop → screen confirmation remains below. The
generalized source-timestamp definition is in PROTOCOL.md and both sides'
comments: DDA LastPresentTime or WGC compositor SystemRelativeTime, with the
same host QPC base and existing 68-byte message. No separate WGC UI label.

**Mac implementation / local evidence (2026-10-19 Pacific)**

`1181e72` fixes the Mac HUD/state separation and adds independent submit →
sent to `FrameEndToEnd`, rolling/session histograms, report Details/Markdown
and HUD detail. PC work still sums basic capture/encode/send. A healthy clock
with an empty source window falls back to receive → screen with “source timing
idle”; no time is manufactured, no expired percentile is retained, and the
clock is not reset by static content. Unknown, zero, oversized, reversed and
future source/cross-clock stamps are rejected independently of valid host-local
encode/send. Negative screen samples cannot enter sparklines/timelines.
Both depths/chroma modes use identical timing logic and labels.

Baseline: `swift test` on `dc31425`: **198 passed**. Local updated suite:
`cd client; swift test` — **206 passed**, including static >5 s, moving/static,
missing/invalid sync, host-local timing without source/sync, future/reversed
stamps, old 8-bit timing and recovery. `swift build`, `./bundle.sh` (arm64
release, ad-hoc strict signature verification) pass. `./Tools/test-pair-name.sh`
— **23 PASS** with isolated temporary identities: new 18 s source cycle has
initial static 6 s, moving 2 s, capture gap 2 s, recovered moving 2 s and
final static 6 s. **21 accepted clock replies**, including during the gap;
**949 received frames**, two codec configs, fresh source resumes on the same
connection, encode/send remains available during static content. These are
synthetic source/recovery transitions, not an actual Windows desktop switch.

`DecodedPrecisionTests` uses versioned lossless 256×128 SDR fixtures generated
by `python3 client/Tools/generate-precision-fixtures.py` (ffmpeg/libx265/libx264).
The actual hardware-only VideoRenderer decodes them; tests compare numeric
CVPixelBuffer luma to the controlled source, then use production texture views,
shader/range/matrix and packed native render-target readback. On **M3 Pro,
macOS 27.0 (26A428)**:

| Stream | Actual buffer | Source codes → decoded codes | Native gray levels | Max RGB code error |
|---|---|---|---|---|
| HEVC 8-bit 4:2:0 | 420v | 17 → 17 | 17 | 0 |
| HEVC 8-bit 4:4:4 | 444v | 17 → 17 | 17 | 0 |
| HEVC 10-bit 4:2:0 | x420 | 64 → 64 | 64 | 0 |
| HEVC 10-bit 4:4:4 | x444 | 64 → 64 | 64 | 0 |
| H.264 8-bit 4:2:0 | 420v | 17 → 17 | 17 | 0 |

The 10-bit source has **consecutive** codes 400–463, finer than expanded 8-bit;
controls are limited-range black/white and BT.601 RGB patches matching host
matrix=6. All controls pass. The 10-bit planes use r16Unorm/rg16Unorm,
float shader math and bgr10a2Unorm; 8-bit uses r8Unorm/rg8Unorm/bgra8Unorm.
HUD BGRA8 is blended only in its quad, not an intermediate video surface.
**This is decoder/shader/render-target proof, not PC capture precision or
WindowServer/panel precision.** Actual exclusive VDD ramp, cursor shapes and
secure/Default recovery remain pending user/PC evidence below.

Real-PC measurement preparation: Chrome/other known video apps are closed
(CUA inventory); Mac on AC, lowpowermode=0. Start executable with
`RELAY_TIMING_LOG=1 ./Relay.app/Contents/MacOS/Relay > /tmp/relay-real-mac.log 2>&1`.
One-second diagnostics expose five-second p50/p95 windows **and counts**, sync
and reply count, without extra frame reads/copies. Decoder generations log
actual pixel buffers. User controls every exclusive connect/disconnect.
Target fixed at 3024×1964@120, Fastest, **120 Mbps**, VSync off, Ethernet,
automatic display scale 200%; each comparison has static/moving/static phases.
Installed host hash supplied by the user:
`09E95E2D9F4B97EC3479F6BCF1D51B8A145E3095EF1B86E13D8BBF22F1E3E276`
(`792bca7`, documented by `dc31425`); not independently hashed from this Mac.
The precision audit follow-up `f91377a` rejects a render target of the wrong
depth: a frame can change while `nextDrawable()` waits, so a new 10-bit image
must never be drawn into a drawable obtained for an old 8-bit stream. That
one mismatched frame is dropped; subsequent frames use the selected format.
A focused regression tries the 8-bit target with both true 10-bit fixtures and
requires refusal. Actual drawable/luma/chroma formats are logged per generation.
The final **206 tests**, `swift build`, bundle/signature verification all pass.

Initial user-run HEVC 8-bit 4:2:0 session, **20:55:59–20:58:13 Pacific**:
release app version **312**, binary SHA-256
`2b29fa2ad1732a9077afcc06764caf72a07a41e3391e61e3ca6599ec78743973`
(`1181e72` runtime changes, built before committing); actual **420v** decoded
buffer and BGRA8 renderer. User confirms Relay remained foreground and no Mac
video apps reopened. Measured after warm-up, **2:12**, **71.4 fps** shown,
**41.3% skipped**; p50/p95 in ms: source age **1.3/8.2**, PC work **5.9/6.6**,
encode/send **5.8/6.4**, receive → decode **2.8/3.3**, receive → screen
**12.2/32.0**, Desktop → screen **20.0/43.7**. Clock stayed healthy (best delay
**0.492 ms**). Toward the end a five-second window recovered to **117.1 fps**,
receive → screen **4.0/7.2 ms** without a code/settings change. The cause of
this variable Mac presentation slowdown is **unresolved**; do not silently
exclude it or call the run a clean performance baseline. Exact static/moving
phase boundaries were not tagged, so these are whole-session measurements.
Colors/cursor observations were not supplied by the user's “done” reply.

Mac-only presentation control, **20:59:46–21:00:09 Pacific**, final runtime
against loopback fakehost: `fakehost 18469 accept --clip full.hevc --size
3024x1964 --fps 120`, native-size testsrc2 HEVC generated with ffmpeg/libx265,
then isolated `CFFIXED_USER_HOME` client `--host 127.0.0.1:18469 --pin 000000
--no-input`, timing logging enabled. Stable windows reached **120 fps** with
receive → screen **3.7/4.0 ms**; whole measured **20 s**, **107.3 fps**,
receive → screen **3.8/18.8 ms**, receive → decode **2.5/2.7 ms**. Some late
presentation stalls also occurred here; this is not proof they are resolved
or that the Windows path caused the initial slowdown. Isolated state and the
fakehost process were retired. No Windows connection was made by that test.

Final user-test app version **313**, runtime `1181e72` + `f91377a`, binary
SHA-256 `0dfadb0597578a0d456b9574fc4c78d416cb6f7cf9232c0d57eb66564d28e9fc`.
Opened the normal picker with `RELAY_TIMING_LOG=1`, log
`/tmp/relay-real-mac-final.log`; the user was asked to repeat the same baseline
before the remaining modes. Evidence logs are copied under ignored
`client/.build/qualification-20261019/`. Further results and remaining user/PC
checks follow here; none of the remaining exclusive checks is marked passed.

Repeat 8-bit 4:2:0, **21:02:09–21:03:45 Pacific**, final version 313:
**1:33 measured**, **113.0 fps** shown, **6.8% skipped**; p50/p95 ms:
source age **0.9/8.2**, PC work **5.9/6.9**, encode/send **5.8/6.9**,
receive → decode **2.6/3.1**, receive → screen **3.9/10.8**, Desktop → screen
**12.5/26.0**. Best sync delay **0.527 ms**, accepted replies continue to
**92**. Actual **420v → r8Unorm/rg8Unorm → bgra8Unorm drawable** logged.
Presentation varies despite decode staying at 120 fps; the last window shows
**120.0 fps**, receive → screen **3.5/4.2 ms**. The user reports colors,
black/white levels and cursor looked correct with no duplicate/trails. This
is visual feedback, not an end-to-end native-ramp or exhaustive cursor-shape
qualification. No 8-bit 4:4:4 session had started by the time local validation
finished. The next picker was prepared with Full color on, 10-bit off; **the
user must click Connect**, since an agent must not start an exclusive VDD
session. Keep the other three HEVC modes, real-PC H.264, native VDD precision,
all secure/Default transitions, cursor-shape checks and comparable phase
measurements **pending** until actual results are recorded.

A final sparse-source correction timestamps the Desktop → screen sparkline
points and expires them with the same per-second window as percentiles.
After >5 s idle, old points cannot reappear when one fresh picture returns;
the focused source-timing suite and complete 206-test suite pass. This does
not alter clock sync, presentation scheduling or the measured latency values.
Version 313 above was used for both final-build runtime controls; the next
bundle adds this graph-history expiry only.

Follow-up (2026-10-19): The user reported that the transition to "source timing idle"
felt jarring during brief pauses, the sparkline appeared stuck when static, and "source
timing idle" engaged even while playing active games like Valorant.
Client updates:
1. Extended `windowSeconds` from 5 to 10 seconds across all rolling latency windows.
2. Carried the last real Desktop → screen value forward in the sparkline during
   static re-encodes. Review on 2026-10-20 found that `recordPresented` also
   appended a carry for fresh frames: the actual callback order produced 239
   points for 120 displayed frames. The correction joins each frame's timing
   result (including a missing source stamp) with its presentation by sequence.
   A completed join appends either the real measurement or one carried graph
   point, in either callback order. Carrying never enters histograms/report
   measurements or extends the real sample's ten-second grace window.
3. Upon grace-window expiration, cleared stale sparkline points so they do not
   reappear when motion returns.

Correction verification (2026-10-20): **208 Swift tests pass**. New regressions
check 120 real frames → 120 graph points with exact values in both callback
orders, delayed missing-source timing, replaced frames, motion returning
within grace, and graph-only carries staying out of report histograms.
The moving/static/recovery test now exercises both actual presentation calls
and still checks expiration/resume. Isolated `test-pair-name.sh` passes,
including the 18-second source/recovery cycle with 21 clock replies and 949
received frames. Release bundle/signature verification pass. Real-PC gaming
traces and the existing exclusive qualification remain pending; this Mac
correction changes no host runtime, protocol or timestamp validation.

The Valorant cause remains unverified. The earlier host diagnostic established
that WGC can supply a timestamp later than CPU submission on this stack, but
did not establish why gaming loses source timing or quantify its rejection
rate. The earlier prescribed tolerance/clamping fix is withdrawn; investigate
on the PC as described below.

### → PC: investigate missing WGC source timing during gaming (2026-10-20)

**What is needed and why:**
During fast-paced 3D gaming (e.g. Valorant), the Mac HUD frequently switches to
"Receive → screen, source timing idle" even though the game is rendering actively at
high frame rates (60–120+ fps) and video is streaming smoothly.

**Current Mac behavior / reproduction baseline (updated 2026-10-20):**

- The message means clock sync is accepted but the roughly ten-second
  rolling window contains no valid **joined Desktop → screen samples**.
  It does not establish that the clock, game or capture is idle. A frame
  must have valid source timing and actually reach presentation for that
  sample to exist; investigate missing/rejected timing and frame association,
  rather than assuming a source API failure from the caption alone.
- The Mac rejects unknown/zero/out-of-range source stamps, source after
  submit, reversed submit/send, source mapped after Mac receipt, and
  presentation before source. Encode/send and clock exchanges are separate
  measurements and can remain healthy. Check which side first loses usable
  timing instead of treating every empty Mac window as a host future stamp.
- Current Mac runtime: `acf6724` removes **Extra frames**; a selected 120 Hz
  again requests a 120 Hz VDD/120 fps target. Use this matched-rate baseline,
  not the withdrawn 144-on-120 experiment. The HUD's FPS **text** is capped
  at 120; use raw timing-log, report and host/probe counts to judge throughput.
  The cap changes neither pacing nor source-timing validation.
- The caption “source timing idle” remains in the current app. “Source timing
  unavailable” would be clearer during games, but a wording-only change
  does not solve the measurement loss. Any Mac wording/runtime follow-up
  belongs in this file for the Mac session; PC owns `host/` + `tools/`.

Microsoft documents `SystemRelativeTime` as the QPC time at which the
compositor rendered the frame, not as a target VSync timestamp
([API documentation](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframe.systemrelativetime)).
The earlier 1,557 µs lead is an observation, not evidence of target-VSync
semantics. `frame_present_us` deliberately rejects stamps after `submit_us`;
whether this explains the game's missing samples, and at what rate, is unknown.
Missing/reused source frames, timestamp conversion, helper metadata and
capture/presentation modes also need to be distinguished with actual traces.

**Steps for the PC session:**
1. Identify the running service/worker build and installed/release hashes,
   actual session mode, capture source and helper use before diagnosing it.
   Preserve service/display restoration and the existing 8-bit/H.264 paths.
   Add bounded/opt-in diagnostics around the production WGC/helper → NVENC
   timing path. For the same picture record raw WGC 100 ns time, converted
   host QPC µs, helper sequence where applicable, CPU submit/send time and
   the reason a source stamp is unavailable. Record QPC frequency and frame
   sequence/association through encode and wire output. Keep acquisition
   time separate as diagnostic context, never as a substitute source time.
   Aggregate counters at a bounded rate; any detailed sample buffer must be
   bounded/opt-in and must not block video or extend GPU-slot ownership.
2. During user-run Valorant sessions and matched desktop controls, record
   stream depth/chroma, actual capture path, windowed/fullscreen mode, fps
   and timestamps of static/moving phases. Count fresh/known, reused/missing,
   future, invalid/backwards and helper-rejected stamps. For future stamps,
   report lead distribution/max and sample count; correlate the same phases
   with Mac timing logs and its ten-second source window.
   Compare static desktop, continuously moving desktop and active gameplay
   at the same resolution/120 Hz, preset, bitrate and chroma; compare 8-bit
   DDA with true 10-bit WGC, recording the actual path in each run. Record
   game display mode rather than assuming exclusive fullscreen behavior.
   First localize loss: no fresh capture timestamp → helper/host rejected →
   wire UNKNOWN → client validation/presentation join. If the host emits
   ordered known stamps through an affected interval, save the correlated
   frame data and hand off the Mac validation/join investigation instead of
   loosening host checks. The Mac can log with `RELAY_TIMING_LOG=1`; its
   `Timing window:` lines include sync/reply state, raw fps and stage counts.
3. Verify clock-unit conversion and per-picture timestamp association before
   choosing a fix. Start with non-exclusive `--no-vdd` checks; the user runs
   exclusive VDD sessions. Keep unknown timing unknown, retain
   `present_us ≤ submit_us ≤ sent_us`, and preserve current host/client
   validation. Do not introduce a 20 ms allowance, zero-age clamp or
   acquisition-time fallback based on the current evidence.
4. Record traces/results and an evidence-backed next step here. If a code
   correction is justified, run Windows fmt, tests, strict clippy and release
   build, plus appropriate probe checks. Install only a verified correction
   using the existing installer, record hashes, and hand off any required
   Mac follow-up. Any justified protocol change still goes host → spec →
   client; this investigation does not pre-author a new timing contract.

**What counts as done:**
Reproducible traces explain which path loses source timing during active
gaming, with measured rejection counts/reasons and comparison controls.
For an implemented correction, verify valid ordered samples reach the Mac
and refresh Desktop → screen during continuous gameplay, while true static
re-encodes and invalid source times still remain unknown. Confirm clock and
encode/send telemetry continue through missing-source intervals. Record
unchanged/unrun paths explicitly and keep real-game qualification pending
until actual correlated results exist.
Record the validated correction or remaining blocker here; do not call
invented source times or merely suppressing “source timing idle” a pass.

### → user / Mac: qualify true 10-bit SDR (host implemented and installed 2026-10-19)

**User request:** make the existing Mac **10-bit color** setting select a
10-bit Windows virtual display and preserve that precision through capture,
composition and NVENC input. This is SDR work; HDR remains a separate roadmap
item. The user sees **8-bit** in Windows Advanced display during a current
10-bit stream. The implementation, Windows tests and non-exclusive SYSTEM
installation/precision checks are done (2026-10-19; implementation `ecb33ee`).
The installed follow-up `c060d0f` implements the requested temporary 8-bit
lock/login source and automatic promotion to true 10-bit after sign-in.
Keep this item open for the virtual-display, exclusive/recovery and real-Mac
qualification below.

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

**User amendment after the first deployment (2026-10-19):** when 10-bit is
selected, show the lock/login screen using an 8-bit source, then recreate
capture at true 10-bit after sign-in. This authorizes the Winlogon-only
8-bit-source exception to the original no-downgrade rule below. The display
and encoded Main10/Rext stream stay at the selected 10-bit depth; only input
precision changes, so no protocol/client change or display cycle is needed.
Default still requires true 10-bit capture. H.264 and sessions with 10-bit
off do not opt into this policy.

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

The initial method below excluded the WGC cursor and relied on DDA pointer
metadata. The user's real VDD session exposed a missing cursor; the later
cursor correction section supersedes that cursor ownership. Earlier numeric
ramp evidence remains valid, but artificial CursorOverlay checks alone did
not qualify actual pointer visibility on the VDD.

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
  **2026-10-19 07:58:53 UTC** (superseded; final deployment recorded below). Release and `%ProgramFiles%\Relay\relay-host.exe` SHA-256:
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

**First deployment and SYSTEM verification (2026-10-19 Pacific / 2026-10-20 UTC)**

The first helper-backed release (`ecb33ee`) was installed. Its release and
`C:\Program Files\Relay\relay-host.exe` then both had SHA-256
`2A36B9CD1AAD29055832DBEF29B8042801968A7645BDA6CC26A1B2466C96F9AA`.
On resuming after the usage limit, fmt, all 237 unit + 2 probe + integration
tests, the separate NVENC/WinRT lifetime regression, strict clippy and release
build passed again. The sandboxed attempt could not open loopback sockets or
rename a temporary journal; the unrestricted rerun passed all checks.
Two earlier elevation attempts were cancelled before their guarded script
started; the user then requested another prompt and accepted it at
**18:28:43 Pacific / 01:28:43 UTC**. The intermediate candidate SHA-256
`ABD08DCC1DCD5073206A5AA58DFE38015BC0B76AE8AD1EA1295662B011B3B20D`
withheld 10-bit under SYSTEM and is now superseded, as is the earlier `F516…`
candidate. Neither hash denotes the final feature build.

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

The local script `host/target/system-guarded.ps1` installed with
`tools/install-host.ps1 -SkipDriver`, temporarily used the exact SCM command
`"C:\Program Files\Relay\relay-host.exe" --no-vdd service run`,
and proved the latest SYSTEM worker was in no-VDD mode **before** any probe.
Both persisted-pairing sessions exited 0 and negotiated `0x09` / `0x0d`,
capturing the unchanged **2560×1440@120** physical primary at Fastest,
120 Mbps. No virtual display was attached, no physical display colour/DPI/mode
was changed, and no input test was requested. Both sessions launched the
signed-in-user WGC source successfully (PIDs **21200 / 17160**) and logged
FP16 desktop → shared RGB10 → SYSTEM RGB10 cursor/slots → NVENC ABGR10.

The native scene's actual source/composition samples were **64/64** for each
ramp, max error **0**, and all cursor/range/channel controls passed. The
**SYSTEM service dumps**, decoded against that scene's CSV by
`tools/check-precision.py`, retained **37/47/39/52** (4:2:0) and
**33/45/27/53** (4:4:4) R/G/B/gray codes. Maximum RGB errors were **5 / 6**;
mean absolute errors **1.350 / 1.354**. Both have the expected SDR
`tv / smpte170m / bt709 / bt709` VUI and correct black/white/primary controls.
These are actual service capture/encode results, not merely format labels.

The three-second probes received **272 / 273 frames**, including ~0.76 s
startup (90.4 / 90.9 fps over the full interval); PC work p50/p95 was
**2.99/3.94 / 4.62/6.01 ms**. This is a short, mostly static precision check,
**not** sustained 3024×1964@120 performance qualification. All 7 clock replies
arrived per session; DWM present timestamps remained unknown as intended.

The test harness then read a **blank** PowerShell `Process.ExitCode` for the
finished scene and recorded `success=False` / `native scene failed ()`.
It had already completed both successful probes, scene pixel checks, CSV
and production dump. The CSV was copied to each service dump afterwards and
both were independently decoded/validated as above. Do not describe the
whole harness as an exit-0 run. Its finally restored
`"C:\Program Files\Relay\relay-host.exe" service run` and restarted the normal
service at **01:29:19 UTC**. Final checks: service **Running**, normal VDD
configuration, `ten_bit: true` and `enc=q,444,10`, both source PIDs gone,
only supervisor/worker remain, matching hashes, installed-service
`probe --pair-only` exit 0 (same identity, already paired, caps `0x0f`).
Evidence is in `system-{420,444,scene}.*`, `system-guarded*`,
`final-normal-worker.txt` and `final-installed-pair-only*` under the ignored
evidence directory. The earlier cancelled deployment is resolved.

**Lock/login source switching update (2026-10-19)**

The user's amendment is implemented in `c060d0f`: a selected HEVC 10-bit session chooses
`Secure8` on Winlogon, `Desktop10` on Default, and waits on unknown/unreadable
desktops. Secure8 uses the production DDA/BGRA8/ARGB path with the **same
10-bit output**; it does not claim 10-bit source precision. Desktop10 still
requires FP16/RGB10/ABGR10 and refuses unsupported SDR formats. Capture watches
desktop changes in both modes, including while awaiting the first frame,
and normal recovery recreates the appropriate source/slots/encoder. The VDD,
negotiated format, chroma, Main10/Rext profile and VUI remain unchanged. Fresh
parameter sets and a keyframe use the existing restart path; no reconnect,
wire or client changes. No 8-bit fallback is enabled for a WGC failure on
Default. Plain 8-bit/H.264 keep their existing behavior.

Windows fmt, **239 unit tests + 2 probe tests + integration**, strict clippy,
release build and the read-only NVENC/WinRT lifetime regression pass. Preflight
now registers/maps **both** RGB10 and BGRA8 inputs with the selected Main10/Rext
output. New tests cover Winlogon/Default selection, refusal for unknown
desktops, restart detection in both directions, H.264/8-bit compatibility and
SDR/format checks for the secure source.

Safe unchanged-desktop release diagnostics forced **only** the secure input
combination with `RELAY_TEST_FAULT=secure-capture`; they did not lock Windows
and are not a real Winlogon/transition pass. Actual production secure-source
4:2:0 / 4:4:4 dumps decode as yuv420p10le / yuv444p10le, correct SDR VUI and
controls, ramp counts **19/16/16/16 / 18/16/16/16**, max error **10 / 10**,
mean error **1.965 / 1.947**. With the hook cleared, the true 10-bit path keeps
**64/64** source/composed codes, max error **0**; decoded counts
**36/44/31/54** in both chroma modes, max error **5**, mean error
**1.199 / 1.201**. These are 12-frame Best/200 Mbps/30 fps checks. The secure
diagnostic's raw 64-code report describes its preliminary WGC reference
sampling, not the deliberately 8-bit production encode input; the production
logs explicitly show BGRA8/ARGB. Evidence: `switch-{secure,desktop}-{420,444}.*`.

The updated build is **installed**. Its release and installed SHA-256 match:
`D63A3F7F8ACF1B19D92897D8E4E7B5B5655E0B3047CB330F4C600CD3D70A517F`.
The accepted elevation ran `switch-system-guarded.ps1`: the newest SYSTEM
worker's no-VDD guard passed before both probes. Both sessions exited 0,
negotiated `0x09` / `0x0d` on the unchanged 2560×1440@120 physical primary,
and produced valid 10-bit dumps. The scene kept **64/64** source/composed
codes with zero error. SYSTEM dump decoded counts are **38/43/35/52** /
**36/43/28/54**, max errors **5 / 6**, mean error **1.309** each, expected SDR
VUI and correct channel/range controls. The ordinary 8-bit HEVC and H.264
release diagnostics also pass unchanged: source/composed **16/64**, max
error **2**, decoded counts **9/12/9/14**, max error **14**, mean error **6.167**.

The two three-second SYSTEM probes received **225 / 225** frames, including
startup, PC work p50/p95 **2.98/3.96 / 4.74/5.14 ms**, 7/7 clock replies each,
unknown WGC present timestamps. Extra preflight covers both input depths;
these short checks do not qualify sustained 3024×1964@120 performance.
The harness now caches the scene process handle before waiting; the complete
run recorded **success=True**, resolving its earlier blank ExitCode issue.
Finally restored the normal service command and worker at **01:44:18 UTC**:
service Running, `enc=q,444,10`, only supervisor/worker remain, matching
hashes, `probe --pair-only` exit 0 with the same already-paired identities and
caps `0x0f`. Evidence: `switch-system-*`, `switch-final-normal-worker.txt`,
`switch-installed-pair-only*`, `switch-eight.*`, `switch-h264.*`.

Actual lock/login, sign-in, user-switch and real-Mac continuity remain
pending below; older 8-bit-source lock/recovery tests do not qualify the new
automatic policy. No exclusive session or actual lock/sign-in was run by the
agent for this update.

**Cursor correction and timing diagnosis (2026-10-19; `20ea60a`)**

The user reports no cursor on the real 10-bit VDD session, and missing image
age / encode-send / desktop-to-screen HUD values with "clock not synced".
The initial WGC source explicitly excluded its cursor and relied on DDA's
separate pointer shape/visibility. That is insufficient when DDA has already
baked the pointer into the BGRA8 desktop that this path discards. The fix
enables **WGC cursor capture in FP16**, including in the user helper, and
never updates/draws a DDA overlay on true 10-bit frames. DDA now observes
output loss/recovery only there. Windows owns the single pointer composition;
GPU SDR conversion, RGB10 sharing/slots and ABGR10 input retain precision.
The 8-bit/secure paths keep their existing DDA cursor behavior.

`precision --cursor-check` now compares **actual Windows cursor pixels** at
two positions with the known native RGB10 test image, and verifies the old
position is clean after moving. It restores the pointer on success/error and
pumps test-window messages so a long held scene stays responsive. The release
direct paths detected **93 / 144** changed pixels; the shared-GPU helper path
detected **13 / 260**; both positions had **zero trail pixels**. Counts depend
on which cursor frame arrives; the test requires visible pixels, not those
exact counts. A negative control with `omit-wgc-cursor` fails with "WGC cursor
missing or left trails", reproducing the old source setting. Synthetic
CursorOverlay shapes alone would not have caught this regression.

All native 10-bit ramps still retain **64/64** source/composed codes with
maximum error **0**. Release 4:2:0, 4:4:4 and helper production dumps decode
with **38/44/31/54** R/G/B/gray codes, max error **5**, mean errors
**1.199 / 1.193 / 1.199**, correct SDR controls/VUI. Ordinary 8-bit HEVC and
H.264 remain **16/64** source codes (max error 2), decoded **9/12/9/14**,
max error 14 / mean 6.167. Windows fmt, 239 unit + 2 probe + integration,
strict clippy, release and the separate NVENC lifetime/input trial pass.
Evidence: `cursor-direct*`, `cursor-broker*`, `cursor-negative*`,
`cursor-release-{420,444,broker,eight,h264}.*` under the ignored evidence folder.

The cursor build is installed; release/installed SHA-256 both equal
`225B3B78C71922910C7B8B946973ABB992B640EAE9E5BBE40B671BC5AA80188A`.
The first installation's guarded SYSTEM test stopped **before any probe** on
a PowerShell log Substring/argument type error. Its finally restored the
normal service. Pair-only passes, service Running, `enc=q,444,10`, no helper
left behind. The corrected log reader casts a joined string and integer
index. The accepted SYSTEM-only retest then completed **success=True** without
reinstalling. The newest no-VDD worker guard passed before both exit-0 probes.
The scene retained **64/64** codes, max error 0, and actual cursor checks
detected **93 / 144** changed pixels with zero trails. SYSTEM 4:2:0 / 4:4:4
dumps decode with **37/41/38/51 / 33/46/30/54** ramp codes, max errors **6 / 6**,
mean errors **1.404 / 1.346**, expected SDR VUI and channel/range controls.
Both kept **7/7** clock replies while DWM present stayed unknown; independent
submit → sent p50/p95 **2.798/3.005 / 4.508/4.967 ms**, PC work
**2.97/3.19 / 4.70/5.18 ms**. These directly demonstrate encode/send and clock
telemetry do not depend on a source-present stamp. They do not prove this
Mac's UI consumes or labels them correctly.

Normal service restored at **02:11:19 UTC**, Running, `enc=q,444,10`, only
supervisor/worker remain, hashes still match, pair-only exit 0 with the same
already-paired identities and caps `0x0f`. `cursor-system-guarded-first-*`
preserves the failed harness evidence; `cursor-system-*`,
`cursor-final-normal-worker.txt`, `cursor-installed-pair-only*` preserve the
successful final checks. No exclusive test or actual lock/sign-in was run by
the agent for this cursor correction. Reconnect from the Mac to verify the
pointer in the real VDD stream; that visual check is still pending.

At `20ea60a`, the WGC DWM present timestamp remained **unknown**. Clock requests/replies and
encode/send telemetry still work independently; the Mac HUD bug/follow-up is
the separate Open item above. Host logging now says source age is unavailable
instead of reporting a fabricated **0.00 ms** when no samples are known, and
averages known ages over their actual sample count. No wire/client change
at that revision; the unified timing update below supersedes this restriction.

Read-only audit of the user's installed `D63A3F7F…` session: 01:48:29 UTC
active VDD **10-bit SDR** at 3024×1964@120; 01:48:33 Winlogon BGRA8/ARGB
source with unchanged 10-bit output (recovered in 1.2 s); 01:52:40 Default
RGB10/helper source (1.5 s), same TCP session until normal restore at
01:53:34. Both physical devices/layout and original VDD color tags restored.
The cause of that Winlogon interval (lock/login/UAC) was not independently
recorded, so it does not qualify reboot-before-login or user-switch behavior.
Later 8-bit / 10-bit sessions also restore normally. Host logs show steady
120 fps on the true 10-bit source, but Mac screen latency/buffer precision,
actual VDD native-ramp precision and the fixed cursor still need user checks.

References: [WGC cursor inclusion](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.iscursorcaptureenabled),
[DDA pointer composition](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api#updating-the-desktop-pointer).

**Unified 10-bit timing (2026-10-19 Pacific / 2026-10-20 UTC; `792bca7`)**

The user explicitly requested the same Mac timing rows/labels as 8-bit.
WGC SystemRelativeTime now feeds the existing `present_us` field, converted
from 100 ns units to the host's QPC clock. Direct capture keeps it with the
converted frame. The SYSTEM user's helper writes a tagged 24-byte sequence
and source-QPC record before publishing key 1 of the RGB10 texture. The
host peeks a complete record without blocking, acquires key 1, consumes the
metadata and GPU pixels together, then returns key 0. A new pipe/process/
texture resets the sequence on recovery. Partial records, bad tags, duplicate/
skipped sequences, backwards/nonpositive times and helper errors cannot be
mistaken for a new frame. Conversion failures never publish a valid slot.
Pixels remain GPU-only; timestamps ride each picture through NVENC's output
queue. Re-encodes without a fresh source remain unknown, just like 8-bit.

The first production timing diagnostic caught WGC source stamps **later
than CPU submission**, including a measured 1,557 us lead, despite the API's
documented QPC/compositor clock. This is not a clock-sync failure. The final
build retains raw source time for cadence but excludes such a stamp from
wire timing and age statistics for that picture. It never fabricates zero
age, uses pipe/arrival time as the source, or delays video to make timestamps
fit. A focused regression covers this case. Unknown samples still carry
submit/send/work/clock telemetry. PROTOCOL.md and both sides' timestamp
comments now describe source time from either capture API. The 68-byte
layout, capability byte, Mac calculations and HUD labels are unchanged;
**the existing Mac app can consume this host fix without rebuilding**.
Client edits are comments only; Swift builds/tests remain Mac-owned.

Windows fmt, **243 unit tests + 2 probe tests + integration**, strict
all-target clippy and release build pass. The first sandboxed test attempt
was denied loopback/temp-file access; rerunning with normal OS access passed.
New tests cover WGC time-unit conversion across frequencies/long uptime,
fragmented metadata, sequence/clock/error validation, and future/reused
source stamps. The enhanced production diagnostic verifies ordered source/
submit times in actual emitted access units and requires known WGC samples.

Release direct 4:2:0 / 4:4:4 and GPU-sharing helper diagnostics all pass:
**64/64 R/G/B/gray source and composed codes, max error 0**. Actual pointer
pixels: direct **93/144**, helper **209/260**, zero trails. Production timing
had **5/12, 10/12 and 8/12** known source stamps, all ordered; other pictures
were repeated or had unusable source times. Decoded ramps retained
**38/44/31/54, 37/44/31/54 and 38/44/31/54** codes, max error **6**, mean
error **1.226 / 1.216 / 1.226**, expected SDR channels/range/VUI. Ordinary
8-bit HEVC and H.264 remain **16/64** captured codes, decoded **9/12/9/14**,
max error **14**, mean **6.167**. The secure-input simulation also passes
with 12/12 ordered source stamps and unchanged 10-bit output; this is not
an actual lock/sign-in test.

The verified build is **installed**; release and installed SHA-256 both:
`09E95E2D9F4B97EC3479F6BCF1D51B8A145E3095EF1B86E13D8BBF22F1E3E276`.
The accepted elevation ran `timing-system-guarded.ps1`. It required a **new**
worker's explicit no-VDD startup proof, then rechecked that worker before
each probe. Both five-second SYSTEM probes exit 0 with video_format
**0x09 / 0x0d** on the unchanged 2560×1440@120 physical primary:

| SYSTEM check | 4:2:0 10-bit | 4:4:4 10-bit |
|---|---:|---:|
| Frames / EXT records | 467 / 466 | 466 / 465 |
| Known source stamps / out of order | 9 / 0 | 99 / 0 |
| Source → submit p50 / p95, ms | 7.079 / 16.473 | 2.964 / 3.281 |
| Submit → sent p50 / p95, ms | 3.024 / 4.048 | 4.556 / 5.794 |
| PC work p50 / p95, ms | 3.25 / 4.28 | 4.76 / 6.01 |
| Clock requests / retained samples (limit 8) | 9 / 8 | 9 / 8 |
| Best offset / delay, us | +5 / 39 | -2 / 59 |

The native scene still retains **64/64** codes, zero error, visible cursor
and no trails. SYSTEM dumps decode **36/40/35/52 / 34/44/32/54** codes, max
error **6 / 6**, mean **1.438 / 1.292**, correct SDR controls/VUI. Short
static-scene checks, startup-inclusive fps and sparse known timestamps do
not qualify sustained 3024×1964@120 latency/performance.

The harness completed **success=True**; the normal service command was
restored and a normal worker started at **02:34:23 UTC**, service Running,
`enc=q,444,10`, installed hash matching release. Pair-only passes with the
same identities and caps `0x0f`; no display is requested by that check.
Evidence is under ignored `host/target/precision-evidence/timing-*` and
`host/target/timing-{tests,clippy,release-build}.txt`. No exclusive display
session, actual lock/sign-in or Mac runtime test was run for this update.
The user/Mac qualification and unknown-source HUD follow-up stay open.

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
2. User: with **10-bit selected**, connect while locked/before sign-in: the
   lock/login screen must appear from the logged 8-bit secure source. Sign in
   without reconnecting: logs must switch to true FP16/RGB10/ABGR10 capture
   and gradients regain the measured precision. Lock/unlock again in that
   same connection, and sign out/back in or switch users. Repeat with 10-bit
   off to check the unchanged 8-bit behavior. Also check cursor
   (normal/masked/monochrome), quick reconnect, capture/GPU restart, disconnect and failure restore
   with the SYSTEM worker. Check physical monitor colour settings, positions,
   primary, DPI and refresh rates return as before, and that the colour journal
   is removed only after restoration. The automatic source transitions are **unqualified**;
   older DDA lock/recovery passes do not qualify this source.
3. Mac: rebuild current client, verify real VideoToolbox 10-bit output buffers,
   normal colours/gradients and no double cursor. At 3024×1964@120 Fastest,
   compare fps, PC work, receive → screen and input latency for both chroma
   modes against 8-bit. All earlier “10-bit free” measurements used the old
   8-bit source and must not be treated as a result for WGC/FP16 capture.
4. Mac + user: verify the existing Desktop → screen, image-age and encode/send
   rows against the installed unified-timing host, in both chroma modes and
   across secure/Default transitions. Keep the same labels as 8-bit; no Mac
   upgrade is required for valid stamps. Host no-VDD timing is verified below,
   but real-Mac source-to-screen latency, the exclusive VDD source and actual
   desktop switches remain unqualified. The separate Mac unknown-source HUD
   follow-up is still open.

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
