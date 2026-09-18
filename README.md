# Relay

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
 ââââââââââââââââââââââââââââââââ   direct GbE cable    ââââââââââââââââââââââââââââ
 â MTT VDD âââââ virtual monitorâ                        â Bonjour: find host        â
 â             â¼                â  TCP 8468              â TCP: hello, frames, input â
 â DXGI Desktop Duplication     â ââââââââââââââââââââ¶   â VideoToolbox HEVC decode  â
 â GPU HEVC enc (120 Mbps CBR)  â ââââââââââââââââââââ   â VT decode â display layer â
 â SendInput ââ mouse/keys      â  (mDNS over IPv6 LL)   â trackpad + keys â host    â
 ââââââââââââââââââââââââââââââââ                        ââââââââââââââââââââââââââââ
```

1. **Virtual monitor.** Windows only believes in monitors that come from a
   kernel display driver, so the host drives MikeTheTech's open-source, signed
   [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver).
   Between sessions its device is disabled, so no virtual monitor exists at all.
   When a Mac connects the host saves your display layout, enables the device
   (its settings file already lists every Apple laptop panel size at native, Â¾
   and Â½, rendered on the GPU you chose) and makes the virtual monitor the
   **only** active display at the Mac's exact pixel size. It also temporarily
   disables the physical monitor device nodes, preventing fullscreen games from
   reactivating them. On disconnect those exact devices are re-enabled, the saved
   layout comes back, and the virtual device is disabled again. The host never
   needs elevation: device changes go through a scheduled task the installer
   registers, and that task watches the host so a crash also restores the monitors.
   [parsec-vdd](https://github.com/nomi-san/parsec-vdd) remains available as a
   fallback (`--driver parsec`) with neither of those two properties.
2. **Capture + encode.** The new monitor is captured with DXGI Desktop
   Duplication and encoded by the GPU's own encoder â NVENC, AMD AMF or Intel
   Quick Sync, chosen from the adapter's vendor id â without leaving the GPU.
   NVIDIA uses an in-process D3D11 â NVENC path with a GPU-composited Windows
   cursor and a fixed output cadence; `--no-native` falls back to the `ffmpeg`
   child. AMD, Intel, software and cross-adapter configurations use `ffmpeg`.
3. **Transport.** TCP with 8-byte framed messages, encrypted end to end â see
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
| 1. Host: driver control (MTT + parsec), GPU selection, exclusive display mode with layout restore, vendor-aware ffmpeg capture/encode, TCP server, mDNS, input injection | done; verified on this PC: virtual display becomes the only display and the layout comes back on disconnect, Ctrl-C and a hard kill; 3024Ã1964@120 HEVC stream to the `probe` tool. parsec path untested |
| 2. Mac client: Bonjour, pairing, decode, fullscreen, input | verified on the Mac: pairing, native decode, keyboard, pointer input and quit shortcut work |
| Mac host picker | implemented: Paired / Available sections, return-to-list on disconnect, `--host` bypass. Pairing is decided by the Bonjour TXT `pk` key only; per-row rename and forget-on-both-sides buttons. Bonjour goodbye handling verified on the hardware (2026-09-17): quitting the host from its tray removes the row within ~1 s with no intermediate Available state; restarting it returns the row to Paired |
| Mac Metal presentation | default renderer, VSync off; direct YCbCrâRGB shader. Verified on a real stream: colour correct. Mode changes, reconnect and the Metal vs `--renderer avsbdl` latency numbers still to be recorded |
| 3. First real session over the cable | done; native 3024x1964@120 is usable, with remaining latency work tracked below |
| 4. Polish: tray icon, auto-start, headless boot, DPI | tray icon done and verified on this PC: windowless host, status / PIN / paired-Macs menu, PIN rotates after each pairing, icon survives an Explorer restart and follows the taskbar theme (icons rendered on the Mac from the picker glyph). Start at login done and verified on this PC: unelevated logon task, exe copy in `%LOCALAPPDATA%Relaybin`, supervisor restarts a crashed host in 5 s, tray toggle, single-instance guard. Headless boot and DPI pending |
| 5. In-process DXGI â NVENC (drops ffmpeg and its pipe/parser delay) | done and default on NVIDIA; sustains 3024Ã1964@120 and verified stable in exclusive-fullscreen games (Valorant, FC 26) after enabling D3D11 multithread protection on the shared capture/encode device. `--no-native` falls back to ffmpeg |

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

# driver, settings file, firewall â needs an elevated PowerShell
.\tools\install-host.ps1
```

The script installs the driver, creates `C:\VirtualDisplayDriver\vdd_settings.xml`
(writable by your account), registers the elevated helper task, opens the
firewall, and leaves the driver device disabled. A session enables it and uses
whatever size the connecting Mac reports (its native pixels, or Â¾/Â½ of them with
the client's `--scale`); an unknown size is merged into the settings file first.
Nothing is tied to one MacBook.
`-Driver parsec` installs parsec-vdd instead; then the modes are fixed and come
from `-Resolutions "WxH@Hz",...`, five at most.

Then run:

```powershell
host\target\release\relay-host.exe            # serve (default): a tray icon, no window
host\target\release\relay-host.exe pin        # show the PIN (--new to change it)
host\target\release\relay-host.exe paired     # paired Macs (--forget <fingerprint>)
host\target\release\relay-host.exe gpus       # adapters and which one is used
host\target\release\relay-host.exe displays   # what Windows/DXGI see
host\target\release\relay-host.exe attach-test --width 3024 --height 1964 --hz 120
                                                      # full session dance for 10 s: your monitors go dark!
host\target\release\relay-host.exe restore    # put the displays back if something went wrong
host\target\release\relay-host.exe layout     # show the current layout (--reapply to test restore)
host\target\release\relay-host.exe --no-vdd   # dev: stream the primary monitor
```

Useful flags: `--gpu 4090` (substring of the adapter name; default is the
adapter with the most dedicated VRAM, i.e. the discrete card on a PC that also
has an iGPU), `--driver mtt|parsec|auto`, `--quality speed|balanced|quality` (speed is the low-latency default),
`--bitrate 200` (Mbps), `--codec h264`, `--fps 60`, `--intra-refresh` (NVIDIA),
`--no-native` (fall back to the ffmpeg capture path instead of the in-process
NVENC one), `--no-input`, `-v`.

The host has no window. Serving puts a Relay icon in the notification area; click it
for the status line (`Idle` or `Streaming to <Mac> â WxH @ Hz`), the pairing PIN
(click to copy), **New PIN**, **Start at login**, the list of paired Macs and **Quit Relay**. The PIN
changes by itself after every successful pairing, so a PIN only ever admits one Mac
(`--pin` pins it). Started from a terminal the log goes to that terminal; started by
the logon task or a double-click it goes to `%LOCALAPPDATA%\Relay\host.log`
(`host.log.1` is the previous one). The subcommands above print to the terminal but,
being a windowless program, return the prompt first. Quit, Ctrl-C and a logoff or
shutdown restore your displays and remove the
virtual monitor; if the host is killed, the helper task disables the virtual
monitor and Windows brings the physical ones back, and the next host start (or
`restore`) re-applies the saved layout.

**Start at login** (tray item, `relay-host autostart --on|--off|--status`, or the
installer's `-AutoStart`) registers a logon task for your user — no elevation —
that runs a copy of the exe from `%LOCALAPPDATA%Relayin` under a small supervisor,
so the host comes back within seconds if it crashes (Quit stays quit). Whenever you
run a newer build by hand, that copy is refreshed, so the last build you ran is the one
that starts at login. Launching a second host while one is running just shows a
"Relay is already running" box.

### macOS client

```sh
cd client
swift run Relay            # dev
./bundle.sh && open Relay.app   # proper .app (local-network permission prompt)
```

The app opens with a host list: PCs found over Bonjour, split into **Paired** and
**Available**, each with the link the connection will use. Hovering a PC shows a card with what it
advertises about itself â Windows edition and version, CPU, RAM (with DDR type and speed), GPU (with VRAM) â plus its address on each link this Mac
shares with it, labelled Ethernet, Wi-Fi or â when the wire had no DHCP and the PC self-assigned
a 169.254 address â Direct cable (a Tailscale address is never shown),
and its key fingerprint. For an available PC the button reads **Pair**: it
asks for the PIN (a sheet on the list), exchanges keys and moves the PC to
*Paired* â nothing is streamed yet. For a paired PC, Return, double-click or
**Connect** starts the session: progress shows in the list's footer, the button
reads *Cancel* until then, and the full-screen kiosk window appears with the
first decoded frame. When the session ends the list comes back with the
same host selected. In the footer a popup chooses the resolution â native,
75% or 50% of the panel the window is on (labelled in pixels) â and a segmented
control chooses 120 or 60 Hz (shown only where the panel supports both). The **Advanced**
button opens the options: keyboard mapping (â as Ctrl, or physical positions), whether
keyboard and mouse are sent to the PC, and the latency overlay. All of it is
remembered; the matching command-line flags override it for one launch. This
works on any Mac: the sizes and rates come from the screen at runtime.
Paired status comes from the host's advertised identity key
(`pk` in its Bonjour TXT record); a host that advertises no key, or an unknown
one, is listed as available. The pencil on a row **renames** the PC on this Mac (its
own name moves to the hover); the â on a paired PC (or Delete with it
selected) **forgets** it: the Mac tells the PC to
drop the pairing too, then removes it locally either way â if the PC was
unreachable the footer shows the `relay-host paired --forget <fingerprint>` command
to run on it.

Flags: `--host 169.254.x.y` (skip the list and Bonjour; re-dials on drops),
`--pin 123456` (otherwise a dialog asks the first time), `--scale 0.75`/`--max-fps 60`
(override the remembered mode for one launch; Â¾ or Â½ the pixels is softer on
the panel but much cheaper to encode â the gaming modes), `--modifiers physical`, `--no-input`,
and `--latency-stats` (live host/network/client estimate; toggle with ââ¥âL).
**ââ¥âQ leaves the stream** and returns to the host list (it quits in `--host`
mode, and from the list itself). By default â acts as Ctrl, â¥ as Alt and â as
Win so âC/âV behave like Mac shortcuts.

## Testing without a Mac

`host/src/bin/probe.rs` is a fake client:

```powershell
cargo run --bin probe -- --seconds 5 --out capture.hevc --wiggle
ffplay -f hevc capture.hevc
```

## Known limitations

- The in-process NVIDIA path is the default and is verified stable at
  3024Ã1964@120 in exclusive-fullscreen games (Valorant, FC 26). An earlier
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
- macOS keeps âTab, âSpace and the Fn media keys for itself; everything else is
  forwarded.
- Windows DPI scaling for the virtual monitor is a per-monitor setting Windows
  remembers; set it once in Settings â Display (200% for a Retina-native mode).
- Headless boot works once the host runs at logon; the BIOS and the login screen
  are not visible (a $20 HDMIâUSB capture dongle is still the answer for those).
- Pairing is PIN-based, not a PAKE: someone actively in the middle of the *first*
  pairing could brute-force the PIN. Pair on the cable or at home; afterwards the
  pinned keys make impersonation impossible, and hotel Wi-Fi is fine. Both sides
  keep their keys and pairings in `%LOCALAPPDATA%Relay` and
  `~/Library/Application Support/Relay`.
