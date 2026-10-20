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
  IddCx 1.10 (Windows 11 22H2 or later); without it Windows picks the GPU, and a
  session whose virtual monitor lands on another GPU than the encoding one is
  refused (capture and encode must share one adapter).
- **An NVIDIA GPU with NVENC** and a driver that supports NVENC API 12.1 or
  later. The host refuses to start without one: other adapters are listed but
  never selected, a NVIDIA model without NVENC fails the capability check, and
  an older driver gets an "update the NVIDIA driver" error.
  `relay-host encoder-caps` shows what the GPU can do.
- **Rust** with the MSVC toolchain, and the Visual Studio Build Tools with the
  Windows 11 SDK.
- Optional: **ffmpeg**, for `ffprobe` / `ffplay` on `probe --out` dumps. The host never runs it.
- An administrator account for the one-time install.

## Build and install

```powershell
winget install Rustlang.Rustup
winget install Gyan.FFmpeg   # optional: ffprobe for probe dumps
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
| `-Port <n>` | Port for the firewall rule. The service itself always listens on 8468. |

## Running

### As a service (normal use)

The **Relay** service runs as LocalSystem and keeps one worker process,
`relay-host worker`, running in the signed-in session, also as SYSTEM. That
combination is what lets the host:

- start at boot, before anyone signs in;
- capture and control the lock and login screens with an 8-bit source (a normal
  user process can't open them); a selected 10-bit session promotes capture to
  true 10-bit after sign-in without reconnecting;
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
| `gpus` | List GPUs and show which one would be used; non-NVIDIA adapters are marked. |
| `encoder-caps [--width 3024 --height 1964 --hz 120]` | The selected GPU's name, LUID, driver version and NVENC API version, its NVENC capability record (codecs, profiles, presets, input formats, limits), and Relay's real encoder configuration initialized for each codec, preset and picture option at that mode. Read-only: no capture and no display change, safe while the service runs. A pass is a capability, not a measured frame rate. |
| `displays` | List adapters, monitors, modes and the DXGI indices capture uses. |
| `layout [--reapply]` | Show the current display layout; `--reapply` re-applies it to test the restore path. |
| `restore` | Put the physical displays back after a crash left them off. |
| `attach-test [--width 3024 --height 1964 --hz 120 --seconds 10]` | Run a whole session's display changes with no client. **Your monitors go dark** for the duration. |

### Options for serving

| flag | default | meaning |
|---|---|---|
| `--gpu <name>` | the NVIDIA GPU with the most dedicated VRAM | NVIDIA GPU to render and encode on (case-insensitive substring of its name); a name that matches only other vendors is refused. |
| `--codec hevc\|h264` | `hevc` | Preferred codec; the Mac must support it too. |
| `--bitrate <Mbps>` | the Mac's request | Override the bitrate (1–1000, constant bitrate). |
| `--fps <n>` | display refresh | Force a frame rate. |
| `--gop <seconds>` | `2` | Keyframe interval. |
| `--quality speed\|balanced\|quality` | the Mac's choice, else `speed` | Override the Mac's encoder preset (NVENC P1 / P4 / P6); `speed` is the low-latency one. |
| `--intra-refresh` | off | NVIDIA: spread refresh over the GOP instead of keyframes. Measured slower, so off. |
| `--no-vdd` | | Stream the primary monitor; don't touch the driver or the layout. |
| `--no-lock-physical` | | Take physical monitors off the desktop but don't disable their devices. |
| `--no-input` | | Ignore keyboard and mouse input from the Mac. |
| `--pin <4–8 digits>` | stored PIN | Use this PIN and don't rotate it. |
| `--name <text>` | computer name | Name shown on the Mac. |
| `--port <n>` | `8468` | TCP port. |
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
bitrate choice and congestion detection, stream
splitting, the MTT settings-file rewriting, the layout snapshot format, input
coordinate mapping and the tray text, NVIDIA-only GPU selection, the NVENC
driver-version check (including that a refused driver leaves the DLL
unloaded), the capability record's checks, the session preflight and
post-attach revalidation, and the capture adapter/size check. Anything that
actually changes the displays needs the real machine; `encoder-caps` exercises
the NVENC calls on it without changing any.

### 10-bit SDR precision

The 10-bit toggle controls the virtual display (SDR10bit=true, HDRPlus=false)
and the whole capture path. Its original colour switches are journaled in
`%ProgramData%\Relay\vdd-colour.xml` before writing XML, restored after device
disable, and recovered on cleanup before the next session. GPU/mode merges
and unrelated XML are retained. Eight-bit and H.264 sessions select SDR10bit=false.

On this PC, DuplicateOutput1 returns BGRA8 even with a 10-bit SDR MTT display.
Ten-bit sessions therefore capture FP16 linear scRGB with Windows Graphics
Capture **including its cursor**, use a GPU sRGB OETF into R10G10B10A2, and
register slots as **ABGR10** (R is in the low 10 bits). DDA observes output
loss/recovery; classic duplication is sufficient if DuplicateOutput1 is
unsupported. DDA's pointer can already be baked into its BGRA8 desktop instead
of separately visible, so relying on its metadata while discarding those
pixels lost the pointer on the VDD. WGC owns cursor composition now, with no
second DDA overlay. The Default desktop remains FP16 without a BGRA8 conversion.
A SYSTEM worker starts a signed-in-user
`capture-source` process from the same binary, because WGC activation itself
requires that user's CaptureService (impersonation is insufficient). The local
pipe checks the exact child PID before duplicating only an RGB10 texture
handle; a keyed mutex transfers GPU ownership. Pixel data stays on the GPU,
and topology, input, NVENC and keys stay with SYSTEM.
The helper has no host-state or tray duties and dies with capture teardown.
With 10-bit selected, Winlogon (lock/login/UAC) uses the existing SYSTEM
DDA/BGRA8 cursor/composition/ARGB input path temporarily. The virtual display,
chroma, selected output depth, Main10/Rext profile and VUI stay fixed. On
Default, capture is recreated at true FP16/RGB10/ABGR10; locking recreates the
8-bit secure source. This happens within the same connection through normal
capture recovery and fresh parameter sets/keyframe. Preflight registers/maps
both input formats with the selected 10-bit output. Unknown desktops wait;
WGC failure on Default never permits an 8-bit downgrade. Ordinary 8-bit and
H.264 sessions keep their existing behavior. Actual secure-desktop transitions
and real-Mac continuity remain user checks in SESSION-HANDOFF.md.
Normal, masked and monochrome cursors
are supported; XOR uses integer operations on the destination's native codes.
Eight-bit sessions retain Desktop Duplication/BGRA8/ARGB. The capability record
requires FP16 shader load, RGB10 render/blend, WGC support and NVENC ABGR10;
preflight initializes, registers and maps the real input and creates the SDR
converter. HDR capture is refused rather than relabelled as SDR.

`precision.exe` displays a small native RGB10 window on an existing display,
reads actual captured and composed pixels, checks sub-8-bit ramps, range,
channel order and cursor operations, and optionally writes a production dump:

```powershell
host\target\release\precision.exe --dump host\target\precision-420.hevc
host\target\release\precision.exe --cursor-check --dump host\target\precision-cursor.hevc
host\target\release\precision.exe --full-color --dump host\target\precision-444.hevc
host\target\release\precision.exe --eight-bit --dump host\target\precision-8.hevc
host\target\release\precision.exe --h264 --dump host\target\precision-h264.h264
python tools/check-precision.py host/target/precision-420.hevc host/target/precision-444.hevc host/target/precision-8.hevc
```

This leaves the physical display's colour settings, DPI and layout alone.
An unchanged 8-bit connector can still yield precise native FP16 application
content; an 8-bit application does not gain new precision. Adjacent CSV files
record expected/source/composed patch samples. The Python tool needs ffmpeg /
ffprobe and compares decoded frame 10 at the same pixel centres; it reports
lossy errors in 10-bit RGB codes and validates SDR VUI. A texture format or a
Main10 SPS alone does not pass this diagnostic.

`--cursor-check` additionally samples the **actual Windows cursor** at two
positions against the known RGB10 image and checks the old position has no
trail. It briefly moves/restores the pointer and pumps the test window's
messages. `RELAY_TEST_FAULT=capture-broker relay-host capture-probe
--cursor-check --dump ...` exercises the shared-GPU helper; the negative
control `RELAY_TEST_FAULT=omit-wgc-cursor precision --cursor-check` must fail.
Keep these hooks off in normal use. An artificial overlay shape alone does
not prove WGC includes the real pointer.

With the service stopped, elevated `precision --virtual-display` adds a
1920×1080@60 VDD **alongside** the physical monitors and restores the snapshot
and colour settings afterwards. It never invokes the exclusive topology.
Exclusive sessions/recovery checks belong to the user; results and remaining
Mac/user checks are in [SESSION-HANDOFF.md](../SESSION-HANDOFF.md).

WGC frames carry SystemRelativeTime, not DXGI LastPresentTime. That timestamp
controls capture cadence, but `present_us` stays unknown for this source so
the Mac does not present it as a measured Desktop → screen latency. Receive →
screen, encode/work, transfer, clock sync and input timing remain available.

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
| `--codec h264\|hevc` | both | Offer only this codec. |
| `--quality fastest\|balanced\|best` | | Ask for an encoder preset (CLIENT_HELLO's picture-options extension). |
| `--444`, `--10bit` | | Ask for HEVC 4:4:4 / 10-bit. The extension goes only to a host whose SERVER_HELLO has capability `0x02`, and only when one of these three is given. |
| `--timing` | | Clock sync (capability `0x04`): TIME_REQUESTs as the Mac sends them, the offset once a second, and per frame present → submit → sent → received from FRAME_TIMING_EXT. With `--wiggle`, also input → applied. |
| `--progress` | | Print the frames received in each second. |

`--timing` ends with a summary: the offset at the lowest delay, how many
frames were fresh or re-encoded (`present_us` = `u64::MAX`), any fresh frame
with present > submit or submit > sent, p50 / p95 of each step, and (with
`--wiggle`) the inputs sent against the host's `inputs_applied`. On loopback
both clocks are the same QPC, so the offset should be within a few µs of 0:

```powershell
target\release\probe.exe --addr 127.0.0.1:18468 --timing --wiggle --seconds 8
```

The summary also prints STREAM_START's `video_format` and the host's PC work
(capture + encode + send) p50 / p95 from FRAME_TIMING, the same figure the
Mac's latency overlay shows. To check a picture option, dump and probe it:

```powershell
target\release\probe.exe --addr 127.0.0.1:18468 --444 --10bit --out x.hevc
ffprobe -v error -show_entries stream=profile,pix_fmt x.hevc   # Rext, yuv444p10le
```

A probe session takes the display like a real Mac does, so **your monitors go
dark** while it runs. Against a `--no-vdd` host it streams the primary monitor
instead.

Pair-only naming is in the host, the Mac app and the
[wire spec](../docs/PROTOCOL.md): the Mac sends its name with PAIR, bound into
CPace, so the tray shows it before the first stream. New unnamed pairings use “Paired
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
4. **Preflight.** Before any display changes: pick the codec (what the Mac
   offers, what this GPU's NVENC record can run, the host's preference), apply
   the picture options the GPU supports, check the requested size, rate and
   preset against the record, and initialize Relay's real encoder
   configuration at that size on the selected GPU and tear it down (about
   0.2 s). A refusal is `STREAM_STOP(ENCODER_FAILED)`; the reason is only in
   `host.log`.
5. **Set up the display.** Snapshot the layout to disk, enable the driver's
   device with its negotiated SDR depth, make the virtual monitor the only active display at the Mac's exact
   mode, and disable the physical monitors' devices so a fullscreen game can't
   bring them back. Then revalidate: the display must be on the selected GPU,
   and a mode other than the requested one is checked (and initialized) again.
   On failure the layout is restored before the Mac is told. Every capture
   start and restart also checks that Desktop Duplication opened the selected
   GPU's output at the session's size.
6. **Stream.** Capture and encode run on their own threads; a reader thread
   injects input with `SendInput`. The host pings every second, sends timing
   telemetry, and restarts capture for up to 15 s when a fullscreen switch
   invalidates it, without dropping the Mac. If the link can't sustain the
   chosen bitrate, the session ends with a reason that says so.
7. **Tear down.** Send `STREAM_STOP`, half-close and drain (so Windows doesn't
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
| [`driver/`](src/driver/) | The virtual display driver: [MTT](src/driver/mtt.rs) behind a small trait that tests stand in for |
| [`devnode.rs`](src/devnode.rs) | Enabling and disabling devices (CfgMgr32), physical monitor lock |
| [`topology.rs`](src/topology.rs) | Display layout snapshot, exclusive mode and restore (CCD API) |
| [`display.rs`](src/display.rs) | Monitors, modes, and mapping a display to its DXGI adapter and output |
| [`gpu.rs`](src/gpu.rs) | GPU enumeration; telling the real GPU from the driver's look-alike adapter; NVIDIA-only selection |
| [`nvenc_caps.rs`](src/nvenc_caps.rs) | The NVENC capability record and its checks (pure; filled by `native_nvenc::query_caps`) |
| [`native_nvenc.rs`](src/native_nvenc.rs) | In-process D3D11/NVENC capture, cadence, capability query, real input resource preflight |
| [`sdr_capture.rs`](src/native_nvenc/sdr_capture.rs) | WGC FP16 SDR capture and GPU conversion to RGB10 |
| [`precision.rs`](src/bin/precision.rs) | Native desktop pixel precision/cursor/dump diagnostic |
| [`cursor_overlay.rs`](src/cursor_overlay.rs) | Drawing the Windows cursor into the frame on the GPU |
| [`encoder.rs`](src/encoder.rs) | The session's encoder: native start with retirement wait and busy-output retry, failure classification, Annex-B splitting |
| [`nvenc_bindings/`](src/nvenc_bindings/) | NVENC API bindings, loaded at runtime (derived from `nvidia-video-codec-sdk`, MIT) |
| [`input.rs`](src/input.rs) | Mapping the Mac's pointer and HID key codes to `SendInput` |
| [`desktop.rs`](src/desktop.rs) | Binding capture and input threads to the active desktop (lock screen included) |
| [`tray.rs`](src/tray.rs), [`status.rs`](src/status.rs) | Tray icon and menu, and the state they show |
| [`bin/probe.rs`](src/bin/probe.rs), [`bin/browse.rs`](src/bin/browse.rs) | Test tools |

The tray icons in [`assets/`](assets/) (`relay-light.ico` for a light taskbar,
`relay-dark.ico` for a dark one, PNG images from 16 to 256 px; the host picks by
`SystemUsesLightTheme` and the size nearest `SM_CXSMICON`) are drawn by the Mac
client from the same glyph as its own icon. To regenerate them, on the Mac:
`cd client && swift run Relay --render-icons ../host/assets`, then commit both
files and rebuild the host.

## Troubleshooting

- **Monitors stayed dark after a crash.** Run `relay-host restore` (elevated).
  Rebooting also works: the virtual-only layout is never saved to Windows'
  display database, so Windows falls back to your normal layout.
- **The virtual display device shows Code 43.** Re-run `tools\install-host.ps1`.
  It disables the device, and the next session enables it fresh. Never use the
  MTT driver's own control pipe (`SETDISPLAYCOUNT`, `RELOAD_DRIVER`): on release
  25.7.23 it crashes the driver, and Windows gives up on it after five crashes.
- **Capture produces no frames.** Windows delivers nothing while the monitors are
  asleep. A Mac session handles this itself: it wakes the displays when it
  starts and, after 30 s without input, nudges them with a zero-distance mouse
  move so they stay on. That also keeps the screen saver and inactivity lock
  from starting while a Mac is connected. Other tools, such as `attach-test`,
  don't do this: move the mouse or press a key on the PC first.
- **The Mac doesn't see the PC.** Check that both firewall rules exist, then run
  `browse --seconds 5` to see what the PC is advertising. A host whose GPU
  check fails does not start at all: look for the reason at the end of
  `host.log`, or run `relay-host encoder-caps`.
- **"update the NVIDIA driver".** The driver supports an NVENC API older than
  12.1, which these bindings need. Any current NVIDIA driver does.
- **The Mac says the host stopped the stream (reason 1).** The PC refused or
  lost the encoder; `host.log` says which check failed. Preflight refusals
  happen before any display changes.
- **Windows calls the cable "Unidentified network".** That's expected: there is
  no DHCP on a direct cable, and Bonjour works over link-local addresses anyway.
- **Text is tiny on the Mac.** Windows remembers scaling per monitor. Set the
  virtual monitor to 200% once in Settings → Display.
- **Logs.** `%ProgramData%\Relay\host.log`, or the terminal for a dev run; add
  `-v` for more.

## Limitations

- NVIDIA only: AMD and Intel adapters are never selected, and there is no
  ffmpeg, AMF, Quick Sync or software encoder. A capture that will not start is
  retried by the session's recovery loop for up to 15 s, then the session ends
  with the layout restored.
- Capture and encode must be on the same adapter; there is no cross-adapter
  copy path any more.
- The encoder capability check is a capability, not a frame-rate promise:
  whether a mode sustains its rate is measured per session.
- STREAM_STOP carries a reason code, not text, so the Mac cannot show why the
  PC refused a session.
- The service can't pass options to its worker; it always runs with defaults.
- The exe has no file icon of its own yet (only the tray icon is drawn).
- The BIOS and anything before Windows starts are not visible.
