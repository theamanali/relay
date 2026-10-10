# Windows handoff: allow time to enter the PIN when re-pairing

The user requested a Windows-session handoff on 2026-10-09. The Mac session
has prepared the patch below; **host source has not been changed or built**.
Start by pulling `main` and reading `AGENTS.md`.

## Reproduction and cause

1. The Mac's Forget attempt was blocked by macOS local-network privacy. It
   removed the PC locally, but never delivered UNPAIR to the PC.
2. Quitting and reopening the rebuilt Mac app cleared that block. A real-PC
   connection over Ethernet completed TCP + Noise and showed the PIN sheet
   (PC fingerprint `04F6A881`). No PIN was entered or pairing modified during
   these reachability checks.
3. The PC closed the socket about five seconds after the handshake. The Mac
   correctly dismissed the PIN sheet belonging to that dead connection.

`host/src/server.rs::handle_session` starts the socket at HELLO_TIMEOUT (5 s).
After SERVER_HELLO, it switches to PAIR_TIMEOUT (120 s) **only if
`!hs.paired`**. The PC still knows the Mac's key, so the five-second deadline
remains even though the Mac no longer knows the PC and must ask for its PIN.
The same bug affects a Mac that loses `hosts.txt` while retaining `identity.key`.

This timeout condition predates the recent pairing-name work (`git blame`
places it in September). The name extension is sent only after the human
provides a PIN; it cannot extend the initial wait. The new Mac error handling
does not introduce a short PIN-entry timer. Reconnecting repeatedly does not
solve this: each connection starts another five-second window.

## Exact fix

From the repo root, apply the companion patch:

```powershell
git apply --check docs/known-peer-pin-timeout.patch
git apply docs/known-peer-pin-timeout.patch
```

The patch moves `rx.set_read_timeout(Some(PAIR_TIMEOUT))?` outside the
`if !hs.paired` condition immediately before the first encrypted request is
read. Keep the conditional log for an unknown client.

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

Add a loopback regression using the **production control prelude** in
`server.rs::handle_session` (a unit test in that module can call it), with
temporary identities, peer files and PIN state. Do not test a fixture that
sets its own timeout: it would miss this bug.

Pre-populate the host's peer list with the client key, complete Noise and
assert SERVER_HELLO says paired. Model the Mac as having forgotten the host:
wait at least 6–8 seconds **after SERVER_HELLO**, then send a valid CPace PAIR
and confirmation. Expect success and durable pairing/name storage, then close
without CLIENT_HELLO. The unfixed code must fail this case at five seconds.

Repeat with an unknown key, and with the display-claimed flag already true.
Pair-only must succeed without acquiring/releasing that other session's lease
or touching a driver/GPU/display. Retain coverage for immediate known-client
Connect, UNPAIR, wrong PIN, abandoned confirmation and rate limiting. Use an
inert config/driver that fails the test if display setup is attempted; do not
run exclusive display tests from the agent's active PC session.

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

Update this handoff, README status and AGENTS with the Windows checks, installed
build and real-Mac results. Until deployment, the workaround is to remove the
Mac through the PC tray's **Forget paired MacBook** submenu first; the PC then
uses its existing two-minute timeout for that unknown key.
