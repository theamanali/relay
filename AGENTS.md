# Relay — working notes for coding agents (read on every machine)

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
| `host/src/bin/browse.rs` | prints what Relay hosts advertise over mDNS, TXT included (`browse --seconds 5`); Windows has no `dns-sd` and its resolver does not answer mDNS TXT | Windows |
| `client/` | Swift package, macOS 13+: Bonjour, handshake/pairing, VideoToolbox decode, kiosk window, input | **Mac only** (`swift build`, `swift run Relay`, `./bundle.sh` for a .app) |
| `client/Tools/fakehost.swift` | fake host in Swift (CryptoKit, real handshake); the way to test the client's connect/pair paths without a PC — busy, rate-limited, wrong PIN, accept | Mac (`swiftc`, advertise with `dns-sd -R`) |
| `tools/` | elevated installer (`install-host.ps1`), driver settings template | Windows |
| `docs/PROTOCOL.md` | the wire contract, including the handshake **test vector** | both — this is the source of truth |

Two sessions, one repo: the PC session owns `host/` + `tools/`, the Mac session owns
`client/`. Both work on `main`; commit small, push often, `git pull` before starting.
Protocol changes go host-first (verified with `probe` + tests), then the spec, then the
client. Never change `docs/PROTOCOL.md` and only one side.

## Status

- Milestones 0–3 and 5 are done and verified on the real hardware: the virtual display becomes
  the only display at the Mac's exact mode, layout is restored on disconnect/Ctrl-C/hard kill,
  in-process DXGI → NVENC runs at 3024x1964@120, PIN pairing + encryption, real sessions over
  the cable from the Mac client (Metal presenter).
- Milestone 4 is in progress: tray icon and Windows service are done; real-hardware
  verification of the service is pending (lock screen, login screen, reboot, crash restore,
  sign-out/in). Still to do: DPI, installers/signing. Latency measurements, what was
  rejected and what is still open: `docs/LATENCY.md`.
- Protocol v4 (2026-10-08): Noise XX handshake, CPace PIN pairing and chunked records
  (`docs/PROTOCOL.md`). Host and spec are done (`crypto.rs`, `cpace.rs`, `field25519.rs`; the
  v4 test vector matches line for line); the Mac side's building blocks are in but not wired
  in. Until they are, the current Mac app cannot connect to an updated PC: `host.log` says
  "the Mac app speaks the v2 handshake; update it".
- The README status table is the source of truth for status; keep it current.

## How the host and client work (details you need before changing them)

- The host is windowless (`windows_subsystem = "windows"`). `serve` = tray icon +
  `%ProgramData%\Relay\host.log`; from a terminal it attaches to that terminal instead
  (`AttachConsole`, with the inherited std handles put back so `> file` still works).
  Subcommands print after the prompt returns — a GUI process is not waited on.
- Tray (`host/src/tray.rs`): hidden **top-level** window, not `HWND_MESSAGE` — message-only
  windows never get `TaskbarCreated`, `WM_SETTINGCHANGE` or `WM_ENDSESSION`, all of which
  it relies on. Menu is built on each click from `status::HostStatus` (server writes,
  tray reads): status line, `Disconnect` while streaming, separator, `PIN: 123 456` (copies),
  `Get new PIN` (the menu **stays open**: a Win32 popup closes on any choice, so a
  `WH_MSGFILTER` hook on the tray thread swallows that item's click/Return, rotates the PIN
  and `ModifyMenuW`s the open item; the `#32768` popup window does not repaint on its own,
  `InvalidateRect` it), `Forget paired MacBook ▸` (one id per entry, Yes/No `MessageBoxW`,
  `PeerList::remove`), `Start on system boot` checkbox, `Exit` (2026-09-19). The PIN
  rotates after every successful pairing and is never logged. The tooltip follows the
  session (1 s timer, `NIM_MODIFY` only when the text changes; `szTip` is 127 units, the
  client name is clamped). The tray ends a session by storing a `stop_reason` in
  `SessionInfo::end_request` (`AtomicU8`, `NO_END_REQUEST` = none); `pump` polls it at its
  stop checks, sends the STREAM_STOP, half-closes and lets the reader drain for up to 2 s
  (the RST rule below). Disconnect = reason 0 (the Mac already shows "The PC ended the
  session"), Forget of the streaming Mac = reason 4. **Dark menu:** Win32 popup menus
  are light unless the process calls uxtheme's undocumented ordinal 135
  `SetPreferredAppMode` (2 = ForceDark, 3 = ForceLight; on 1809 that ordinal is a
  different function, so gated on build ≥ 18362) and 136 `FlushMenuThemes`; done at
  start and on `ImmersiveColorSet`, following the taskbar theme like the icon.
  MessageBox stays light. **Exit** = `ControlService(STOP)` on the Relay service from the
  worker (SYSTEM may); the service's stop path sets the quit event and the tray loop
  quits as before — nothing Relay is left running. **Start on system boot** =
  `QueryServiceConfigW`/`ChangeServiceConfigW` start type with `SERVICE_NO_CHANGE`
  (`windows_service::change_config` would rewrite the binary path); while it is off the
  service also skips the `SessionLogon`/`ConsoleConnect` respawn, `Start-Service Relay`
  is the manual way in, and so is a **double-click on the exe**:
  `main.rs::hand_off_to_service` — no console, no `--no-vdd`, service installed but stopped
  → relaunch elevated as `relay-host service start` (`ShellExecuteW runas`;
  `service::start`) and exit, instead of a user-session dev run. From a terminal a dev run
  still happens (that is how `Stop-Service Relay` + `relay-host` is used). Greyed in a dev
  run (`under_service` = the quit event exists).
- **Pairing digest `pg` in the TXT record (host + spec done 2026-09-20; Mac side done
  2026-09-19).** `PeerList::digest()` = first 4 bytes of SHA-256 over `DIGEST_LABEL` + the
  sorted paired keys (the label keeps a lone client's digest from being its fingerprint),
  hex; renames do not move it. The `readvertise` thread in `server.rs` ticks every
  second: `PeerList::reload_if_changed()` (mtime; picks up `relay-host paired --forget`
  from another process, which the running host used to overwrite on its next save),
  then re-registers the record when the digest or (every 5th tick) the IPv4 set moved.
  A tray Forget is on the air in about 1.5 s. Mac side: `DiscoveredHost.pairingDigest`
  (carried forward by `HostListDebouncer` on a TXT-less report like `pk`, and not part of
  `PickerRows.Appearance`, so a digest change alone redraws nothing);
  `verified-digests.txt` next to `hosts.txt` holds the last digest the handshake
  confirmed per host key (cleared by `ClientState.forget`). `AppDelegate.checkPairings`
  (on every browse update, at launch, and after a session, cancel, forget or check
  ends) picks the next known host whose advertised digest is neither verified nor
  already attempted this run (`PairingVerifier`, pure; one attempt per digest value so
  an unreachable host is not re-dialled on every update) and runs one `VerifyTask`
  (`HostConnection.verifyOnly`: msg1, msg2, read `paired`, close; never CLIENT_HELLO, so
  it never touches the display or another Mac's session). `paired` 1 stores the digest;
  0 forgets the host locally, reloads the picker and flashes "PC forgot this MacBook".
  Checks only run while no connection or unpair is in flight, one host at a time, and
  an answer that lands after a Connect/Pair/Forget started is dropped (`retract`).
  Same outcome from a plain Connect whose handshake says `paired` 0 for a known host
  (`HostConnection` forgets it itself, next to where it `remember`s; an explicit Pair
  still gets the PIN sheet) and from STREAM_STOP 4 mid-session; `--host` mode forgets
  and the re-dial then asks for the PIN as for an unknown host. Verified 2026-09-19 against
  `fakehost --forget` / `--pg` / `notpaired`
  (all four paths) and on the hardware over the cable: the launch-time check stored the
  PC's digest, a tray Forget on the PC moved the row to Available within seconds with
  nothing touched on the Mac, and Pair from the picker brought it back (same digest as
  before, since the PC's list held the same one key). Each check shows up in `host.log` as
  `connection with … ended with
  error: waiting for the first message` (the client hangs up after SERVER_HELLO);
  a quieter line is the host's to add. Spec: PROTOCOL.md Discovery + Forgetting.
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
  `pin --new` / `paired --forget` need an elevated prompt; the tray does both as SYSTEM
  (`Get new PIN`, `Forget paired MacBook`).
  One serving host per session is enforced with the `Local\Relay.host` mutex + a
  message box (SYSTEM worker and a user dev run share session 1's namespace).
- Tray icons are `host/assets/relay-{light,dark}.ico`, embedded with `include_bytes!`
  and chosen by `SystemUsesLightTheme`. They are rendered **on the Mac** from the
  picker's glyph: `swift run Relay --render-icons ../host/assets` (done 2026-09-17;
  rerun after any change to `Glyphs.swift`). The Mac app icon is the same glyph:
  `swift run Relay --render-app-icon Assets` writes `client/Assets/AppIcon.icon` (an
  Icon Composer document — blue fill + the glyph as a 1024 px layer — that `bundle.sh`
  compiles with Xcode's `actool` into `Assets.car`; **the system renders the light, dark,
  clear and tinted appearances from it**, which is the only way a macOS icon gets a dark
  mode: an `.icns` has no appearance slot and an asset catalog silently drops dark
  variants for macOS icons) plus `Relay.icns`, the same drawing flattened, used when
  actool is missing and as `applicationIconImage` for a bundle-less `swift run`. Both
  are checked in. `bundle.sh` also stamps `CFBundleVersion` with the commit count, so
  About says "0.1.0 (134)".
  About Relay is the standard panel plus the repo link as credits; copyright is
  `NSHumanReadableCopyright`. Licence: MIT (`LICENSE`, `host/Cargo.toml`).

## Running it

PC: `host\target\release\relay-host.exe`, installed as the `Relay` service with a tray icon;
subcommands `pin`, `paired`, `service install/uninstall`, `gpus`, `displays`, `layout`,
`restore`, `attach-test`. Installer once, elevated: `tools\install-host.ps1`. See
`host/README.md`.

Mac: `swift run Relay` opens the picker; flags are in `client/README.md` (or `--help`).
User-visible behaviour (pairing, connect, rename, forget, menus, shortcuts, settings) is
documented there. What follows is only the mechanics that are easy to break:

- Control / Observe is PC ▸ Control / Observe. Mid-session it goes through the local event
  monitor, saves the pref, releases held keys when turning off, and flashes
  "Controlling/Observing <PC>". ⌃⌥⌘K sits on whichever item is not current, so it always
  switches.
- A dropped session returns to the picker; the kiosk window opens on the first decoded frame.
- Rename edits in place like Finder: the name becomes a bezeled field with its text selected,
  sized to the text (measured; a truncating NSTextField has no intrinsic width). Return or
  any loss of focus commits, Escape restores, an empty name means the PC's own.
- Row context-menu items carry SF Symbols with no configuration so AppKit sizes them like
  Finder's.
- The menu bar is built in code (`MainMenu.swift`): Relay/Edit/Window/Help plus **PC** in
  File's slot and **View**. The Refresh Rate submenu is hidden on a one-rate panel; the
  Bitrate submenu is rebuilt on open so an off-preset slider value appears checked in sorted
  place. PC/View/Settings… actions are nil-targeted and validated by the picker controller, so
  they disable themselves while the kiosk window is key, and
  `StreamView.performKeyEquivalent` swallows ⌘-shortcuts before the menu bar sees them during
  a session. Without a main menu ⌘Q/⌘W/⌘H and ⌘A/⌘C/⌘V in text fields do nothing.
- AppKit's automatic items: "Close All" is paired with any `performClose:` item (Close Window
  uses its own selector to avoid it) and "Enter Full Screen" is added to any View menu unless
  `NSFullScreenMenuItemEverywhere` is false *before* `NSApplication.shared` (`main.swift`, not
  the menu code).

## Hard-won facts — do not relearn these

- **Renamed from TravelDisplay to Relay (2026-09-16).** Every user-visible name and identifier
  changed except the HKDF info string and the `TDH2` handshake magic, which stayed so pairings
  survived; protocol v4 replaced both (2026-10-08) and keeps the identity keys, so pairings
  survive it too. State directories move from the old name automatically on first run;
  re-run the installer once on the PC (it removes the old task and firewall names). The GitHub repo is
  `theamanali/relay`; a local clone directory may still be called `travel-display`.
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
  **black out the PC's monitors** (and any agent app running on it) for the duration. Use
  `--no-vdd` for pipeline tests; let the user run the exclusive ones.
- The mDNS TXT record is static once registered: `server.rs` re-registers the service
  when the host's IPv4 set changes (polled every 5 s) so the advertised `ip` facts follow
  a late 169.254 self-assignment or a switch↔cable move, and when the pairing digest
  `pg` changes (polled every 1 s).
- **A PC that vanishes without a goodbye stays in Bonjour's cache until its TTL runs
  out.** `mdns-sd` announces SRV/A with a 120 s TTL (PTR/TXT 75 min; the setters are
  `pub(crate)`, even in 0.21, so the host cannot shorten them); mDNSResponder re-queries at
  80-95 % of the TTL and, unanswered, flushes the SRV and then reconfirms the PTR, so the
  row lives 24-120 s after a cable pull (measured 2026-09-20). A dial to such a row never
  ends on its own (Network.framework only times out a SYN it has sent; the connection sits
  preparing/waiting), so picker attempts carry `HostConnection.Options.dialTimeout`
  (`AppDelegate.pickerDialTimeout`, 12 s, one deadline for the pinned attempt and its
  unpinned retry; --host mode has none) and end "couldn't reach the PC"; when the attempt
  never reached `.ready` (`everConnected`), `BonjourReconfirm.reconfirm(host)` sends
  `DNSServiceReconfirmRecord` for the PTR (rdata = the instance's full name in wire
  format) on every interface the host was seen on. mDNSResponder re-queries and flushes it
  ~7 s later; the browse drops the row. Verified on the hardware: Pair on the unplugged
  PC's row, footer at 12.6 s, PTR gone at +7 s. A record this Mac registered itself
  (`dns-sd -P` proxies, `fakehost`) never flushes: this Mac answers its own re-query.
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
- Pairing is CPace (a PAKE) inside the Noise channel since v4: someone in the middle gets one
  online guess per attempt, nothing to test offline, and the PC proves the PIN back. The
  host counts every attempt as a failure until PAIR_CONFIRM checks out (`PairLimiter::
  undo_failure`), so a client that leaves after PAIR_REPLY still spent a guess.
  Keys/pairings: `%ProgramData%\Relay`, `~/Library/Application Support/Relay`.
- **snow's default `Dh25519` accepts an all-zero DH result** (plain `mul_clamped`), which
  Relay has always refused (the Mac's Noise.swift too), so the host checks every key a peer
  sends with `Identity::refuse_low_order`. snow's `std` feature turns on `ring/std` (not
  `ring?/std`) and so builds ring; the host uses `default-features = false` with just the
  four `use-*` features its suite needs.

## Conventions

- Rust: `anyhow` errors, `log` macros, no async (one thread per concern), Windows APIs via
  the `windows` 0.58 crate, keep clippy clean. Swift: AppKit + Network.framework +
  CryptoKit only, no third-party packages.
- Defaults are 120 Hz and the Mac's native pixel size; `--scale 0.75`/`0.5` are the
  cheaper same-aspect modes.
- Keep the README's status table honest; note anything verified on real hardware.

`CLAUDE.md` only imports this file; edit here.
