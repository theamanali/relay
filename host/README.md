# Relay host (Windows)

The PC half of [Relay](../README.md): a Rust program that runs as a Windows
service, creates a virtual monitor the size of the connecting Mac's screen,
captures and encodes it on the GPU, and streams it over the encrypted protocol
in [docs/PROTOCOL.md](../docs/PROTOCOL.md). It also takes keyboard and mouse
input back from the Mac.

- [Requirements](#requirements)
- [Build and install](#build-and-install)
- [Running](#running)
- [Command reference](#command-reference)
- [Files](#files)
- [Testing](#testing)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

## Requirements

- **Windows 11, x64.** Pinning the virtual monitor to a specific GPU needs
  IddCx 1.10 (Windows 11 22H2 or later); without it Windows picks the GPU and
  the host copies frames to the encoder through system memory.
- **An NVIDIA GPU** for the in-process capture → NVENC path, which is the tested
  one. AMD (AMF), Intel (Quick Sync) and GPUs with no encoder go through
  `ffmpeg` and are untested.
- **Rust** with the MSVC toolchain, and the Visual Studio Build Tools with the
  Windows 11 SDK.
- **ffmpeg** on `PATH`, only for the fallback paths.
- An administrator account for the one-time install.

## Build and install

```powershell
winget install Rustlang.Rustup Gyan.FFmpeg
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621"

cd host
cargo build --release      # target\release\relay-host.exe, probe.exe, browse.exe
cd ..
```

Then, from the repo root in an **elevated** PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tools\install-host.ps1
```

The installer:

1. Installs the [MTT Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
   (release 25.7.23) and creates its settings file,
   `C:\VirtualDisplayDriver\vdd_settings.xml`, from
   [`tools/vdd_settings.template.xml`](../tools/vdd_settings.template.xml). The
   template already lists every Apple laptop panel at native, ¾ and ½ size; a
   size it doesn't list is added the first time a Mac asks for it.
2. Leaves the driver's device **disabled**, so no virtual monitor exists until a
   Mac connects.
3. Adds firewall rules for TCP 8468 (the host) and UDP 5353 (mDNS).
4. Copies `relay-host.exe` to `%ProgramFiles%\Relay`, moves any state from an
   older per-user install into `%ProgramData%\Relay`, and installs and starts the
   **Relay** service.

| option | what it does |
|---|---|
| `-SkipDriver` | Don't touch the driver; refresh the settings, firewall, exe and service. **Use this after every rebuild.** |
| `-Uninstall` | Remove the service and `%ProgramFiles%\Relay`. Keeps the driver and `%ProgramData%\Relay` (identity and pairings). |
| `-Driver parsec` | Install [parsec-vdd](https://github.com/nomi-san/parsec-vdd) instead (untested; no GPU choice, fixed modes). |
| `-Resolutions "WxH@Hz",…` | parsec only: up to five modes to register. |
| `-Port <n>` | Port for the firewall rule. The service itself always listens on 8468. |

## Running

### As a service (normal use)

The **Relay** service runs as LocalSystem and keeps one worker process,
`relay-host worker`, running in the signed-in session, also as SYSTEM. That
combination is what lets the host:

- start at boot, before anyone signs in;
- capture and control the lock and login screens (a normal user process can't
  open them);
- turn device nodes on and off without a separate elevated helper;
- restore your monitors if the worker crashes. The service then runs
  `relay-host restore` in the session and starts a new worker, after 5 s, or
  60 s if the last one died within 30 s.

The Relay service and its handling of the lock and login screens are
implemented; hardware verification is in progress.

Starting and stopping:

- `Stop-Service Relay` / `Start-Service Relay` from an elevated prompt.
- **Exit** in the tray stops the service, so nothing Relay is left running.
- Double-clicking `relay-host.exe` while the service is installed but stopped
  asks for elevation and starts the service.

The service always runs the host with default options. The flags under
[Command reference](#command-reference) apply to a dev run from a terminal.

### The tray icon

Once you're signed in, a Relay icon appears in the notification area. Hovering
shows `Relay: Idle` or `Relay: Streaming to <Mac>`. Clicking opens a menu that
follows the taskbar's light or dark theme:

| item | what it does |
|---|---|
| status line | Idle, or which Mac is streaming |
| **Disconnect** | While streaming: ends the session. The Mac shows "The PC ended the session". |
| **PIN: 123 456** | The pairing PIN; click to copy. |
| **Get new PIN** | Makes a new PIN. The menu stays open to show it. |
| **Forget paired MacBook ▸** | One entry per paired Mac; asks first. A Mac that is streaming is disconnected as not paired. The Mac notices within seconds (see [How it works](#how-it-works)). |
| **Start on system boot** | The service's start type: Automatic when checked, Manual when not. While unchecked, the service also stays stopped at sign-in. |
| **Exit** | Stops the service: displays restored, virtual monitor removed. |

The PIN changes by itself after every successful pairing, so a PIN only ever
admits one Mac, and it is never written to the log.

### A dev run from a terminal

```powershell
Stop-Service Relay                    # elevated; only one host can serve per session
host\target\release\relay-host.exe -v
```

A run from a terminal logs to that terminal, and Ctrl-C restores the displays.
`--no-vdd` streams the primary monitor without touching the driver or your
layout, which is the safe way to test the pipeline. A user-session host can't
capture the lock screen; the session just waits until the desktop is back.
Starting a second host shows a "Relay is already running" box.

## Command reference

### Subcommands

`relay-host` with no subcommand serves. The others:

| command | what it does |
|---|---|
| `pin [--new]` | Show the pairing PIN and this PC's fingerprint; `--new` makes a new PIN (elevated). |
| `paired [--forget <fingerprint>]` | List paired Macs, or forget one (elevated). A running host picks up the change within a second. |
| `service install` / `uninstall` / `start` | Manage the Relay service (elevated). `service run` is the service manager's entry point. |
| `gpus` | List GPUs and show which one would be used. |
| `displays` | List adapters, monitors, modes and the DXGI indices capture uses. |
| `layout [--reapply]` | Show the current display layout; `--reapply` re-applies it to test the restore path. |
| `restore` | Put the physical displays back after a crash left them off. |
| `attach-test [--width 3024 --height 1964 --hz 120 --seconds 10]` | Run a whole session's display changes with no client. **Your monitors go dark** for the duration. |

### Options for serving

| flag | default | meaning |
|---|---|---|
| `--gpu <name>` | most dedicated VRAM | GPU to render and encode on (case-insensitive substring of its name). |
| `--driver auto\|mtt\|parsec` | `auto` | Virtual display driver; `auto` means MTT if installed, else parsec-vdd. |
| `--codec hevc\|h264` | `hevc` | Preferred codec; the Mac must support it too. |
| `--bitrate <Mbps>` | the Mac's request | Override the bitrate (1–1000, constant bitrate). |
| `--fps <n>` | display refresh | Force a frame rate. |
| `--gop <seconds>` | `2` | Keyframe interval. |
| `--quality speed\|balanced\|quality` | `speed` | Encoder preset; `speed` is the low-latency one. |
| `--intra-refresh` | off | NVIDIA: spread refresh over the GOP instead of keyframes. Measured slower, so off. |
| `--no-native` | | Use the ffmpeg path instead of in-process NVENC. |
| `--no-vdd` | | Stream the primary monitor; don't touch the driver or the layout. |
| `--no-lock-physical` | | Take physical monitors off the desktop but don't disable their devices. |
| `--no-input` | | Ignore keyboard and mouse input from the Mac. |
| `--pin <4–8 digits>` | stored PIN | Use this PIN and don't rotate it. |
| `--name <text>` | computer name | Name shown on the Mac. |
| `--port <n>` | `8468` | TCP port. |
| `--ffmpeg <path>` | `ffmpeg` | ffmpeg executable for the fallback paths. |
| `-v`, `-vv`, `-vvv` | info | Debug and trace logging. |

## Files

| path | what |
|---|---|
| `%ProgramData%\Relay\identity.key` | This PC's long-term X25519 key. Readable by SYSTEM and Administrators only. |
| `%ProgramData%\Relay\paired-clients.txt` | Paired Macs: public key and name. |
| `%ProgramData%\Relay\pin.txt` | The current pairing PIN. |
| `%ProgramData%\Relay\display-snapshot.bin` | Your display layout, saved at the start of a session so a crash can be undone. |
| `%ProgramData%\Relay\physical-locked.txt` | Physical monitors a session disabled, for the same reason. |
| `%ProgramData%\Relay\host.log` | The log when there's no terminal; rotated to `host.log.1` at 5 MB. |
| `%ProgramData%\Relay\probe-identity.key` | The `probe` tool's identity. |
| `%ProgramFiles%\Relay\relay-host.exe` | The service's copy of the exe, so a rebuild never fights the running service. |
| `C:\VirtualDisplayDriver\vdd_settings.xml` | The MTT driver's settings: render GPU and modes. |

Everyone may read `%ProgramData%\Relay`, so `relay-host pin` and `paired` work
unelevated; changing them needs an elevated prompt or the tray.

## Testing

```powershell
cd host
cargo test
cargo clippy --all-targets
```

The unit tests cover the crypto (including the
[v4 test vector](../docs/PROTOCOL.md) the Mac client generated, the CPace
draft-21 vectors and the field arithmetic reference values), records and
pairing end to end, the pairing rate limit and digest, the display lease,
bitrate choice and congestion detection, the ffmpeg command lines and stream
splitting, the MTT settings-file rewriting, the layout snapshot format, input
coordinate mapping and the tray text. Anything that actually changes the
displays needs the real machine.

### `probe`: a fake Mac

`probe` runs the real handshake and session from the PC itself:

```powershell
target\release\probe.exe --seconds 5 --out capture.hevc --wiggle
ffplay -f hevc capture.hevc
```

| flag | default | meaning |
|---|---|---|
| `--addr <host:port>` | `127.0.0.1:8468` | Host to connect to. |
| `--width`, `--height`, `--hz` | 1920, 1080, 60 | Mode to ask for. |
| `--bitrate <Mbps>` | 120 | Bitrate to ask for. |
| `--seconds <n>` | 5 | How long to stay connected. |
| `--out <file>` | | Write the received stream as Annex-B for ffprobe/ffplay. |
| `--wiggle` | | Move the mouse while connected (tests input injection). |
| `--pin <digits>` | | Pair first if this probe isn't paired yet. |
| `--pair-only` / `--unpair` | | Pair and leave, or ask the host to forget this probe. |
| `--name <name>` | `probe` | Name sent in pairing when the host supports it, and in CLIENT_HELLO when streaming. |
| `--legacy-pair` | | Omit the pairing-name extension to test older v4 client behavior. |
| `--abandon-pair` | | With `--pin`: send `PAIR`, read `PAIR_REPLY` and leave without confirming, the way a Mac with the wrong PIN does. The host must count it as a failed PIN. |
| `--fresh-identity` | | Use a throwaway key instead of `probe-identity.key`. |

A probe session takes the display like a real Mac does, so **your monitors go
dark** while it runs. Against a `--no-vdd` host it streams the primary monitor
instead.

Pair-only name support is staged on the host; the Mac change and wire-spec update
are described in [PAIR-NAME-HANDOFF.md](PAIR-NAME-HANDOFF.md). The current Mac app
still sends its name only when it streams. New unnamed pairings use “Paired
MacBook” plus the fingerprint in the tray; named pairings save the name before
reporting success. The automated probe fixture tests this without touching the
installed service or any display.

### `browse`: what this PC advertises

Windows has no `dns-sd`, and its resolver doesn't answer mDNS TXT queries, so
`browse --seconds 5` prints every Relay announcement it hears, TXT record
included (`pk`, `pg`, `ip` and the PC facts). A re-advertisement shows up as a
second line.

## How it works

### One session

1. **Connect.** Each TCP connection gets its own thread, up to 8 at a time.
   Both sides run the Noise XX handshake and the host sends `SERVER_HELLO`,
   which says whether it knows the Mac.
2. **Pair or forget, if asked.** A new Mac proves the PIN with CPace inside the
   encrypted channel, and the PC proves it back (`PAIR`, `PAIR_REPLY`,
   `PAIR_CONFIRM`), so each attempt is one guess. Every attempt counts as a
   failure until the Mac's confirmation checks out; failures are rate-limited to
   5 per 10 minutes, and the PIN rotates after a success. `UNPAIR` forgets the
   Mac and closes. Neither touches the display, so they work while another Mac
   is streaming.
3. **Claim the display.** On `CLIENT_HELLO` the connection tries to claim the
   single display lease. If another Mac holds it, the answer is
   `STREAM_STOP(BUSY)`. A running session is never taken over.
4. **Set up the display.** Snapshot the layout to disk, enable the driver's
   device, make the virtual monitor the only active display at the Mac's exact
   mode, and disable the physical monitors' devices so a fullscreen game can't
   bring them back.
5. **Stream.** Capture and encode run on their own threads; a reader thread
   injects input with `SendInput`. The host pings every second, sends timing
   telemetry, and restarts capture for up to 15 s when a fullscreen switch
   invalidates it, without dropping the Mac. If the link can't sustain the
   chosen bitrate, the session ends with a reason that says so.
6. **Tear down.** Send `STREAM_STOP`, half-close and drain (so Windows doesn't
   reset the connection and lose the stop), then restore the layout, re-enable
   the physical monitors and disable the virtual one.

### Discovery

The host advertises `_relay._tcp` over mDNS with its identity key (`pk`), a
pairing digest (`pg`) and facts the Mac shows on hover (CPU, RAM, GPU, Windows
version, IPv4 addresses). The TXT record can't change after registration, so a
`readvertise` thread re-registers it when the pairing digest changes (checked
every second) or the IPv4 addresses do (every 5 seconds). That is how a Mac
learns within seconds that the tray forgot it.

### Source map

| file | responsibility |
|---|---|
| [`main.rs`](src/main.rs) | CLI, subcommands, serve startup, single-instance check, shutdown path |
| [`service.rs`](src/service.rs) | The Windows service: install, start type, the worker in the console session, crash restore |
| [`server.rs`](src/server.rs) | Accept loop, per-connection session, display lease, stream pump, re-advertising |
| [`crypto.rs`](src/crypto.rs) | Noise XX handshake (`snow`), records, the pairing exchange and rate limiter, paired list and digest |
| [`cpace.rs`](src/cpace.rs), [`field25519.rs`](src/field25519.rs) | CPace (draft-21) and the field arithmetic and Elligator 2 map under it |
| [`protocol.rs`](src/protocol.rs) | Message types and encoding |
| [`discovery.rs`](src/discovery.rs), [`sysinfo.rs`](src/sysinfo.rs) | mDNS advertisement and the PC facts in it |
| [`driver/`](src/driver/) | Virtual display backends: [MTT](src/driver/mtt.rs) (default) and [parsec-vdd](src/driver/parsec.rs) |
| [`devnode.rs`](src/devnode.rs) | Enabling and disabling devices (CfgMgr32), physical monitor lock |
| [`topology.rs`](src/topology.rs) | Display layout snapshot, exclusive mode and restore (CCD API) |
| [`display.rs`](src/display.rs) | Monitors, modes, and mapping a display to its DXGI adapter and output |
| [`gpu.rs`](src/gpu.rs) | GPU enumeration; telling the real GPU from the driver's look-alike adapter |
| [`native_nvenc.rs`](src/native_nvenc.rs) | In-process Desktop Duplication → D3D11 → NVENC, phase-locked capture timer |
| [`cursor_overlay.rs`](src/cursor_overlay.rs) | Drawing the Windows cursor into the frame on the GPU |
| [`encoder.rs`](src/encoder.rs) | One interface over the native path and the ffmpeg fallback |
| [`nvenc_bindings/`](src/nvenc_bindings/) | NVENC API bindings, loaded at runtime (derived from `nvidia-video-codec-sdk`, MIT) |
| [`input.rs`](src/input.rs) | Mapping the Mac's pointer and HID key codes to `SendInput` |
| [`desktop.rs`](src/desktop.rs) | Binding capture and input threads to the active desktop (lock screen included) |
| [`tray.rs`](src/tray.rs), [`status.rs`](src/status.rs) | Tray icon and menu, and the state they show |
| [`bin/probe.rs`](src/bin/probe.rs), [`bin/browse.rs`](src/bin/browse.rs) | Test tools |

The tray icons in [`assets/`](assets/) are drawn by the Mac client from the same
glyph as its own icon; see [assets/README.md](assets/README.md).

## Troubleshooting

- **Monitors stayed dark after a crash.** Run `relay-host restore` (elevated).
  Rebooting also works: the virtual-only layout is never saved to Windows'
  display database, so Windows falls back to your normal layout.
- **The virtual display device shows Code 43.** Re-run `tools\install-host.ps1`.
  It disables the device, and the next session enables it fresh. Never use the
  MTT driver's own control pipe (`SETDISPLAYCOUNT`, `RELOAD_DRIVER`): on release
  25.7.23 it crashes the driver, and Windows gives up on it after five crashes.
- **Capture produces no frames.** Windows delivers nothing while the monitors are
  asleep. Move the mouse or press a key on the PC first.
- **The Mac doesn't see the PC.** Check that both firewall rules exist, then run
  `browse --seconds 5` to see what the PC is advertising.
- **Windows calls the cable "Unidentified network".** That's expected: there is
  no DHCP on a direct cable, and Bonjour works over link-local addresses anyway.
- **Text is tiny on the Mac.** Windows remembers scaling per monitor. Set the
  virtual monitor to 200% once in Settings → Display.
- **Logs.** `%ProgramData%\Relay\host.log`, or the terminal for a dev run; add
  `-v` for more.

## Limitations

- AMD and Intel encoding through ffmpeg is implemented but untested. A GPU with
  no hardware encoder falls back to software x264/x265, which can't keep up at
  large sizes.
- parsec-vdd is untested, can't pin the render GPU and offers at most five fixed
  modes.
- The ffmpeg path streams a completely static screen at about 100 fps rather than
  120. That is duplicated frames, not lost ones.
- The service can't pass options to its worker; it always runs with defaults.
- The exe has no file icon of its own yet (only the tray icon is drawn).
- The BIOS and anything before Windows starts are not visible.
