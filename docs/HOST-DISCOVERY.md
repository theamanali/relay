# Discovery TXT record — note for the PC session (2026-09-16)

**From the Mac session.** The client now launches into a host picker with
*Paired* and *Not paired* sections. To decide which section a discovered host
belongs in *before* connecting, it needs the host's identity key from the
Bonjour record. Until the host advertises it the client falls back to matching
the service instance name against names it already saved in `hosts.txt`
(marked "name match, key not advertised" in the list); the handshake verifies
the real key regardless, so the fallback is safe but imprecise (a renamed PC or
two PCs with the same name misclassify).

## Host change (host-first, then spec, then nothing on the client)

`host/src/discovery.rs` `advertise()` currently sets one TXT property, `v`.
Add:

- `pk` = the host's long-lived X25519 **public** key, 64 lowercase hex chars
  (32 bytes). `ServerConfig.identity` (`server.rs:65`) already holds it;
  `advertise(&cfg.name, cfg.port)` needs the key passed in.

The client reads `pk` from `NWBrowser.Result.metadata` and treats a missing or
malformed value as "not advertised". Nothing else changes: the key is public
(it's what the client already stores after pairing), and advertising it does
not weaken pairing — the PIN proof and the stored-key check are unchanged.

## Spec paragraph for `docs/PROTOCOL.md` (add when the host change lands)

> **Discovery.** The host advertises `_traveldisplay._tcp` over mDNS with a TXT
> record containing `v` (protocol version, decimal) and `pk` (the host's
> identity public key, 32 bytes as 64 lowercase hex characters). Clients use
> `pk` to show whether a host is already paired before connecting; it is
> informational and never trusted in place of the handshake.

## Verify

`dns-sd -B _traveldisplay._tcp` then `dns-sd -L "<name>" _traveldisplay._tcp`
on the Mac shows the TXT record. In the client, the host's row then shows its
fingerprint (`fingerprint()` of `pk`, same as the PIN dialog) and the "name
match" suffix disappears; `traveldisplay-host pin` after a re-key should move
the host to *Not paired*.
