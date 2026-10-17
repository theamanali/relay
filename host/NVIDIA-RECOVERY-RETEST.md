# NVIDIA-only host: failure/recovery gate (handoff step 5) — 2026-10-17

The gate for removing the ffmpeg, AMF/QSV/software and Parsec paths
(`docs/WINDOWS-PLATFORM-HANDOFF.md` steps 6–7). Nothing is removed until every
case below has a recorded result on the hardware.

## Build and machine

- Host source: `062d411` for the agent-run cases below (phase A
  `9334c1e`…`4a8c5d6`, fault hooks `04ae0ff`, per-session GPU re-selection
  `d1546a3`, refused-desktop fix `062d411`; release SHA-256 `D7C7F314…004345F9`).
  The user-run cases use `3e320af`, which only repairs em dashes in log
  strings and comments that a PowerShell rewrite had double-encoded: release
  SHA-256 `A3E248D313F6ED871C46B404B691034E6254574DFA2FF0F91A46E2A1518F1112`,
  installed with `install-host.ps1 -SkipDriver`. Every relink changes the
  hash; compare before a run.
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

## Agent-run cases (dev host, `--no-vdd`, probe): probe-tested, 2026-10-17

Service stopped, an elevated dev host on port 18468 streaming the primary
display (DISPLAY1, 2560×1440@144), `probe` over loopback at 120 Mbps, the
build above (B12 rerun on it after the fix below). None of these touch the
virtual display driver or the topology code. "No display was changed" means
the connection's log has no `woke displays` / `dev mode: streaming` line.
Every preflight logged two trials (requested 1920×1080@60, then the display's
2560×1440@144), about 180 ms each for HEVC and 65 ms for H.264.

| case | what | result |
|---|---|---|
| B01 | baseline | **pass**: STREAM_START 2560×1440@144 HEVC Fastest; 144 frames/s after the first second (133.6 fps over 8 s); PC work p50/p95 5.64/6.44 ms |
| B02 | Balanced + 4:4:4 + 10-bit | **pass**: format byte 0x0e; 124.0 fps; PC work 13.88/14.14 ms; ffprobe Rext yuv444p10le, bt709/bt709/smpte170m, decodes clean |
| B03 | H.264 only | **pass with a finding**: codec 1, ffprobe High yuv420p, decodes clean; but native start failed and ffmpeg h264_nvenc took over (finding 2); colour description reads bt470bg/sRGB (finding 5) |
| B04 | Fastest | **pass**: 0x01; 119.2 fps over 3 s; PC work 3.03/3.17 ms |
| B05 | Best | **pass**: 0x03; 114.7 fps; PC work 14.38/14.71 ms |
| B06 | codec mask 4 | **pass**: STREAM_STOP encoder failed; "no codec in common: the Mac offers nothing Relay knows, this GPU encodes HEVC and H.264"; no display changed |
| B07 | 9000×9000 | **pass**: STREAM_STOP encoder failed; "HEVC cannot encode 9000x9000@60: 9000x9000 is outside 129x33 to 8192x8192"; no display changed |
| B08 | second client while streaming | **pass**: BUSY; the owner kept 144 frames/s |
| B09 | refresh 144 → 120 → 144 mid-session | **pass**: two access losses, each "capture recovered after 1.1s and 1 encoder restart(s)" |
| B10 | resized to 1920×1080 for 6 s | **pass**: every restart refused ("captured output is 1920x1080, the session is 2560x1440"); recovered 6.8 s after the loss, once the size was back |
| B11 | resized for 21 s | **pass**: restarts refused, then "capture did not recover within 15s", STREAM_STOP encoder failed |
| B12 | a desktop only SYSTEM may open, 20 s | **pass after a fix** (finding 1): "the ? desktop cannot be captured (PC locked, or not running as the Relay service); waiting", no timeout across 20 s, "desktop capturable again (Default)", 144 frames/s again |
| B13 | `RELAY_TEST_FAULT=trial` | **pass**: "session preflight refused the stream (no display was changed): NVENC on NVIDIA GeForce RTX 3080 Ti refused HEVC 1920x1080@60: NvEncInitializeEncoder failed (forced …)" |
| B14 | `RELAY_TEST_FAULT=display-gpu` | **pass**: refused after attach, "the display is not on the selected GPU … (LUID 0:fffedd1e instead of 0:122e1)"; dev mode has no layout to restore, see U5 for the VDD rollback |
| host D | `RELAY_TEST_NVENC_DRIVER_API=0xb1` | **pass**: the host refused to start, exit code 1: "the NVIDIA driver supports NVENC API 11.1, Relay needs 12.1: update the NVIDIA driver" |
| B15 | `--no-native` | **pass**: ffmpeg hevc_nvenc session through the preflight, 92.5 fps (the known ~100 fps static-screen pacing) |
| B16 | `--no-native` + 4:4:4 | **pass**: "not applying the client's 4:4:4 request: the ffmpeg path (--no-native) encodes 8-bit 4:2:0" |

### Findings

1. **Fixed (`062d411`), predates phase A.** `is_desktop_not_capturable` never
   matched: `Encoder::spawn` attaches the marker with `.context()`, which is
   not a chain item of its own type. On a desktop the process may not capture
   (the lock screen, for a non-SYSTEM host) restarts fell into the generic
   branch, the desktop wait never started and the 15 s recovery limit ended the
   session. The first B12 run (12 s) survived only because 12 < 15; after the
   fix the 20 s run waited and recovered. The SYSTEM worker can capture the lock
   screen, which is why the service never showed it.
2. **Open, a phase C requirement.** B03's native start failed with
   `IDXGIOutput1::DuplicateOutput: The parameter is incorrect (0x80070057)`. It
   began 1.5 s after the 4:4:4 10-bit session ended, whose capture is retired
   on a detached thread. A throwaway in-process test confirmed the cause: a
   second `DuplicateOutput` on an output the same process already duplicates
   fails with exactly this error, and succeeds once the first is gone. Today
   ffmpeg masks it. Without ffmpeg it would be a failed session, so phase C's
   native retry must wait (bounded) for the previous capture's retirement and
   retry this error before giving up. The same race exists for in-session
   restarts, where the recovery loop already retries.
3. A session ends about 0.1 s after its client closes; a client that
   reconnects within that window gets BUSY. Harmless for the Mac; the first
   run's script reconnected after 40 ms and had to be redone with a pause.
4. Cosmetic: the waiting line names an inaccessible desktop `?`; while the
   desktop waits, pings go out about every 3 s (under the 5 s pong timeout);
   `probe --progress` attributes the first frames after a silence to the
   catch-up lines.
5. Separate task, not introduced here: the native H.264 stream's colour
   description reads bt470bg/sRGB where HEVC reads smpte170m/bt709 from the
   same `signal_colour`. (The background task traced B03's tags to the ffmpeg
   fallback that encoded it; see its branch.)
6. Open, not introduced here (U6): after a killed worker the Mac's picker
   lost the PC and did not find the new worker's announcements until Relay
   was reopened. A worker that dies sends no mDNS goodbye; a dial during the
   5 s respawn gap fails and the Mac reconfirms (flushes) the record, and its
   continuous browse then queries again only on its own backoff. Candidates:
   the host re-announcing a few times after a respawn, or the Mac restarting
   its browse after a failed dial. A real crash would leave the user in the
   same state.

## User-run exclusive-display cases

These black out the PC's monitors (and anything running on them) while a
session holds the virtual display. The build above is already installed; if
anything was rebuilt since, reinstall from an elevated PowerShell at the repo
root with `./tools/install-host.ps1 -SkipDriver`, then check
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
3. Reconnect within a second or two of the disconnect, stream 10 s, disconnect.
   Record whether host.log shows `native NVENC startup failed
   (IDXGIOutput1::DuplicateOutput: The parameter is incorrect …); falling back
   to ffmpeg` for that session (finding 2). If it does, the HUD shows no PC
   work for that session.
4. Record: time from Connect to picture (the preflight adds about 0.2 s), the
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
| U1 | 2026-10-17 21:50–21:56 UTC | **pass (path)**, run with 4:4:4 + 10-bit still on | Two real-Mac sessions on the installed `3e320af`. Each: `encoder preflight: HEVC 3024x1964@120 P4 initializes` (194 / 202 ms), wake, layout saved, `virtual display \\.\DISPLAY37`/`38` `is the only display: 3024x1964@120` on the RTX (no re-check: the mode matched), native capture `4:4:4 10-bit, preset balanced`, about 95.5 fps with encode about 20.7 ms (mostly static desktop: 0–300 of 600 frames fresh), `display layout restored` on each disconnect; the user confirmed the monitors. The second connect came 3 s after the first ended and started native capture (finding 2 not reproduced at 3 s). Still to do: one session with the picture options off (4:2:0 8-bit) |
| U2 | 2026-10-17 21:50–21:56 UTC | **pass**, via the U1 sessions | CLIENT_HELLO flags 0b11 applied: `capturing … HEVC 4:4:4 10-bit 120 Mbps, preset balanced`; layout restored |
| U3 | 2026-10-17 21:59–22:01 UTC | **pass** | Session 1: `SessionLock` → access lost → `capture recovered after 1.1s` (twice: lock, then a second desktop transition), `SessionUnlock` from the Mac → recovered 1.1 s, lock again → recovered 1.1 s, disconnect while locked → `physical monitor devices restored`, `display layout restored`. Session 2 connected to the still-locked PC: preflight, exact-mode virtual display, lock-screen capture, unlock from the Mac → recovered 1.1 s, disconnect → restored. No `capture restart refused`, no `cannot be captured`, no ffmpeg fallback (the SYSTEM worker captures the lock screen). The GDI names of the two physical monitors swapped between the sessions (`DISPLAY2 (ACR0692)` in session 2's snapshot); restore follows the saved paths, not the names. Session 2 ended with a 10053 send error after the restore (the Mac closed first). Still 4:4:4 10-bit Balanced |
| U4 | | | LUID before/after: |
| U5 | | | |
| U6 | 2026-10-17 22:05–22:06 UTC | **pass** (reconnect not yet in the log) | Session through the preflight as before. Opening the elevated PowerShell (UAC's secure desktop) cost two access losses at 22:05:42 and :44, each `recovered after 1.1s`. The kill: `worker exited with 0xffffffff after 1468 s; restoring displays`, `MTT VDD: physical monitor devices restored`, `restoring the display layout saved by an earlier session`, `display layout restored`, `next worker in 5 s`, a new worker 5 s later (NVENC queried again, `listening`). The user confirmed the monitors. Afterwards the Mac's picker did not show the PC although the new worker was advertising (the PC's `browse` saw it on Ethernet); quitting and reopening Relay on the Mac brought it back (finding 6) |

Known UI gap, by design for now: STREAM_STOP carries a reason code, not text,
so the Mac shows only "host stopped the stream (reason 1)" for every preflight
or encoder refusal; the reason is in host.log.
