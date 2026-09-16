# TravelDisplay

Use a MacBook as a real extra monitor for a Windows PC over a direct Ethernet
cable. Plug in, open the Mac app, and Windows gets a new display at the Mac's
native resolution with trackpad and keyboard passthrough. Unplug or quit, and the
monitor disappears again.

Deliberately smaller than Sunshine + Moonlight: no config UI, no game launcher,
pairing is one PIN once. One Rust binary on the PC, one Swift app on the Mac, a
small encrypted protocol between them.

## How it works

```
 Windows PC (host, Rust)                                  MacBook (client, Swift)
 ┌──────────────────────────────┐   direct GbE cable    ┌──────────────────────────┐
 │ MTT VDD ────┐ virtual monitor│                        │ Bonjour: find host        │
 │             ▼                │  TCP 8468              │ TCP: hello, frames, input │
 │ DXGI Desktop Duplication     │ ───────────────────▶   │ VideoToolbox HEVC decode  │
 │ GPU HEVC enc (120 Mbps CBR)  │ ◀───────────────────   │ VT decode → display layer │
 │ SendInput ◀─ mouse/keys      │  (mDNS over IPv6 LL)   │ trackpad + keys → host    │
 └──────────────────────────────┘                        └──────────────────────────┘
```

1. **Virtual monitor.** Windows only believes in monitors that come from a
   kernel display driver, so the host drives MikeTheTech's open-source, signed
   [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver).
   Between sessions its device is disabled, so no virtual monitor exists at all.
   When a Mac connects the host saves your display layout, enables the device
   (its settings file already lists every Apple laptop panel size at native, ¾
   and ½, rendered on the GPU you chose) and makes the virtual monitor the
   **only** active display at the Mac's exact pixel size. It also temporarily
   disables the physical monitor device nodes, preventing fullscreen games from
   reactivating them. On disconnect those exact devices are re-enabled, the saved
   layout comes back, and the virtual device is disabled again. The host never
   needs elevation: device changes go through a scheduled task the installer
   registers, and that task watches the host so a crash also restores the monitors.
   [parsec-vdd](https://github.com/nomi-san/parsec-vdd) remains available as a
   fallback (`--driver parsec`) with neither of those two properties.
2. **Capture + encode.** The new monitor is captured with DXGI Desktop
   Duplication and encoded by the GPU's own encoder — NVENC, AMD AMF or Intel
   Quick Sync, chosen from the adapter's vendor id — without leaving the GPU.
   NVIDIA uses an in-process D3D11 → NVENC path with a GPU-composited Windows
   cursor and a fixed output cadence; `--no-native` falls back to the `ffmpeg`
   child. AMD, Intel, software and cross-adapter configurations use `ffmpeg`.
3. **Transport.** TCP with 8-byte framed messages, encrypted end to end — see
   [docs/PROTOCOL.md](docs/PROTOCOL.md). On a dedicated cable there is no loss
   and no contention, so WebRTC-style machinery would only add latency. Discovery
   is Bonjour over the link-local IPv6 addresses both OSes assign the instant a
   cable is up, so no DHCP is needed.
4. **Pairing.** Each side has a long-lived identity key. The first time a Mac
   connects it enters the 6-digit PIN the host shows; from then on both sides
   recognise each other by key, every session gets fresh ChaCha20-Poly1305 keys
   from an ephemeral X25519 exchange, and strangers on the same network are
   refused before anything is streamed.
5. **Client.** Native macOS app: an explicit real-time `VTDecompressionSession`
   hardware-decodes HEVC into IOSurface-backed pixel buffers, then submits them
   to a Metal presenter with a single pending decoded frame, VSync off by default
   (`--metal-vsync` re-enables it). `--renderer avsbdl` selects the previous
   `AVSampleBufferDisplayLayer` backend. Trackpad and
   keyboard forwarding are optional. Windows' cursor is part of the video, so a
   mouse attached directly to the PC and the Mac trackpad control the same
   visible pointer.

## Status

| milestone | state |
|-----------|-------|
| 0. Toolchain, repo, protocol spec | done |
| 1. Host: driver control (MTT + parsec), GPU selection, exclusive display mode with layout restore, vendor-aware ffmpeg capture/encode, TCP server, mDNS, input injection | done; verified on this PC: virtual display becomes the only display and the layout comes back on disconnect, Ctrl-C and a hard kill; 3024×1964@120 HEVC stream to the `probe` tool. parsec path untested |
| 2. Mac client: Bonjour, pairing, decode, fullscreen, input | verified on the Mac: pairing, native decode, keyboard, pointer input and quit shortcut work |
| Mac Metal presentation | default renderer, VSync off; direct YCbCr→RGB shader. Verified on a real stream: colour correct. Mode changes, reconnect and the Metal vs `--renderer avsbdl` latency numbers still to be recorded |
| 3. First real session over the cable | done; native 3024x1964@120 is usable, with remaining latency work tracked below |
| 4. Polish: tray icon, auto-start, headless boot, DPI | pending |
| 5. In-process DXGI → NVENC (drops ffmpeg and its pipe/parser delay) | done and default on NVIDIA; sustains 3024×1964@120 and verified stable in exclusive-fullscreen games (Valorant, FC 26) after enabling D3D11 multithread protection on the shared capture/encode device. `--no-native` falls back to ffmpeg |

## Setup

### Hardware

- Ethernet cable from the PC's NIC to a USB-C Ethernet adapter on the MacBook.
  Any modern NIC is auto-MDIX; no crossover cable, no switch.
- For the lowest input latency, connect the mouse, keyboard or controller
  directly to the PC. The Mac trackpad and keyboard remain available when
  carrying those devices is inconvenient.
- No DHCP needed. If Windows shows "Unidentified network", that is fine.

### Windows host (once)

```powershell
# toolchain: Rust (MSVC); ffmpeg remains the AMD/Intel/software fallback
winget install Rustlang.Rustup Gyan.FFmpeg
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621"

cd host
cargo build --release

# driver, settings file, firewall — needs an elevated PowerShell
.\tools\install-host.ps1
```

The script installs the driver, creates `C:\VirtualDisplayDriver\vdd_settings.xml`
(writable by your account), registers the elevated helper task, opens the
firewall, and leaves the driver device disabled. A session enables it and uses
whatever size the connecting Mac reports (its native pixels, or ¾/½ of them with
the client's `--scale`); an unknown size is merged into the settings file first.
Nothing is tied to one MacBook.
`-Driver parsec` installs parsec-vdd instead; then the modes are fixed and come
from `-Resolutions "WxH@Hz",...`, five at most.

Then run:

```powershell
host\target\release\traveldisplay-host.exe            # serve (default); prints the pairing PIN
host\target\release\traveldisplay-host.exe pin        # show the PIN (--new to change it)
host\target\release\traveldisplay-host.exe paired     # paired Macs (--forget <fingerprint>)
host\target\release\traveldisplay-host.exe gpus       # adapters and which one is used
host\target\release\traveldisplay-host.exe displays   # what Windows/DXGI see
host\target\release\traveldisplay-host.exe attach-test --width 3024 --height 1964 --hz 120
                                                      # full session dance for 10 s: your monitors go dark!
host\target\release\traveldisplay-host.exe restore    # put the displays back if something went wrong
host\target\release\traveldisplay-host.exe layout     # show the current layout (--reapply to test restore)
host\target\release\traveldisplay-host.exe --no-vdd   # dev: stream the primary monitor
```

Useful flags: `--gpu 4090` (substring of the adapter name; default is the
adapter with the most dedicated VRAM, i.e. the discrete card on a PC that also
has an iGPU), `--driver mtt|parsec|auto`, `--quality speed|balanced|quality` (speed is the low-latency default),
`--bitrate 200` (Mbps), `--codec h264`, `--fps 60`, `--intra-refresh` (NVIDIA),
`--no-native` (fall back to the ffmpeg capture path instead of the in-process
NVENC one), `--no-input`, `-v`. Add
`-AutoStart` to the install script to launch the host at
logon (needed for a headless PC). Ctrl-C restores your displays and removes the
virtual monitor; if the host is killed, the helper task disables the virtual
monitor and Windows brings the physical ones back, and the next host start (or
`restore`) re-applies the saved layout.

### macOS client

```sh
cd client
swift run TravelDisplay            # dev
./bundle.sh && open TravelDisplay.app   # proper .app (local-network permission prompt)
```

Flags: `--host 169.254.x.y` (skip Bonjour), `--pin 123456` (otherwise a dialog
asks the first time), `--max-fps 60` (default 120),
`--scale 0.75` or `0.5` (request ¾ or ½ the pixels: softer on the panel but
much cheaper to encode — the gaming modes), `--modifiers physical`, `--no-input`,
and `--latency-stats` (live host/network/client estimate; toggle with ⌃⌥⌘L).
**Exit with ⌃⌥⌘Q.** By default ⌘ acts as Ctrl, ⌥ as Alt and ⌃ as
Win so ⌘C/⌘V behave like Mac shortcuts.

## Testing without a Mac

`host/src/bin/probe.rs` is a fake client:

```powershell
cargo run --bin probe -- --seconds 5 --out capture.hevc --wiggle
ffplay -f hevc capture.hevc
```

## Known limitations

- The in-process NVIDIA path is the default and is verified stable at
  3024×1964@120 in exclusive-fullscreen games (Valorant, FC 26). An earlier
  build hard-hung the GPU during a game's mode switch because the shared
  capture/encode D3D11 device lacked multithread protection; that is fixed.
  `--no-native` falls back to the ffmpeg path if a future case misbehaves.
- Fullscreen and display-mode transitions can invalidate Windows Desktop
  Duplication briefly. The host restarts capture for up to 15 seconds without
  disconnecting the Mac. Physical monitor devices remain disabled throughout
  the session, so games cannot restore their old multi-monitor topology.
- AMD and Intel still use ffmpeg with their hardware encoders and remain
  untested. A GPU with no hardware encoder falls back to software x264/x265 and
  will not keep up at large sizes.
- Pinning the render GPU needs IddCx 1.10 (Windows 11 22H2+). On older Windows
  the driver picks; the host notices and copies frames to the encoder instead.
- The MTT driver's own reload command (`SETDISPLAYCOUNT`/`RELOAD_DRIVER` on its
  control pipe) crashes its user-mode host on release 25.7.23, and Windows gives
  up restarting it after five crashes (Code 43). The host therefore never uses
  the pipe; a mode-list change is applied by restarting the device through the
  installer's scheduled task, which also recovers a Code 43. Re-running
  `toolsinstall-host.ps1` fixes a driver that is stuck.
- On fallback paths, a completely static screen can stream at ~100 fps instead
  of the display's 120 because of ffmpeg's ddagrab pacing; moving games are the
  useful frame-rate test.
- macOS keeps ⌘Tab, ⌘Space and the Fn media keys for itself; everything else is
  forwarded.
- Windows DPI scaling for the virtual monitor is a per-monitor setting Windows
  remembers; set it once in Settings → Display (200% for a Retina-native mode).
- Headless boot works once the host runs at logon; the BIOS and the login screen
  are not visible (a $20 HDMI→USB capture dongle is still the answer for those).
- Pairing is PIN-based, not a PAKE: someone actively in the middle of the *first*
  pairing could brute-force the PIN. Pair on the cable or at home; afterwards the
  pinned keys make impersonation impossible, and hotel Wi-Fi is fine. Both sides
  keep their keys and pairings in `%LOCALAPPDATA%TravelDisplay` and
  `~/Library/Application Support/TravelDisplay`.
