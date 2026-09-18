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
| `client/Tools/fakehost.swift` | fake host in Swift (CryptoKit, real handshake); the way to test the client's connect/pair paths without a PC — busy, rate-limited, wrong PIN, accept | Mac (`swiftc`, advertise with `dns-sd -R`) |
| `tools/` | elevated installer (`install-host.ps1`), driver settings template, (no helper script any more: the service does the privileged work) | Windows |
| `docs/PROTOCOL.md` | the wire contract, including the handshake **test vector** | both — this is the source of truth |

Two sessions, one repo: the PC session owns `host/` + `tools/`, the Mac session owns
`client/`. Both work on `main`; commit small, push often, `git pull` before starting.
Protocol changes go host-first (verified with `probe` + tests), then the spec, then the
client. Never change `docs/PROTOCOL.md` and only one side.

## Status (2026-09-18)

- Milestones 0–3 and 5 done and verified on the real hardware: virtual display becomes
  the only display at the Mac's exact mode, layout restored on disconnect/Ctrl-C/hard
  kill, in-process DXGI → NVENC at 3024x1964@120 (stable in exclusive-fullscreen
  games), PIN pairing + encryption, real sessions over the cable from the Mac client
  (Metal presenter).
- Milestone 4 in progress: tray icon done; **the host is a Windows service now**
  (`host/src/service.rs`, 2026-09-18) so the lock and login screens stream and the PC
  can boot headless — verification on the real hardware pending (lock screen, login
  screen, reboot, crash restore, sign-out/in; the list is in the README status row).
  Still to do: DPI, installers/signing. Open measurement items live in
  `docs/HOST-LATENCY.md` and `docs/CLIENT-LATENCY.md` (Metal vs avsbdl numbers,
  `--scale 0.75`, mode changes).
- Protocol additions (2026-09-18, both halves done): connections run on their own scoped
  thread so `server.rs` answers a second connection at once — full handshake and
  SERVER_HELLO, then PAIR/UNPAIR remain available while only CLIENT_HELLO gets
  the atomic display lease or `STREAM_STOP` reason 6 `BUSY`; waiting for a PIN
  does not reserve the display and a running display session is never preempted;
  `PAIR_RESULT` is `u8 result` (1 paired, 0 wrong PIN, 2 rate-limited + `u16 seconds`
  to wait). Verified end-to-end on the PC and Mac: an unpaired Mac pairs while `probe`
  owns the display, its Connect gets BUSY without preempting `probe`, and it connects
  successfully after the probe releases the display. PAIR_RESULT paths were also
  verified on the Mac against `client/Tools/fakehost.swift`.
- The host is windowless (`windows_subsystem = "windows"`). `serve` = tray icon +
  `%ProgramData%\Relay\host.log`; from a terminal it attaches to that terminal instead
  (`AttachConsole`, with the inherited std handles put back so `> file` still works).
  Subcommands print after the prompt returns — a GUI process is not waited on.
- Tray (`host/src/tray.rs`): hidden **top-level** window, not `HWND_MESSAGE` — message-only
  windows never get `TaskbarCreated`, `WM_SETTINGCHANGE` or `WM_ENDSESSION`, all of which
  it relies on. Menu is built on each click from `status::HostStatus` (server writes,
  tray reads). The PIN rotates after every successful pairing and is never logged.
- The Relay service (`relay-host service run`, LocalSystem, session 0) spawns
  `relay-host worker` into the **console session as SYSTEM**: duplicate our token,
  `SetTokenInformation(TokenSessionId)` (needs SE_TCB — only LocalSystem has it),
  `CreateProcessAsUserW` on `winsta0\default`. Desktop Duplication and `SendInput` only
  work from a thread bound to the *input* desktop (`OpenInputDesktop` +
  `SetThreadDesktop`, `host/src/desktop.rs`); a user process may not open `Winlogon`,
  which is why a dev run gets `E_ACCESSDENIED` at the lock screen — the session then
  waits (`DesktopNotCapturable`) instead of falling back to ffmpeg, which fails the
  same way. Threads that own windows (the tray) can never bind. Worker exit 0 = down
  until the next `WTS_SESSION_LOGON`/`CONSOLE_CONNECT`; non-zero = service runs
  `restore` in-session and respawns (5 s / 60 s backoff). `Stop-Service` sets the
  `Global\Relay.quit.<session>` event the worker's tray loop waits on. At the login
  screen there is no Explorer: `NIM_ADD` fails, the icon arrives on `TaskbarCreated`.
  SCM's own recovery restarts a crashed *service*; Task Scheduler's
  `RestartOnFailure` never restarted a crashed process — that is why the logon-task
  design (2026-09-17) was replaced.
- State is `%ProgramData%\Relay` (SYSTEM has no meaningful `%LOCALAPPDATA%`): Users
  RX, `identity.key` SYSTEM/Admins only (`restrict_to_admins` after creation). The
  installer and the first run as a user migrate the old `%LOCALAPPDATA%\Relay`. So
  `pin --new` / `paired --forget` need an elevated prompt; the tray does them as SYSTEM.
  One serving host per session is enforced with the `Local\Relay.host` mutex + a
  message box (SYSTEM worker and a user dev run share session 1's namespace).
- Tray icons are `host/assets/relay-{light,dark}.ico`, embedded with `include_bytes!`
  and chosen by `SystemUsesLightTheme`. They are rendered **on the Mac** from the
  picker's glyph: `swift run Relay --render-icons ../host/assets` (done 2026-09-17;
  rerun after any change to `Glyphs.swift`).

## Running it

PC: `host\target\release\relay-host.exe` (installed as the `Relay` service; tray icon with the PIN and status; `pin`,
`paired`, `service install/uninstall`, `gpus`, `displays`, `layout`, `restore`, `attach-test` subcommands). Installer once, elevated:
`tools\install-host.ps1`. Mac: `swift run Relay` opens a picker listing hosts
found over Bonjour under *Paired* / *Available* plus a footer with a resolution popup (native/75%/50%
of the current screen), a 120/60 Hz segmented control and an Advanced popover (modifier
mapping, "Native keyboard and pointer control", latency HUD — `SessionPrefs`; the
control one is also PC ▸ Native Keyboard and Pointer Control / ⌃⌥⌘K, which mid-session goes through the
local event monitor, saves the pref, releases held keys when turning off, and flashes
"Controlling/Observing <PC>"), all remembered in UserDefaults and
overridden per launch by the equivalent flags; an available host gets a Pair button (PIN sheet,
then it moves to Paired without streaming); a paired host connects from within the picker
(footer status, Cancel button) and the kiosk window opens on the first decoded frame; a dropped session returns to the picker. A PC already in a session with another Mac
still allows Pair and forget because neither takes over the display. Connect gets
"The PC is in another session" at once and is not retried from the picker.
A rate-limited PIN reopens the sheet with "Too many wrong PINs. Try again in N min."
(minutes rounded up); a wrong one keeps "That PIN wasn't correct…". `--host` skips the picker and re-dials on
drops (every 5 s instead of 1 s after a busy answer). Other flags: `--pin`, `--max-fps`, `--scale`, `--modifiers`, `--no-input`,
`--latency-stats`, `--renderer`, `--metal-vsync`; ⌃⌥⌘Q returns to the picker (quits in
`--host` mode). A row's context menu has Connect (paired) or Pair (available) — the same `didChoose` as the footer button — then Rename, `Revert Name to “<PC name>”` while a nickname is set, and, when paired, a separator and Forget (Delete does the same); the menu items carry SF Symbols with no configuration so AppKit sizes them like Finder's. Rename edits in place like Finder: the name becomes a bezeled field with its text selected, sized to the text (measured — a truncating NSTextField has no intrinsic width), Return or any loss of focus commits, Escape restores, an emptied name means the PC's own. Forget removes
the pairing on both sides (UNPAIR message; `relay-host paired --forget <fp>` is the
host-only fallback) and rename stores a local nickname in `nicknames.txt`. Paired means the advertised key is in
`hosts.txt` — there is no name-based fallback. The menu bar (`MainMenu.swift`, built in
code) has the standard Relay/Edit/Window/Help menus plus **PC** in File's slot (the
selected row's Connect ⌘↩ / Pair, Rename ⌘R, Revert Name ⇧⌘R, Forget ⌘⌫, then the global Native
Keyboard and Pointer Control ⌃⌥⌘K checkmark, Close Window) and **View** = the picture
(Resolution submenu, 120/60 Hz checkmarks — the footer's mode, kept in sync — a Bitrate
submenu of presets rebuilt on open so an off-preset slider value appears checked in sorted
place, plus Custom… → Advanced, and Show Latency Stats); PC/View/Settings… actions are nil-targeted and validated by the
picker controller, so they disable themselves while the kiosk window is key, and
`StreamView.performKeyEquivalent` swallows ⌘-shortcuts before the menu bar sees them
during a session. Without a main menu ⌘Q/⌘W/⌘H and ⌘A/⌘C/⌘V in text fields do nothing.
AppKit's automatic items: "Close All" is paired with any `performClose:` item (Close
Window uses its own selector to avoid it) and "Enter Full Screen" is added to any View
menu unless `NSFullScreenMenuItemEverywhere` is false *before* `NSApplication.shared`
(`main.swift`, not the menu code).

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
  Code 43. The device node is the switch: the host enables/disables it in-process
  (`host/src/devnode.rs`, CfgMgr32 `CM_Disable_DevNode`/`CM_Enable_DevNode`, needs
  admin — the SYSTEM worker or an elevated prompt). The physical monitors a session
  disabled are listed in `%ProgramData%\Relay\physical-locked.txt` so `restore` can
  re-enable them after a crash. There is no `Restart-PnpDevice`; use Disable/Enable.
- The driver keeps one monitor whenever enabled (count 0 == 1), so "invisible when idle"
  means the device is **disabled** between sessions. Enabling takes ~2 s.
- `SetDisplayConfig(SDC_TOPOLOGY_SUPPLIED)` fails with ERROR_GEN_FAILURE (31) for a layout
  Windows has never stored. Attach the monitor normally first, read back its modes with
  `QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS)`, then apply a complete one-path config with
  `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES`. Never save the virtual-only layout
  to the database. The snapshot for restore lives in `%ProgramData%\Relay`.
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
- The mDNS TXT record is static once registered: `server.rs` re-registers the service
  when the host's IPv4 set changes (polled every 5 s) so the advertised `ip` facts follow
  a late 169.254 self-assignment or a switch↔cable move.
- **Unplugging the Mac's cable makes mDNSResponder purge the TXT, not the host.** It
  drops everything learned on the vanished interface; the PTR usually survives on Wi-Fi
  but the TXT (with `pk`) was cached on the cable alone and is not re-fetched until its
  TTL (measured 2026-09-18: 53 s TXT-less on Wi-Fi, until the cable came back). That
  looks exactly like a host's goodbye (TXT gone, PTR still there), so `HostListDebouncer`
  tells them apart by whether the result's interface set changed in the same update and
  carries the last key/facts forward. A picker row is re-rendered on every
  `NWPathMonitor` update too: a freshly plugged cable is seen by Bonjour (IPv6
  link-local) seconds before it has an IPv4, and Bonjour never fires for the latter.
- `StreamView.flagsChanged` decides press vs release from its own held-key record
  **and** the event's flags: the record alone tells left from right, but forwards the
  release of a modifier it never sent down (control turned on by ⌃⌥⌘K with ⌃⌥⌘ still
  held) as a press, which sticks on Windows.
- NSTextField ends editing (and sends its action) for *any* reason, including
  `makeFirstResponder` moving focus away. The in-place rename leans on that —
  Finder commits on focus loss too — and cancels only through Escape's
  `cancelOperation` + `abortEditing`. While the field editor is up, the footer's
  default button gives up its `\r` key equivalent or Return would Connect;
  `isBezeled = true` switches `drawsBackground` on and `false` does not switch it
  off; and `apply` commits an in-progress rename before any reload that touches
  its row (the delegate's own reload is dispatched async so it never runs inside
  that `apply`).
- **The PIN sheet belongs to one connection attempt.** Current hosts allow PAIR while
  the display is busy, but older hosts can send STREAM_STOP(BUSY) with the sheet up;
  the host's 120 s PAIR_TIMEOUT can also close the socket under a sheet left open. A
  PIN typed into either dead attempt goes nowhere. `AppDelegate.dismissPINPrompt` closes it from
  `connectionDidEnd` (`endSheet` in the picker, `abortModal` in `--host` mode with a
  flag so that abort is not read as the user's Cancel, which quits there).
- **A final STREAM_STOP must be half-closed and drained when client data can be in
  flight.** Closing with unread bytes can draw a Windows RST that discards the stop
  from the receive buffer (probe saw 10053, not the reason). BUSY is now a reply to
  CLIENT_HELLO, but the client becomes input-ready when it sends that hello, so the
  host still `shutdown(Write)`s and drains until close/timeout before returning.
- A session-less host in the same session as the SYSTEM worker cannot be run for
  tests (`Local\Relay.host` mutex): redeploy with `install-host.ps1 -SkipDriver`
  (elevated) and test against the service instead. The probe's persisted identity
  is paired with it since 2026-09-18 (`probe --unpair` removes it).
- ffmpeg-based capture (`ddagrab` → `hevc_nvenc`) paces a static screen at ~100 fps,
  not 120; that is frame duplication, not loss.
- Pairing is PIN-based, not a PAKE: pair on the cable or at home, never first-pair on
  hotel Wi-Fi. Keys/pairings: `%ProgramData%\Relay`,
  `~/Library/Application Support/Relay`.

## Conventions

- Rust: `anyhow` errors, `log` macros, no async (one thread per concern), Windows APIs via
  the `windows` 0.58 crate, keep clippy clean. Swift: AppKit + Network.framework +
  CryptoKit only, no third-party packages.
- Defaults are 120 Hz and the Mac's native pixel size; `--scale 0.75`/`0.5` are the
  cheaper same-aspect modes.
- Keep the README's status table honest; note anything verified on real hardware.
