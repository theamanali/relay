# Relay — working notes for Claude Code (read on every machine)

Use a MacBook as the *only* display of a Windows PC over a direct Ethernet cable
(hotel travel router / home LAN / Tailscale also work). One Rust binary on the PC,
one Swift app on the Mac, a small encrypted TCP protocol between them. Deliberately
smaller than Sunshine + Moonlight: no config UI, no game launcher; pairing is the one
piece of ceremony and it is intentional.

## Layout and which machine builds what

| path | what | builds/tests on |
|---|---|---|
| `host/` | Rust host: driver control, GPU selection, ffmpeg capture/encode, display topology, TCP + mDNS, input, crypto | **Windows PC only** (`cargo build --release`, `cargo test`, `cargo clippy --all-targets`) |
| `host/src/bin/probe.rs` | fake client in Rust; the way to test the host without a Mac | Windows |
| `client/` | Swift package, macOS 13+: Bonjour, handshake/pairing, VideoToolbox decode, kiosk window, input | **Mac only** (`swift build`, `swift run Relay`, `./bundle.sh` for a .app) |
| `tools/` | elevated installer (`install-host.ps1`), driver settings template, elevated helper script | Windows |
| `docs/PROTOCOL.md` | the wire contract, including the handshake **test vector** | both — this is the source of truth |

Two sessions, one repo: the PC session owns `host/` + `tools/`, the Mac session owns
`client/`. Both work on `main`; commit small, push often, `git pull` before starting.
Protocol changes go host-first (verified with `probe` + tests), then the spec, then the
client. Never change `docs/PROTOCOL.md` and only one side.

## Status (2026-09-15)

- Host: complete and verified on the real hardware — virtual display becomes the only
  display at the Mac's exact mode, layout restored on disconnect/Ctrl-C/hard kill,
  3024x1964@120 HEVC stream to `probe`, PIN pairing + encryption.
- Client: written blind (never compiled). First job on the Mac: `cd client && swift build`,
  fix compile errors **without changing the wire format**, then the first real session.
- After that: tray icon, installers, and milestone 5 (in-process DXGI → NVENC instead of
  the ffmpeg child, which removes one frame of latency).

## Running it

PC: `host\target\release\relay-host.exe` (prints the pairing PIN; `pin`, `paired`,
`gpus`, `displays`, `layout`, `restore`, `attach-test` subcommands). Installer once, elevated:
`tools\install-host.ps1`. Mac: `swift run Relay` opens a picker listing hosts
found over Bonjour under *Paired* / *Not paired* plus resolution (native/75%/50% of the
current screen) and refresh (120/60) popups, remembered in UserDefaults; choosing a host enters the kiosk window,
and a dropped session returns to the picker. `--host` skips the picker and re-dials on
drops. Other flags: `--pin`, `--max-fps`, `--scale`, `--modifiers`, `--no-input`,
`--latency-stats`, `--renderer`, `--metal-vsync`; exit with ⌃⌥⌘Q.

## Hard-won facts — do not relearn these

- **Renamed from TravelDisplay to Relay (2026-09-16).** Everything user-visible and every
  identifier changed (`_relay._tcp`, `relay-host.exe`, `Relay.app`, the `Relay display
  driver` task, `%LOCALAPPDATA%\Relay`, `~/Library/Application Support/Relay`) except the
  HKDF info string and `TDH2` handshake magic, which stay so pairings survive. Both state
  directories are moved from the old name automatically on first run. On the PC the
  installer must be re-run once (new task and firewall names; it removes the old ones).
  GitHub repo is `theamanali/relay` (old `travel-display` URLs redirect); a local clone
  directory may still be called `travel-display`.

- **MTT Virtual Display Driver's control pipe must never be used.** `SETDISPLAYCOUNT` /
  `RELOAD_DRIVER` crash its user-mode host; after 5 crashes Windows parks the device at
  Code 43. The device node is the switch: the host enables/disables it through the
  scheduled task `Relay display driver` (runs `C:\VirtualDisplayDriver\vdd-device.ps1`
  with the order in `action.txt`). There is no `Restart-PnpDevice`; use Disable/Enable.
- The driver keeps one monitor whenever enabled (count 0 == 1), so "invisible when idle"
  means the device is **disabled** between sessions. Enabling takes ~2 s.
- `SetDisplayConfig(SDC_TOPOLOGY_SUPPLIED)` fails with ERROR_GEN_FAILURE (31) for a layout
  Windows has never stored. Attach the monitor normally first, read back its modes with
  `QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS)`, then apply a complete one-path config with
  `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES`. Never save the virtual-only layout
  to the database. The snapshot for restore lives in `%LOCALAPPDATA%\Relay`.
- DXGI lists the driver's proxy adapter with the **same name and VRAM as the real GPU**;
  D3DKMT's `IndirectDisplayDevice` flag tells them apart (`gpu.rs`).
- **Never block inside `AcquireNextFrame`** on the native path. With `ID3D11Multithread`
  protection on, the waiting thread holds the device lock and NVENC cannot finish the
  previous picture until the wait returns (encode time becomes one frame interval).
  The capture thread polls `AcquireNextFrame(0)` on a sub-ms timer instead.
- When the PC's monitors are asleep, Desktop Duplication delivers zero frames: a capture
  test that suddenly produces nothing is that, not a bug. Send an input event first.
- `attach-test`, `probe` sessions and anything that goes through `topology::exclusive`
  **black out the PC's monitors** (and the Claude app on it) for the duration. Use
  `--no-vdd` for pipeline tests; let the user run the exclusive ones.
- ffmpeg-based capture (`ddagrab` → `hevc_nvenc`) paces a static screen at ~100 fps,
  not 120; that is frame duplication, not loss.
- Pairing is PIN-based, not a PAKE: pair on the cable or at home, never first-pair on
  hotel Wi-Fi. Keys/pairings: `%LOCALAPPDATA%\Relay`,
  `~/Library/Application Support/Relay`.

## Conventions

- Rust: `anyhow` errors, `log` macros, no async (one thread per concern), Windows APIs via
  the `windows` 0.58 crate, keep clippy clean. Swift: AppKit + Network.framework +
  CryptoKit only, no third-party packages.
- Defaults are 120 Hz and the Mac's native pixel size; `--scale 0.75`/`0.5` are the
  cheaper same-aspect modes.
- Keep the README's status table honest; note anything verified on real hardware.
