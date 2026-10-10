# NVIDIA, Apple silicon and SwiftUI review

Reviewed 2026-10-10 at source commit `1d0118e`. This is a proposed implementation
plan, not a record of completed platform or UI changes.

The requested policy is NVIDIA-only on Windows and Apple-silicon-only on Mac,
with SwiftUI wherever practical. Develop and fully test on the latest stable
macOS; choose the minimum macOS version from the APIs actually adopted, rather
than automatically requiring the latest major release. The existing accelerated stream
path already serves this combination. Most implementation work is support
enforcement, removal of alternative backends, and separation of UI state from
the connection/decoder pipeline.

## Evidence and scope

The review covered the host/client module layout, capture and encode selection,
virtual-display and service lifecycle, transport/pairing boundaries, decode and
presentation, input, picker/settings/menus, persistence, installer/bundler, CI,
tests and protocol/performance documentation. Generated NVENC bindings were
checked for API version and available entry points; this was not a line-by-line
audit of generated ABI definitions or cryptographic correctness.

- Current machine: Apple silicon (`arm64`), macOS 27.0 build 26A428, Xcode 27.0,
  Swift 6.4 compiler. `swift test` passed all 102 tests, including Metal rendering
  tests, on this machine. It still compiles the project in Swift 5 language mode.
- A separate temporary build with `-swift-version 6` failed at module emission.
  The first seven distinct diagnostic locations are shared state in
  `HoverCard.shared`, `MainMenu`'s two menu delegates, and four `Style.Font`
  properties. These are initial blockers, not a complete migration error count.
- Existing Windows records report 145 unit tests and a probe integration test
  passing, plus installed NVIDIA streaming and real-Mac tests. No Windows build,
  GPU benchmark or new physical streaming session was performed for this review.
- At review time, Apple lists macOS 27 Golden Gate **27.0.1** as the latest
  release. This machine's 27.0 results do not qualify 27.0.1. Qualify the current
  stable release without automatically making it the deployment floor.
  [Apple release list](https://support.apple.com/en-us/109033).
- Agreed compatibility policy: preserve older macOS compatibility where the
  adopted APIs allow it. Decide availability fallbacks individually; document
  the feature that requires any increase in the minimum version. SwiftUI alone
  is not a reason to require macOS 27. Test the chosen minimum OS as well as the
  latest stable release before claiming that support.

## 1. Windows host: enforce NVIDIA support

### Required: select a supported encoder, not just a graphics adapter

[`gpu.rs`](/Users/amanali/repos/travel-display/host/src/gpu.rs:181) currently ranks
adapters by hybrid status, dedicated VRAM, then vendor. An AMD adapter with more
VRAM can win over NVIDIA. An explicit `--gpu` also accepts any matching vendor.

Filter encoding candidates to NVIDIA and validate explicit selections. Retain
enumeration of Intel/AMD adapters: hybrid laptops, output mapping and diagnostic
messages still need to know they exist. Preserve the indirect-display proxy
filter and use the adapter LUID for identity where possible. A NVIDIA vendor ID
alone is insufficient: some NVIDIA models lack NVENC. [NVIDIA hardware matrix](https://developer.nvidia.com/video-encode-decode-support-matrix).

Add a capability record in `nvenc_bindings/mod.rs` / `native_nvenc.rs`, exposed by
an explicit diagnostic command and used by `server.rs`:

- Driver-supported NVENC API version and a useful driver-update error.
- Available codec GUIDs, profiles, input formats and asynchronous encode support.
- Requested dimensions and relevant encoder feature limits.
- Selected adapter identity and whether the actual capture output is on it.

The loader currently calls `NvEncodeAPICreateInstance` directly; initialization
chooses profiles, ARGB input, presets and async encoding without enumerating
their support. Bindings contain the capability functions but production code
does not call them. NVIDIA recommends querying codecs, formats and capabilities
before using them. [NVENC programming guide](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-video-encoder-api-prog-guide/index.html).

`server.rs` currently chooses a codec from the client mask and host preference,
acquires the display, and then starts the encoder. Add hardware support to that
intersection and preflight driver/codec/dimension failures before changing the
display topology. Recheck the actual adapter/output after virtual-display
attachment, with rollback if it does not match. Return useful failure text to
the Mac instead of leaving encoder failures only in the host log.

The bindings target NVENC API **12.1**. Updating to the newest SDK is not required
merely to support a newer NVIDIA GPU: NVIDIA documents backward compatibility
for older released APIs on newer drivers. Evaluate a binding update separately
if a needed feature requires it. [NVENC compatibility contract](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-video-encoder-api-prog-guide/index.html).

Do not promise native-resolution 120 fps on every supported GPU. The recorded
performance baseline is an Ampere PC and a 14-inch MacBook Pro. Publish tested
models/modes; use capability checks for eligibility and hardware runs for speed.

### Recommended simplification: one native encoding backend

[`encoder.rs`](/Users/amanali/repos/travel-display/host/src/encoder.rs:463) has
native NVENC, FFmpeg NVENC, AMD AMF, Intel QSV and software encoders. Native
startup and runtime failures can switch automatically to FFmpeg.

For the focused product, retain native DXGI/D3D11 → NVENC and remove the other
production paths after native failure/recovery has been verified. NVIDIA-only
support itself does not require removing FFmpeg NVENC; this is a deliberate
reduction in maintenance and performance variability.

Affected files: `encoder.rs`, `native_nvenc.rs`, `server.rs`, `main.rs`, probe
fixtures/tests and READMEs. Remove `--ffmpeg`, `--no-native`, process/pipe plumbing
and backend-specific command tests. Keep the Annex-B parser and access-unit
types that native NVENC still uses. Preserve desktop-not-capturable handling,
capture restart, bounded queues, asynchronous cleanup and display restoration.
Replace fallback with a classified native recovery/error path; deleting the
fallback branch alone is not enough.

Require the selected capture and encode adapter to match. A NVIDIA laptop may
also contain an Intel/AMD iGPU, so “NVIDIA-only” does not imply a single-adapter
machine. Cross-adapter support becomes an explicit limitation unless we later
implement a native transfer path.

### Recommended simplification: one virtual-display driver

Use MTT as the supported driver. Remove the unverified Parsec backend and its
installer/CLI options from `driver/parsec.rs`, `driver/mod.rs`, `main.rs` and
`tools/install-host.ps1`. Parsec has no GPU-selection facility and makes the
same-adapter requirement harder to guarantee. This is optional cleanup beyond
the vendor restriction; keep the small driver abstraction for test doubles.

Keep dynamic mode creation: deleting old Intel-Mac presets from
`vdd_settings.template.xml` is housekeeping, not the way to support new panels.
Do not change the MTT device-node control strategy or reintroduce its control
pipe. Keep the SYSTEM worker, input-desktop binding, saved topology and crash
restore. Their complexity comes from Windows login/lock/display behavior and
remains necessary with NVIDIA.

## 2. Mac: make the supported platform explicit

The current client already uses native Swift, CryptoKit, Network.framework,
VideoToolbox, IOSurface and Metal. There is no Intel-only streaming dependency
to replace and no need for a new media pipeline to support Apple silicon.

| Area | Proposed change |
|---|---|
| `Package.swift` | Audit adopted API availability before changing the current macOS 13 floor; adopt a current Swift tools version. Enable Swift 6 language mode after ownership fixes. |
| `Info.plist` | Match `LSMinimumSystemVersion` to the package floor; preserve bundle identity, Bonjour declarations and local-network explanation. |
| `bundle.sh` | Explicitly build arm64, match the icon deployment target, and verify the produced executable architecture. Fail if signing fails instead of swallowing it. |
| `VideoRenderer.swift` | Require hardware decoding, verify codec availability, and surface decoder creation failures to session UI. |
| `MetalPresenter.swift` | Keep the IOSurface texture path, bounded latest-frame mailbox, generation checks and presentation metrics. Make initialization failure explicit. |
| `VideoRenderer.swift` / launch options | Consider removing the AVSampleBufferDisplayLayer alternative. Remove its compatibility branches with that backend, or only when the chosen minimum OS makes them unnecessary. |
| `StreamMode.swift` / screen integration | Preserve runtime pixel sizes, backing scale and refresh-rate limits; qualify 60 Hz Air and 120 Hz Pro behavior separately. |
| `.github/workflows/client.yml` | Assert arm64, OS and Xcode versions; qualify latest stable macOS and the chosen minimum on verified runners or test Macs. Add release bundle/signature and fakehost checks. |

The proposed Observation-based UI requires macOS 14 unless we provide an older
observation approach. Other selected APIs may raise that floor further; record
their requirements during implementation. The build toolchain version and the
minimum runtime OS are separate decisions. Apple-silicon-only packaging also
does not require a latest-macOS-only policy.

[`VideoRenderer.makeSession`](/Users/amanali/repos/travel-display/client/Sources/Relay/VideoRenderer.swift:198)
currently *enables* hardware acceleration and logs whether it got it. For the
new support policy, use the requirement key and fail clearly when unavailable.
The Mac currently advertises HEVC and H.264 unconditionally; advertise the
supported set and still validate the actual received stream format. [Apple hardware-decoder requirement](https://developer.apple.com/documentation/VideoToolbox/kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder).

Metal construction is failable and currently causes an implicit switch to
AVSampleBufferDisplayLayer. Making Metal mandatory removes that second
presentation path but requires an explicit, user-visible failure path.

For distribution, use stable Developer ID signing and notarization, and retain
a reproducible local-development signing mode. Preserve `dev.relay.client` and
the existing Application Support files so this migration does not reset
identity keys, pairings, nicknames or preferences. Rebuilds while the old bundle
was still running already caused a local-network permission problem here;
qualify upgrades and relaunch, not just command-line builds.

SwiftUI does not require an Xcode project: the package can continue to build it.
A thin Xcode application/test target over a reusable Swift package is worth
considering for signing, previews and UI automation, but is a packaging choice.

## 3. SwiftUI migration: replace the interface and preserve the stream boundary

The main UI owners are `AppDelegate.swift` (897 lines) and
`HostPickerWindowController.swift` (867 lines), followed by rows, menus, PIN entry
and hover cards. There is substantial UI to replace, but no need to rewrite the
Rust host, encryption or video renderer as part of that replacement.

| Existing component | Destination |
|---|---|
| `main.swift`, UI portions of `AppDelegate` | SwiftUI `App`, a single picker `Window`, settings and commands. Keep only necessary application/window integration in an adapter. |
| `HostPickerWindowController` | SwiftUI host list, sections, selection, empty state, progress, mode controls and actions. |
| `HostRowView`, `HoverCard`, `Style` | SwiftUI rows, host-details popover, semantic fonts/colors and layout. |
| `PINEntryView` plus `NSAlert` handling | SwiftUI sheet and focused PIN field, preserving paste, deletion, automatic submission and attempt ownership. |
| `MainMenu` | SwiftUI commands sharing the same action/state model as the picker and settings. |
| Connection orchestration in `AppDelegate` | A session coordinator with explicit states and attempt identifiers. |
| `StreamView`, `StreamWindow` | A small AppKit integration boundary for video hosting, low-level input and kiosk behavior. |
| `Glyphs`, `IconExport` | Reuse existing drawing/export code initially; convert presentation wrappers where useful. Icon generation need not become SwiftUI. |

Use a main-actor observable model for host selection, preferences, status and
current pairing presentation. SwiftUI supports the Observation model directly.
Keep the transport, decoder and presenter on their existing dedicated execution
paths; publish infrequent state changes into the UI. [Apple Observation guidance](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro).

`AppDelegate` currently handles both AppKit events and
`HostConnectionDelegate` callbacks. The latter arrive on the connection queue,
and codec/frame callbacks go straight into `VideoRenderer`. Split the control
and frame callbacks before making the UI owner `@MainActor`. Moving every frame
through the main actor, an observable property or SwiftUI `body` would add work
to the latency-sensitive path. Keep renderer ownership stable across view
updates. The Swift 6 build failures reinforce the need for explicit isolation;
blanket unchecked `Sendable` declarations would not establish correct ownership.

Apple provides `NSViewRepresentable` to embed an AppKit view in SwiftUI.
Use it if the stream view is hosted in a SwiftUI hierarchy, with a coordinator
for events and explicit cleanup. SwiftUI must own the represented view's layout;
the view can size its Metal drawable from the resulting bounds/backing scale.
[Apple AppKit integration](https://developer.apple.com/documentation/SwiftUI/NSViewRepresentable?changes=la&language=objc).

Keeping a small AppKit boundary is a recommendation, not a claim that SwiftUI
cannot receive keyboard events. Relay needs physical key codes, independent
left/right modifiers, key-up handling, held-input release on focus loss,
precise scrolling, additional mouse buttons and interception of command-key
shortcuts. Its kiosk window also controls menu/Dock visibility, window level,
screen placement, cursor and keep-awake behavior. Reusing that tested code is
lower risk than recreating those semantics during the UI migration.

The full-screen video must remain opaque and unobstructed in normal operation.
The existing latency measurements show overlays affect presentation timing.
Qualify the SwiftUI container's compositing behavior; wrapping the view alone
does not establish equivalent latency. Avoid permanent decorative layers,
glass or animations over the stream. UI overlays can appear when requested.

Preserve these behaviors explicitly in migration tests:

- A PIN sheet belongs to one connection attempt and closes when it ends.
- Cancel/retry and background pairing verification ignore stale completions.
- Pair-only and Forget never request a streaming display.
- Bonjour TXT withdrawals retain the discovery grace period and stable rows.
- Rename commits on Return/focus loss, cancels on Escape, and survives list updates.
- Menu validation and command shortcuts follow picker versus stream focus.
- Losing focus/disconnecting/control-off releases all held keys and buttons.
- The stream window opens on the first frame and returns to the picker on failure.
- Window close/reopen, `--host` mode, CLI overrides, selected screen, and saved
  preferences retain their intended behavior.

The pure models (`PickerRows`, `PairingVerifier`, `StreamMode`, `SessionPrefs`,
`VideoBitrate`, `SessionText`) remain reusable. Replace table-index diffing once
SwiftUI owns rendering, but keep identity, classification and discovery logic.
Encapsulate `ClientState` file access behind one owner during the state split;
keep its on-disk format compatible.

## 4. Protocol and other modules

Noise XX, CPace, encrypted TCP records, mDNS, HID messages and the existing
HEVC/H.264 wire formats already work across these target platforms. The platform
restriction and SwiftUI migration need no protocol-version bump or pairing
reset. Keep shared vectors, chunking and host/client regression coverage.

Useful encoder failure details or advertised hardware limits may justify an
optional protocol extension. Design that separately and follow the host-first,
spec-and-both-clients sequence. The existing codec mask can already express
HEVC/H.264 availability.

AV1 is an enum/reserved possibility on the Mac, not an implemented decoder:
`makeFormatDescription` returns nil for it, and the host supports HEVC/H.264.
Keep HEVC as the baseline. AV1, HDR, 10-bit output and 4:4:4 are separate features
requiring capability negotiation, encode/decode/presentation work and hardware
qualification. Apple-silicon-only support does not make them automatic. The
current Metal shader accepts 8-bit biplanar 4:2:0 and outputs SDR BGRA.

Keep Windows `service`, `desktop`, `topology`, `display`, `devnode`, `input`,
`cursor_overlay`, `tray`, `discovery` and `sysinfo` responsibilities. Update their
diagnostics or backend references where necessary. Login-screen reliability,
crash restore and DPI remain product work even after this platform reduction.

## 5. Suggested implementation order and acceptance gates

1. **Declare/enforce supported platforms.** Enforce arm64 packaging, audit Mac
   API requirements and align deployment settings with the resulting minimum.
   Add NVIDIA selection and capability diagnostics and document supported
   configurations. Preserve existing UI during this step.
2. **Harden the native pipeline, then remove alternative host paths.** Test
   absent/old driver, unsupported GPU/codec/mode, hybrid adapter mismatch,
   capture loss and GPU reset. Remove FFmpeg/AMF/QSV/software and Parsec only
   after errors and recovery restore the physical displays correctly.
3. **Separate client state and execution ownership.** Introduce the UI model,
   session coordinator and frame sink; resolve Swift 6 diagnostics. Run current
   tests and isolated fakehost flows before changing screens.
4. **Migrate picker/settings/rows, then PIN and commands to SwiftUI.** Use a
   temporary hosting boundary if it keeps each step reviewable. Retain the
   native stream window/view until behavioral and latency comparisons pass.
5. **Qualify releases.** Add arm64 bundle checks and UI automation on latest
   stable macOS and the chosen minimum; test a 60 Hz Air, a 120 Hz Pro and an
   external display. Verify discovery,
   permissions, pairing, focus, sleep/wake, screen changes and application updates.

Windows tests should keep fast capability-selection/unit checks separate from
real NVENC integration tests. Generic hosted CI does not establish real NVIDIA
encode or SYSTEM/Winlogon display behavior. Qualify an explicit GPU/driver
matrix, including a hybrid laptop if that is supported. Let the user perform
exclusive-display tests on the active PC session.

Compare host encode/capture and Mac presentation percentiles at identical modes,
bitrates, link and overlay state against `docs/LATENCY.md`. The recorded roughly
4.2 ms mean / 5.3 ms p95 Mac receive-to-presentation baseline is a measured
reference, not a universal guarantee or glass-to-glass latency measurement.

The Mac UI/state migration is the largest change. NVIDIA enforcement is a
moderate host change; platform metadata cleanup is small. Release qualification
must remain a separate gate because passing unit tests does not prove hardware
compatibility or full-screen input/presentation behavior.
