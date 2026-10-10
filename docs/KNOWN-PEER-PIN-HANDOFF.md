# Windows handoff: allow time to enter the PIN when re-pairing

The user initially requested a Windows-session handoff on 2026-10-09, then
authorized proceeding with the fix. The Mac session applied the host source
change and added production-handler regression tests on 2026-10-10.
**Windows checks and deployment passed on 2026-10-10; real-Mac retesting remains
pending.** Source commit `ae249f4` needed no further code changes. See the
verification record below for the installed build and scope of the checks.

## Reproduction and cause

1. The Mac's Forget attempt was blocked by macOS local-network privacy. It
   removed the PC locally, but never delivered UNPAIR to the PC.
2. Quitting and reopening the rebuilt Mac app cleared that block. A real-PC
   connection over Ethernet completed TCP + Noise and showed the PIN sheet
   (PC fingerprint `04F6A881`). No PIN was entered or pairing modified during
   these reachability checks.
3. The PC closed the socket about five seconds after the handshake. The Mac
   correctly dismissed the PIN sheet belonging to that dead connection.

Before the fix, `host/src/server.rs::handle_session` started the socket at
HELLO_TIMEOUT (5 s). After SERVER_HELLO, it switched to PAIR_TIMEOUT (120 s)
**only if `!hs.paired`**. The PC still knew the Mac's key, so the five-second
deadline remained even though the Mac no longer knew the PC and needed its PIN.
The same bug affects a Mac that loses `hosts.txt` while retaining `identity.key`.

This timeout condition predates the recent pairing-name work (`git blame`
places it in September). The name extension is sent only after the human
provides a PIN; it cannot extend the initial wait. The new Mac error handling
does not introduce a short PIN-entry timer. Reconnecting repeatedly does not
solve this: each connection starts another five-second window.

## Exact fix

The source change moves `rx.set_read_timeout(Some(PAIR_TIMEOUT))?` outside the
`if !hs.paired` condition immediately before the first encrypted request is
read. The conditional log for an unknown client remains.

Every client then has up to two minutes to send PAIR, CLIENT_HELLO or UNPAIR
after SERVER_HELLO. This handles a known client that needs human PIN entry
without guessing from the host's half of the pairing state.

- Keep the initial Noise handshake at HELLO_TIMEOUT.
- Keep the PAIR_REPLY → PAIR_CONFIRM wait at HELLO_TIMEOUT: the human has
  already entered the PIN when PAIR is sent.
- Keep the existing later timeout assignments, PIN limiter/rotation and
  identity/name confirmation rules.
- No display lease is acquired until CLIENT_HELLO. Pair-only must still close
  without it. The existing eight-connection cap remains in place.
- No protocol version, wire message, crypto, or Mac production change is needed.
  Do not send CLIENT_HELLO, UNPAIR, invented keepalives or guessed PINs merely
  to keep the PIN sheet open.

## Regression checks on Windows

`server.rs::pairing_wait_tests` now exercises **production `handle_session`**
over loopback with generated identities, temporary peer files and fixed test
PIN state. Three cases wait six seconds **after SERVER_HELLO** before sending
valid CPace PAIR and confirmation: a known key, an unknown key, and a known
key while another session owns the display. Each checks the paired flag and
durable name storage, then closes without CLIENT_HELLO. The known-key cases
would fail at five seconds with the old timeout condition.

The inert driver panics on any display operation. Tests assert the existing
display claim and session are preserved. All three passed on Windows, along
with existing crypto regressions for wrong PIN, abandoned confirmation and rate
limiting. Immediate known-client Connect still needs the user's streaming test;
the agent does not run exclusive display tests from the active PC session.

Run on the Windows PC from `host/`:

```powershell
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
cargo build --release
```

The Mac already passes 102 Swift tests and its isolated HostConnection /
UnpairTask checks. Those checks are not verification of this Rust timeout fix.

## Deploy and verify on the hardware

After Windows checks pass, deploy from an elevated repo-root PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\tools\install-host.ps1 -SkipDriver
```

The current real Mac is already in the half-forgotten state, so no pairing
reset should be needed for the first check. Choose Pair, leave the PIN sheet
open for 10–15 seconds, then enter the correct PC PIN. It must pair successfully
with the displays untouched, and the PC tray must name the Mac before Connect.
Also verify wrong-PIN retry gives a full entry window, Forget from the Mac is
confirmed by the PC, and ordinary Connect still works. Let the user perform
streaming checks because they change the physical display topology.

If recreating the half-forgotten state is needed, have the user disconnect the
link, Forget locally while the PC cannot be reached, then reconnect the link.
Use their chosen test pairing; do not delete the Mac identity or other peers.

Update this handoff, README status and AGENTS when real-Mac results arrive.
The installed fix no longer requires clearing the PC's pairing to obtain the
two-minute PIN-entry window.

## Windows verification record — 2026-10-10

- Source: `ae249f42b24d7da2d52c71999d8bc37628d9aa25`; no code repair needed.
- `cargo fmt --check`: passed.
- `cargo test`: 145 unit tests and one probe integration test passed; one
  opt-in desktop test remained ignored. All three six-second timeout regressions
  passed, including known-key re-pair while another session owns the display.
- `cargo clippy --all-targets -- -D warnings`: passed.
- `cargo build --release`: passed.
- Elevated `tools/install-host.ps1 -SkipDriver`: exit 0 at 13:05 PDT.
  Service Running; SYSTEM worker started in session 1 (PID 18920) and listened
  on `[::]:8468`. Host fingerprint remains `04F6A881`.
- Installed `C:\Program Files\Relay\relay-host.exe` matches the checked release
  build, SHA-256:
  `EEEEA9E0F2CC36ED4A9E3ADF7D5AB00B47FC22FD3754FF67DB809065B3A5C460`.

Installed-service probe verification passed at 13:06–13:07 PDT. The unmodified
release probe used a dedicated temporary identity (`9AEA10BE`) and a loopback
proxy that forwarded Noise and SERVER_HELLO immediately, then held the first
encrypted client request for 12 seconds. It did not decrypt or modify messages.
The probe explicitly used `--pair-only` (or `--unpair`); no CLIENT_HELLO was sent.

| Check | Result |
|---|---|
| Fresh named pair-only | Passed; name persisted without a streaming connection. |
| Known-key re-pair, 12-second wait | Passed in 12.01 s; SERVER_HELLO reported already paired; Unicode replacement name persisted. |
| Known-key wrong PIN, 12-second wait | Rejected in 12.02 s; saved peer/name unchanged. |
| Known-key correct retry, another 12-second wait | Passed in 12.01 s. |
| Immediate known-key UNPAIR | Confirmed in 0.03 s; test pairing removed. |

The original two-peer list was preserved, and its advertised pairing digest
returned to its initial value. Successful checks rotated the PIN normally; use
the current tray PIN for the Mac retest. Logs confirm pair-only disconnects and
UNPAIR, with no display setup during these checks. These tests verify waits
beyond the old five-second cutoff; the full 120-second expiry was not timed.
Busy pairing was verified by the production-handler regression, not a real
concurrent stream. No new host source changes were required.

Real-Mac PIN-sheet behavior, wrong-PIN retry UI, confirmed Forget, pair-only
name presentation in the tray, and ordinary Connect/disconnect remain unverified
on this deployed build. No streaming/exclusive-display test was run by the agent.
