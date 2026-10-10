# Mac handoff: show the Mac name immediately after Pair

## Scope and current state

The Windows side is implemented. The user chose host changes plus a Mac-session
handoff; `client/` and `docs/PROTOCOL.md` are deliberately untouched here. The Mac
session should implement the matching client, fakehost and tests, then update the
wire spec to describe this optional v4 extension. The existing spec remains the
base v4 contract; this document describes the staged extension until that rollout.

Previously, the Mac sent its name only in CLIENT_HELLO, which requests streaming.
The host saved `paired <IP>` after pair-only. It now saves a name supplied during
CPace only after valid PAIR_CONFIRM, before sending PAIR_RESULT(success). No
CLIENT_HELLO or virtual-display operation is needed. The name is also bound into
CPace confirmation as ADa; changing it invalidates the proof.

Old clients still pair. A new unnamed peer is stored as `Paired MacBook` (the tray
already appends its fingerprint); an unnamed re-pair preserves an existing name.
Named re-pair updates the name. Name changes do not alter the pairing digest.
Existing `paired <IP>` entries are not guessed or reverse-resolved. They gain a
name on a successful named re-pair or the existing streaming CLIENT_HELLO path.

## Exact wire extension

Noise handshake, version 4, identities and existing pairings are unchanged.

1. SERVER_HELLO remains `u16 version | u8 name_len | host_name | u8 paired`,
   followed optionally by **one capability byte**. Bit `0x01` is `CAP_PAIR_NAME`.
   This host appends `0x01`; older hosts omit it. Missing means zero. Ignore
   unknown bits. Existing clients already ignore this trailing byte.
2. Only when the host advertises that bit, send PAIR (`0xA0`) as:
   `Ya[32] | u8 client_name_len | client_name_utf8`.
   Cap the name at **255 UTF-8 bytes**, truncating on a Unicode scalar boundary;
   do not split a UTF-8 sequence. No terminator. Maximum PAIR payload: 288 bytes.
3. CPace **ADa is the complete suffix, including the u8 length**. Pass these exact
   bytes to `CPaceInitiator(..., ad: suffix)` and append the same suffix to its
   `share` for PAIR. A zero-length name has ADa `[0]`, not empty ADa.
4. Without the capability, send the original 32-byte Ya with empty ADa. Do not
   attempt the extension against an old host or retry a refused PIN as another
   protocol variant. The fallback retains the old name-after-streaming behavior.
5. ADb remains empty. PAIR_REPLY (Yb + Tb), PAIR_CONFIRM (Ta), PAIR_RESULT,
   rate limiting and PIN rotation remain unchanged. The host accepts legacy PAIR
   as well as named PAIR; it rejects inconsistent lengths and invalid UTF-8.
6. In the spec's CPace formulas, use `lv_cat(Ya, ADa)` instead of `lv_cat(Ya, "")`
   in ISK and Ta. ADb stays empty and Tb's formula is unchanged, but both tags
   change because ISK changes. Generator, Ya, Yb, K and Noise h are unchanged
   by the name. The original v4 test vector is still the legacy case.

The host replaces control characters with spaces and trims the name **after**
confirmation for storage/UI. Proofs use the original wire bytes. Names remain
display labels; identity and Forget operations still use the public key.

## Mac work

- `Sources/Relay/Protocol.swift`: parse optional capabilities in `ServerHello`;
  add a helper for the length-prefixed, UTF-8-safe name suffix.
- `HostConnection.swift`: remember the capability for the current connection
  from `handleServerHello`, clearing it when starting another attempt. In
  `askForPIN`, use `options.clientName`, build ADa once, pass it to
  `CPaceInitiator`, and send `share + ADa`. Keep PAIR_CONFIRM as its 32-byte tag.
  Both Pair-only and pair-then-stream use this path. Leave verify-only/UNPAIR and
  already-paired behavior alone; do not send a streaming hello just to name a peer.
- `Tools/fakehost/main.swift`: advertise the capability, parse both PAIR layouts,
  pass the suffix as responder `peerAD`, and offer a legacy-capability-off mode
  to verify new-Mac/old-host compatibility. Continue supporting wrong PIN,
  abandon, busy, rate limit and forget cases.
- Add tests for legacy/extended SERVER_HELLO, unknown capability bits, Unicode
  truncation, empty name versus legacy ADa, malformed names, the vector below,
  and tampering with the name. Exercise Pair-only through fakehost.
- Update `docs/PROTOCOL.md` pairing table/formulas and SERVER_HELLO, plus relevant
  README/AGENTS status. Build/test/bundle on the Mac; this PC has not verified Swift.

## Named CPace vector

Use the **same inputs as the existing v4 vector**: client static `0x11` × 32,
client ephemeral `0x22` × 32, host static `0x33` × 32, host ephemeral `0x44` × 32,
PIN `123456`, CPace scalars `0x55` × 32 and `0x66` × 32. CI, h, Ya, Yb and K
are unchanged. Client name is `Aman’s MacBook Pro` (U+2019 apostrophe, 20 UTF-8
bytes); ADb is empty. Rust test: `crypto::tests::named_pairing_vector`.

```text
ADa = 14416d616ee2809973204d6163426f6f6b2050726f
ISK = babe000cfe7c4fd314c375fed097aa1d24fe6378e76301176e789efc7d1028bc6b478776897e730bd39f59a00f4229e177eb7237545ba54c9fe9109b3eaab508
Tb  = 499bc005e3877364ce6002d9fcecf22d02d1a0f76019e9f6f042150add403315
Ta  = 921c83bc4d09122459355ac523326b048f5bae10859d4584543415d41b946e2d
```

## Windows verification and deployment

Passed on 2026-10-09: `cargo test` (142 unit tests and one probe integration
test; one opt-in desktop test ignored), `cargo clippy --all-targets -- -D warnings`,
`cargo build --release` and `cargo fmt --check`. This build has not been installed.

`cargo test` includes `tests/pair_name.rs`, which invokes the real probe executable
against isolated loopback endpoints using the production Noise/CPace and peer
storage code. It checks the persisted Unicode name before the success response,
new-host/legacy-client and new-client/legacy-host compatibility, wrong PIN and
abandon. It asserts pair-only closes without CLIENT_HELLO. It never starts the
installed service, touches real pairings or changes a display. Unit tests also
cover tampering, malformed requests, bounded Unicode and blank-name re-pairing.

The host build must be deployed before testing the Mac update on real hardware:
from elevated PowerShell at the repo root:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\tools\install-host.ps1 -SkipDriver
```

With both apps updated, Forget the test pairing, then Pair from the Mac picker
and stop there. Open the Windows tray's Forget submenu: it must immediately show
the Mac name, and the PC displays must never change. Repeat with a wrong PIN:
no peer/name should be added. Repeat while another client streams to ensure
pair-only never takes its display lease. Restart the service and confirm the
name persists. Existing real pairings need not be reset unless testing a fresh
Pair; a known old placeholder needs explicit re-pair or a stream to refresh.

For host-only manual checks, probe now accepts `--name "Test Mac"` and
`--legacy-pair`, alongside `--pair-only --pin <PIN>`. Use a dedicated test
identity and remove it afterward with `--unpair`; avoid `--fresh-identity` on
the real service if you need that same key to unpair later. Installed-service
and real-Mac verification of this extension remain pending.
