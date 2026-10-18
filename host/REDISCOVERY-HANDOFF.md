# Handoff to the Mac session: rediscovery after a host dies (finding 6)

Status 2026-10-18: the host side is done and is **not enough**. This needs a
Mac change in `client/`. No wire, TXT or protocol change is involved.

## What happens

The Relay service's worker is killed (as in a crash). It sends no mDNS goodbye.
The service restores the displays and starts a new worker 5 s later, which
registers the same record (same instance name, port, `pk`, `pg`). The Mac's
picker drops the PC's row and **never shows it again** until Relay is quit and
reopened. After reopening, Connect works without a PIN.

## Evidence (home LAN, Mac at `2601:600:9b7f:85ff:dc6:bf12:7712:a49f`)

Installed host `6de6010`+ (SHA-256 `70749142…9CF97724`), which re-announces
each new record 3, 8, 16, 32 and 60 s after registering it, on top of
mdns-sd 0.11.5's own two announcements at 0 and 1 s:

| run (UTC) | what | host.log | Mac |
|---|---|---|---|
| 00:50:36 | worker killed, picker idle, Connect during the 5 s gap | new worker `advertising` 00:50:42, `re-announced` 1/5 … 5/5 by 00:51:42 | "couldn't reach the PC"; row disappeared and never came back |
| 00:53:40 | worker killed mid-session (U6) | new worker `advertising` 00:53:46, `re-announced` 1/5 … 5/5 by 00:54:46 | session dropped; row disappeared and never came back |

Afterwards the PC's own `browse` heard the record on every interface with
the same `pk`/`pg`. So the record is on the air, announced seven times in the
first minute and answered on query, and the Mac's picker does not take it up.

Unexplained: with a `--no-vdd` dev host killed the same way (`Stop-Process
-Force`, 5 s or 20 s gap, with and without a failed Connect, mid-session or
idle) the row **never disappeared** (`host/NVIDIA-RECOVERY-RETEST.md` F6a).
Only the real worker's death removed it. The difference may be on either
side. One candidate is the PC's network or display change while the service
restores the layout, which the dev host does not do.

## Suggested Mac work

1. **First, find out which layer loses it.** During a repro run, in Terminal:
   `dns-sd -B _relay._tcp local.` and `dns-sd -L "GAMING-PC" _relay._tcp local.`
   Also run `log stream --predicate 'process == "mDNSResponder"' --info`
   and Relay's own log.
   - If `dns-sd -B` shows the PC's `Add` again after the new worker starts
     while Relay's picker does not: the app is losing it (the `NWBrowser` state,
     `HostListDebouncer`'s removal/withdrawal handling, or `PairingVerifier`
     / a forgotten-host path).
   - If `dns-sd -B` also shows only `Rmv`: mDNSResponder is ignoring the
     announcements (for example a reconfirm still in progress on the record).
     Then the app has to re-query.
2. **Likely fix either way:** when a known host's row is removed, or a picker
   dial ends without reaching `.ready` (the `BonjourReconfirm` path), cancel and
   recreate the `NWBrowser` after a short delay (for example 2–3 s, then again
   at roughly 10 and 30 s while that host is still missing). A new browse
   question makes mDNSResponder query at once instead of on the backoff of a
   long-lived question, and the host answers queries immediately. Keep the
   debouncer's grace logic so a browse restart does not flicker other rows.
3. Test with `fakehost` killed with `kill -9` and restarted (a record this Mac
   registered itself never flushes, so use a second Mac or the real PC for the
   final check). The PC-side steps are F6b in `host/NVIDIA-RECOVERY-RETEST.md`:
   kill only the worker from an elevated PowerShell with
   `Get-CimInstance Win32_Process -Filter "name='relay-host.exe'" | Where-Object CommandLine -match ' worker' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }`.
