# Relay wire protocol (v3)

One TCP connection, one client at a time. Host (Windows PC) listens on **TCP 8468**
and advertises itself over mDNS as `_relay._tcp.local.`. The client
(MacBook) browses for that service, connects, and the host adds a virtual monitor
for the duration of the connection.

Designed for a direct Ethernet cable, but safe on shared networks: every session
is mutually authenticated and encrypted (see "Handshake and pairing"); there is
no congestion control. All integers are **big-endian**.

## Discovery

The host advertises `_relay._tcp` over mDNS with a TXT record containing
`v` (protocol version, decimal) and `pk` (the host's identity public key, 32
bytes as 64 lowercase hex characters). Clients use `pk` to show whether a host
is already paired before connecting; it is informational and never trusted in
place of the handshake.

The record may also carry facts about the PC for the client to show on hover,
each omitted when unknown and truncated to fit a 255-byte TXT string:
`cpu` (processor name), `ram` (installed memory in whole GB, decimal),
`ramtype` (e.g. `DDR4-3600`, from SMBIOS), `gpu` (render adapter name), `vram`
(its dedicated memory in whole GB), `os` (e.g. `Windows 11 Pro 24H2 (build
26100)`), and `ip` (comma-separated IPv4 addresses, routable before link-local). Like `pk`
they are public and purely informational.

## Framing

Every message is an 8-byte header followed by `length` bytes of payload. On the
wire, header + payload travel inside one encrypted frame (below); the header is
never sent in the clear.

```
offset  size  field
0       u8    type
1       u8    flags        (message-specific; 0 if unused)
2       u16   reserved     (0)
4       u32   length       payload length in bytes
8       ...   payload
```

Maximum payload length is 64 MiB; anything larger is a protocol error and the
receiver closes the connection.

## Handshake and pairing

Both sides own a long-lived X25519 identity key. The first time a client talks
to a host it proves knowledge of the PIN the host displays; the host then stores
the client's key and the client stores the host's, and later connections need
no PIN. Every connection also runs a fresh ephemeral exchange, so session keys
are unique and forward-secret.

The two handshake messages are the only cleartext ever sent; each is prefixed by
a `u32` length like every later frame:

```
msg1  client -> host   "TDH2" | u16 version (2) | S_c (32) | E_c (32)               70 bytes
msg2  host -> client   "TDH2" | u16 version (2) | S_h (32) | E_h (32) | paired (u8)   71 bytes
```

`S_*` are the identity public keys, `E_*` fresh ephemeral public keys, `paired`
whether the host already knows `S_c`. Then both sides compute:

```
th    = SHA-256(msg1 || msg2)
ikm   = X25519(E_c, E_h) || X25519(E_c, S_h) || X25519(S_c, E_h)
okm   = HKDF-SHA256(salt = th, ikm, info = "TravelDisplay v2", 96 bytes)
k_c2h = okm[0..32]      k_h2c = okm[32..64]      k_pair = okm[64..96]
```

The `info` string and the `TDH2` magic keep the project's original name on
purpose: they are wire constants covered by the test vector below, and renaming
the app to Relay was not a reason to break every existing pairing.


The second and third DH terms require the host's and the client's identity
private keys respectively, which is what authenticates each side to the other.
A client that knows the host's identity must refuse a different `S_h` for the
same host (the host's key changed = someone else). Reject all-zero DH outputs.

**Encrypted frames.** From here on every message is

```
u32 length || ChaCha20-Poly1305(key = k_dir, nonce = 4 zero bytes || u64 counter,
                                aad = empty, plaintext = header (8) || payload)
```

where `length` covers ciphertext + 16-byte tag, `k_dir` is `k_c2h` or `k_h2c`
for the sending direction, and each direction's counter starts at 0 and
increments per message (never reused; a decryption failure ends the session).

**Pairing.** The host sends SERVER_HELLO immediately after msg2. If the client
is unknown to the host (`paired == 0`), or the host is unknown to the client,
the client sends PAIR before its CLIENT_HELLO:

| type | name        | direction | payload |
|------|-------------|-----------|---------|
| 0xA0 | PAIR        | client -> host | `HMAC-SHA256(k_pair, "pin:" || PIN digits)` (32 bytes) |
| 0xA1 | PAIR_RESULT | host -> client | `u8 result`: 1 = paired, 0 = wrong PIN, 2 = rate-limited, followed by `u16 seconds` until pairing is accepted again. On 0 and 2 the host then closes. |
| 0xA2 | UNPAIR      | client -> host | empty. Sent instead of CLIENT_HELLO: the host forgets `S_c`, answers STREAM_STOP reason 5 (`UNPAIRED`) and closes. |

The host rate-limits failures (5 per 10 minutes, then refuses all pairing with
result 2 and the remaining wait, checked before the proof so a locked-out
guesser learns nothing about the PIN) and accepts a PIN from an already-paired
client too (a client that lost its copy of the host key). A client that only
tests `result == 1` keeps working. An unpaired client that sends anything but
PAIR gets STREAM_STOP with reason 4 (`NOT_PAIRED`).

**Forgetting.** A client that drops a pairing sends UNPAIR as its first
encrypted message so both sides forget each other in one step; the host
answers STREAM_STOP with reason 5 whether or not it knew the client, then
closes. The client removes the host locally regardless of whether the host was
reachable (the host side can then be cleaned up with `relay-host paired
--forget <fingerprint>`). A client the host does not know that sends UNPAIR is
answered the same way, not with `NOT_PAIRED`.

This is not a PAKE: an attacker who sits in the middle of the *first* pairing
can brute-force the 6-digit PIN offline. Pair on the cable or at home; after
that the pinned identity keys make impersonation impossible on any network.

**Test vector** (all secret scalars are the byte repeated 32 times; client
identity 0x11, client ephemeral 0x22, host identity 0x33, host ephemeral 0x44,
`paired = 0`, PIN "123456"):

```
msg1   5444483200027b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f130faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20
msg2   5444483200027b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14ff2ee45601ec1b67310c7790404585ae697331eee1c1f8cf2419731c1fff3e6b00
k_c2h  d8a97f4a0b7c64b0be967bbc40644991d83dc7e8660ee9c1afdfabe570be86a5
k_h2c  f62792bb52e27a09c5932048f06bf373e6a680cf3d7ea78693e394d426405c9b
k_pair abcb29c363b089c882c6c4a4fe0d815fed0c48b0ab99fcf8a968b953e83f029f
proof  11ef35ab8b2347a264019c1995103913f92db8ef3080cea0407a04bd6adcc397
frame  47de84ee17d1168e959caa9768dd9532bdb13b964fbc3a614f30f853a16741f1270b1867ff11f18833740b2f1f5aa82d66b3c34c85db1f7c
```

`frame` is the client's first encrypted message (counter 0 under `k_c2h`): the
PAIR header plus `proof`, without the length prefix.

## Session

```
client                                   host
  |------------------- TCP connect ------->|
  |------------------- msg1 -------------->|
  |<------------------ msg2 ---------------|   keys derived on both sides
  |<----------------- SERVER_HELLO ---------|
  |------------------- PAIR --------------->|   only when not paired yet
  |<----------------- PAIR_RESULT ----------|
  |------------------- CLIENT_HELLO ------->|   host adds virtual display, sets mode
  |<----------------- STREAM_START ---------|
  |<----------------- CODEC_CONFIG ---------|
  |<----------------- FRAME (key) ----------|
  |<----------------- FRAME ----------------|
  |------------------- MOUSE_MOVE --------->|
  |<----------------- PING -----------------|   every 1 s
  |------------------- PONG --------------->|
  |                   ...                   |
  |------------------- TCP close ---------->|   host kills encoder, removes display
```

The host removes the virtual display when the connection closes for any reason.
If the client stops answering PINGs for 5 s the host closes the connection.

**Busy.** The host serves one display session at a time, but pairing is not a
display session. A client that connects while one is running is not left in
the listen backlog: the host completes the handshake (so a paired client can
trust the answer), sends SERVER_HELLO, and reads its first encrypted request.
PAIR and UNPAIR are handled normally without touching the running session. A
pair-only client may close after PAIR_RESULT. If the client sends CLIENT_HELLO
(the request to take over the display), it atomically competes for the one
display lease; if another client owns it, the host answers STREAM_STOP reason
6 (`BUSY`) and closes. A connection waiting for a PIN does not reserve the
display. The running session is never preempted; the client should show "in
another session" rather than retry in a loop.

## Host → client

| type | name           | payload |
|------|----------------|---------|
| 0x01 | SERVER_HELLO   | `u16 proto_version`, `u8 name_len`, `name` (UTF-8) |
| 0x02 | STREAM_START   | `u16 width`, `u16 height`, `u16 fps`, `u16 bitrate_mbps`, `u8 codec`, `u8 reserved` |
| 0x03 | CODEC_CONFIG   | parameter-set NAL units: repeated `u32 len` + NAL bytes (no start codes). HEVC: VPS, SPS, PPS. H.264: SPS, PPS. |
| 0x04 | FRAME          | one access unit: repeated `u32 len` + NAL bytes (no start codes, parameter sets and AUDs stripped). `flags & 0x01` = keyframe (IRAP). |
| 0x05 | CURSOR         | `i32 x`, `i32 y` (pixels, relative to the streamed display), `u8 visible`. Reserved for a future cursor-overlay path; currently the Windows cursor is composited into the video. |
| 0x06 | STREAM_STOP    | `u8 reason` (0 = host shutting down, 1 = encoder failed, 2 = display lost, 3 = bad version, 4 = not paired, 5 = unpaired at the client's request, 6 = busy with another client, 7 = selected bitrate exceeded the connection's sustained bandwidth) |
| 0x07 | PING           | `u64 host_time_us` |
| 0x08 | FRAME_TIMING   | optional telemetry for the immediately preceding FRAME: `u64 sequence`, `u32 capture_us`, `u32 encode_us`, `u32 frame_send_us`, `u32 network_rtt_us`. A duration of `0xffffffff` is unavailable. |

`codec`: 1 = H.264, 2 = HEVC, 3 = AV1 (reserved).

FRAME payloads are already in the length-prefixed layout that `CMSampleBuffer`
and `hvcC`/`avcC` expect (4-byte NAL lengths), so the client can hand them to
VideoToolbox without rewriting. A new CODEC_CONFIG may arrive before any
keyframe; the client must rebuild its format description when the bytes differ
from the last one it saw.

`FRAME_TIMING` is sampled diagnostic data and does not alter the video stream.
Sequence numbers start at zero for each session and identify the preceding FRAME;
the host need not send telemetry for every frame. Native NVENC reports capture and encode durations;
the ffmpeg fallback reports those fields as unavailable because its output pipe
cannot associate an encoded access unit with the originating capture. The client
estimates one-way network latency as half the measured ping round trip. Existing
clients can ignore this message and continue decoding the preceding FRAME normally.

The host bounds encoded output waiting behind the socket. If, for a continuous
five-second window, frame delivery stays below 95% of the selected frame rate
while encryption and writes consume at least 80% of wall time, the connection
cannot sustain the selected bitrate. The host stops capture, best-effort sends
STREAM_STOP reason 7, closes the connection and restores the display. It never
silently changes the requested bitrate, and the client must not automatically
retry reason 7 without a lower user-selected value.

## Client → host

| type | name         | payload |
|------|--------------|---------|
| 0x81 | CLIENT_HELLO | `u16 proto_version`, `u16 width_px`, `u16 height_px`, `u16 refresh_hz`, `u16 bitrate_mbps`, `u8 flags`, `u8 codecs`, `u8 name_len`, `name` |
| 0x87 | PONG         | echo of the PING payload |
| 0x90 | MOUSE_MOVE   | `u16 x`, `u16 y` — position normalised to 0..65535 across the streamed frame |
| 0x91 | MOUSE_BUTTON | `u8 button` (0 left, 1 right, 2 middle, 3 back, 4 forward), `u8 down` |
| 0x92 | MOUSE_WHEEL  | `i16 dx`, `i16 dy` — Windows wheel units, 120 = one notch; positive dy scrolls up (content moves down), positive dx scrolls right |
| 0x93 | KEY          | `u16 hid_usage` (USB HID Keyboard/Keypad page 0x07), `u8 down` |

CLIENT_HELLO `flags`: bit 0 = client wants to send input. `codecs` bitmask:
bit 0 = H.264, bit 1 = HEVC, bit 2 = AV1. `width_px`/`height_px` are the
client's native **pixel** size; the host uses them to pick the virtual display
mode (falling back to the closest mode the driver offers). `refresh_hz` is a
request; the host may answer with a lower `fps` in STREAM_START.
`bitrate_mbps` is the requested CBR video bitrate and must be 1 through 1000.
The host uses it unless it was started with an explicit `--bitrate` override;
`STREAM_START` reports the bitrate actually selected.

Keys are sent as HID usages so the protocol is platform-neutral; the client
decides how macOS modifiers map (default: ⌘→Ctrl, ⌥→Alt, ⌃→Win) and the host
translates HID usages to PS/2 scan codes for `SendInput`.

## Notes

- With the ffmpeg-based encoder (milestone 1) the host learns an access unit is
  complete only when the next AU's delimiter arrives, which costs one frame
  interval of latency. The in-process encoder (milestone 5) removes that.
- Version negotiation: both sides send `proto_version` (currently 3) inside the
  hellos; the handshake carries its own version in msg1/msg2. A host that
  doesn't support the client's version sends STREAM_STOP and closes.
