# NVIDIA-only host: failure/recovery gate (handoff step 5) — 2026-10-17

The gate for removing the ffmpeg, AMF/QSV/software and Parsec paths
(`docs/WINDOWS-PLATFORM-HANDOFF.md` steps 6–7). Nothing is removed until every
case below has a recorded result on the hardware.

## Build and machine

- Host source: `d1546a3` (phase A `9334c1e`…`4a8c5d6`, fault hooks `04ae0ff`,
  per-session GPU re-selection `d1546a3`). Release `relay-host.exe` SHA-256
  `C6757C14152795496BA766BFCA3882003C7299F2CF940BD83DD7A9A0AB7396D5` (every
  relink changes it; compare against the installed copy before a run).
- NVIDIA GeForce RTX 3080 Ti, LUID 0:122e1, driver 616.56 (32.0.16.1656),
  NVENC API 13.1; Windows 11 Pro 26200.9711. Displays: DISPLAY1 2560×1440@144
  (primary), DISPLAY2 1080×1920@120.
- Test hooks (dev host only, never the service): `RELAY_TEST_NVENC_DRIVER_API`
  (pretend driver version), `RELAY_TEST_FAULT=trial` (the driver refuses the
  trial initialization), `RELAY_TEST_FAULT=display-gpu` (the attached display
  reports another adapter, as on a hybrid laptop). Each logs a warning when used.

## What counts as evidence

Keep three kinds apart when reporting:

- **unit-tested**: `cargo test` (pure selection, record, preflight, revalidation,
  capture-check and session-GPU logic; no hardware);
- **probe-tested**: a dev host and `probe` on this PC, no Mac;
- **real-Mac**: the installed service and the Mac app over the cable.

## Agent-run cases (dev host, `--no-vdd`, probe) — pending

Service stopped, an elevated dev host on port 18468 streaming the primary
display, `probe` over loopback. None of these touch the virtual display driver
or the topology code. Results are recorded here after the run.

| case | what | expected |
|---|---|---|
| B01 | baseline, probe asks 1920×1080@60 | preflight trial at 1920×1080@60, "display runs at 2560x1440@144 … checked the encoder again", frames at about the display rate |
| B02 | Balanced + 4:4:4 + 10-bit | flags applied; ffprobe Rext yuv444p10le |
| B03 | H.264 only | ffprobe High |
| B04/B05 | Fastest / Best | STREAM_START quality byte 1 / 3 |
| B06 | codec mask 4 (nothing in common) | STREAM_STOP encoder failed, "no codec in common", no "woke displays" |
| B07 | 9000×9000 | STREAM_STOP encoder failed, size outside limits, no "woke displays" |
| B08 | second client while streaming | BUSY; the first stream continues |
| B09 | primary refresh 144 → 120 mid-session, then back | capture interrupted, restarts at the same size, recovers |
| B10 | primary resized to 1920×1080 for 6 s | restarts refused ("captured output is 1920x1080, the session is 2560x1440"), recovers once the size is back |
| B11 | primary resized for 21 s | session ends after the 15 s recovery limit with STREAM_STOP encoder failed |
| B12 | a desktop only SYSTEM may open, 12 s | "cannot be captured … waiting", then "desktop capturable again" and frames resume |
| B13 | `RELAY_TEST_FAULT=trial` | refused before any display change ("forced by RELAY_TEST_FAULT") |
| B14 | `RELAY_TEST_FAULT=display-gpu` | refused after attach: "the attached display failed revalidation (layout restored)" |
| B15 | `RELAY_TEST_NVENC_DRIVER_API=0xb1` | host refuses to start: "update the NVIDIA driver", exit code 1 |
| B16 | `--no-native` | ffmpeg session through the preflight; picture flags not applied |

## User-run exclusive-display cases

These black out the PC's monitors (and anything running on them) while a
session holds the virtual display. Run them with the build above installed:
from an elevated PowerShell at the repo root,
`./tools/install-host.ps1 -SkipDriver`, then check
`(Get-FileHash "$env:ProgramFiles\Relay\relay-host.exe").Hash` against the
release hash. Note the start time; `%ProgramData%\Relay\host.log` holds every
line quoted below. After **every** case check that both physical monitors come
back with the same primary, positions and refresh rates (DISPLAY1
2560×1440@144 primary, DISPLAY2 1080×1920@120 to its right).

Mac settings unless a case says otherwise: 3024×1964 @ 120 Hz, Balanced,
4:2:0 8-bit, bitrate Automatic (120 Mbps), latency HUD on, Control on.

### U1. Normal VDD session (real Mac)

1. Connect. Wait 30 s with something moving on the PC, then disconnect.
2. Expected in host.log, in this order: `encoder preflight: HEVC 3024x1964@120 P4
   initializes (… ms)`, `woke displays before session setup`, `display layout
   saved`, `virtual display … is the only display: 3024x1964@120`, **no**
   `checked the encoder again`, `capturing … HEVC 120 Mbps … preset balanced`,
   `native capture: … 3024x1964@120`, per-5 s `fps` lines, then on disconnect
   `display layout restored`.
3. Record: time from Connect to picture (the preflight adds about 0.2 s), the
   HUD's fps and PC work, and the session report. For comparison the
   2026-10-17 Balanced run delivered 102.1 fps with PC work 18.7 / 19.4 ms
   (`docs/LATENCY.md`); the full A/B is phase C's job, so one session is enough
   here.

### U2. Picture options (real Mac)

1. Turn on Full color (4:4:4) and 10-bit color; connect for 20 s; disconnect.
2. Expected: `capturing … HEVC 4:4:4 10-bit …`, `native capture: … 4:4:4 10-bit`,
   the HUD shows 4:4:4 10-bit; layout restored. Turn both off again afterwards.

### U3. Session reset: lock and unlock (real Mac)

1. While streaming, lock the PC (Win+L on the PC). Unlock from the Mac.
2. Disconnect while locked once; connect to the already-locked PC; unlock from
   the Mac; disconnect.
3. Expected: `capture interrupted`, then `capture recovered after …`, **no**
   `capture restart refused`; the login screen streams; layout restored each time.

### U4. GPU reset (real Mac)

1. In a terminal on the PC: `relay-host gpus` (note the LUID).
2. While streaming, press **Win+Ctrl+Shift+B** on the PC keyboard (Windows
   restarts the graphics driver; the screen flashes and beeps).
3. Record whether the stream resumes (within 15 s) or ends with "host stopped
   the stream (reason 1)", and whether a `capture restart refused` line appears.
4. Disconnect (if still streaming). Check the monitors and layout. Run
   `relay-host gpus` again: did the LUID change?
5. Connect again. If the LUID changed, host.log must show `… has LUID …, not …
   as at startup (the driver restarted or was updated); querying NVENC again`,
   and the session must stream normally. Disconnect.

### U5. Hybrid mismatch, simulated (dev host with the virtual display, probe)

This PC has one adapter, so the fault hook stands in for Windows rendering the
virtual display on an iGPU. The monitors go dark for a few seconds.

1. Elevated PowerShell at the repo root:
   ```powershell
   Stop-Service Relay
   $env:RELAY_TEST_FAULT = "display-gpu"
   Start-Process host\target\release\relay-host.exe "--port 18468 -v" -RedirectStandardError "$env:TEMP\u5.log" -NoNewWindow
   Start-Sleep 5
   host\target\release\probe.exe --addr 127.0.0.1:18468 --width 3024 --height 1964 --hz 120 --seconds 5
   ```
2. Expected: the monitors go dark briefly and come back by themselves; probe
   prints `STREAM_STOP: encoder failed`; `u5.log` has `RELAY_TEST_FAULT:
   injecting 'display-gpu'` and `the attached display failed revalidation
   (layout restored)` followed by `display layout restored`.
3. With the same host running, the mode check must refuse **before** the
   monitors are touched (they must not go dark):
   `host\target\release\probe.exe --addr 127.0.0.1:18468 --width 9000 --height 9000 --seconds 3`.
4. Clean up: `Get-Process relay-host | Where-Object Path -like "*target\release*" | Stop-Process`,
   `Remove-Item Env:RELAY_TEST_FAULT`, `Start-Service Relay`.

### U6. Worker crash during a session (real Mac)

1. While streaming, from an elevated PowerShell kill only the worker:
   ```powershell
   Get-CimInstance Win32_Process -Filter "name='relay-host.exe'" |
     Where-Object CommandLine -match ' worker' |
     ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
   ```
2. Expected: the Mac's session drops; host.log shows `worker exited with … ;
   restoring displays`, `next worker in 5 s`, then `worker started in session
   …`; the physical monitors come back; the Mac can connect again without a
   PIN.

## Report template

| case | date/time | result | notes (HUD fps, PC work, log lines, anything odd) |
|---|---|---|---|
| U1 | | | |
| U2 | | | |
| U3 | | | |
| U4 | | | LUID before/after: |
| U5 | | | |
| U6 | | | |

Known UI gap, by design for now: STREAM_STOP carries a reason code, not text,
so the Mac shows only "host stopped the stream (reason 1)" for every preflight
or encoder refusal; the reason is in host.log.
