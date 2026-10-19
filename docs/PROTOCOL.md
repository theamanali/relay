# Relay wire protocol (v4)

One TCP connection, one client at a time. Host (Windows PC) listens on **TCP 8468**
and advertises itself over mDNS as `_relay._tcp.local.`. The client
(MacBook) browses for that service, connects, and the host adds a virtual monitor
for the duration of the connection.

Designed for a direct Ethernet cable, but safe on shared networks: every session
is mutually authenticated and encrypted (see "Handshake and pairing"); there is
no congestion control. All integers are **big-endian**, except inside Noise
(the record nonce, below).

## Discovery

The host advertises `_relay._tcp` over mDNS with a TXT record containing
`v` (protocol version, decimal: `4`), `pk` (the host's identity public key, 32
bytes as 64 lowercase hex characters) and `pg` (the pairing digest: the first
4 bytes of SHA-256 over the ASCII label `relay-pairing-digest-v1` followed by
the host's paired client public keys, sorted and concatenated, as 8 lowercase
hex characters; the label keeps a one-client digest from equalling that
client's fingerprint). Clients use `pk` to show whether a host
is already paired before connecting; it is informational and never trusted in
place of the handshake.

`pg` changes whenever the host pairs or forgets a client, and the host
re-registers the record when it does. It is how a client learns that a host
forgot it: a client that knows a host and sees its `pg` differ from the value
it last verified runs the handshake alone (no CLIENT_HELLO, so it never
touches the display or another client's session), reads `paired` from
SERVER_HELLO and closes; 0 means the host forgot it, and the client removes the
host locally. The
digest says nothing about who is paired, and like `pk` it is informational: the
handshake, not the digest, is the authority.

The record may also carry facts about the PC for the client to show on hover,
each omitted when unknown and truncated to fit a 255-byte TXT string:
`cpu` (processor name), `ram` (installed memory in whole GB, decimal),
`ramtype` (e.g. `DDR4-3600`, from SMBIOS), `gpu` (render adapter name), `vram`
(its dedicated memory in whole GB), `os` (e.g. `Windows 11 Pro 24H2 (build
26100)`), and `ip` (comma-separated IPv4 addresses, routable before link-local). Like `pk`
they are public and purely informational.

`enc` lists, comma-separated, the picture options this host's encoder honours
(see "Picture options" under Client → host):

| item | meaning |
|---|---|
| `q` | honours CLIENT_HELLO's `encoder_quality` |
| `444` | can encode HEVC 4:4:4 (8-bit, and 10-bit when `10` is also listed) |
| `10` | can encode HEVC 10-bit |

The host omits the key when it supports none of them; clients ignore items
they don't know. It is fixed for the life of the host process: the host
derives it once at startup from its NVIDIA GPU's NVENC capabilities. Like the other facts it only tells a client
which controls to offer; the host still checks every request itself.

## Framing

Every message is an 8-byte header followed by `length` bytes of payload. On the
wire, header + payload travel inside one or more encrypted records (below); the
header is never sent in the clear.

```
offset  size  field
0       u8    type
1       u8    flags        (message-specific; 0 if unused)
2       u16   reserved     (0)
4       u32   length       payload length in bytes
8       ...   payload
```

Maximum payload length is 64 MiB; anything larger is a protocol error and the
receiver closes the connection. A receiver may accept less: the host takes
payloads of at most 4 KiB from a client (the largest client message,
CLIENT_HELLO, is under 300 bytes), because any peer can complete the handshake
without being paired.

## Handshake and pairing

Both sides own a long-lived X25519 identity key. Every connection runs a Noise
handshake that exchanges those keys encrypted and derives fresh,
forward-secret keys for the session. The first time a client talks to a host
it proves knowledge of the PIN the host displays with CPace, a PAKE, inside
that encrypted channel, and the host proves it back; the host then stores the
client's key and the client stores the host's, and later connections need no
PIN.

**Noise.** The handshake is `Noise_XX_25519_ChaChaPoly_SHA256` from the Noise
Protocol Framework, revision 34, with the prologue `"RLY4"` and an empty
payload in every message. Its three messages are the only cleartext ever sent;
each is prefixed by a `u32` length like every later record:

```
msg1  client -> host   "RLY4" | -> e                    36 bytes
msg2  host -> client   <- e, ee, s, es                  96 bytes
msg3  client -> host   -> s, se                         64 bytes
```

`"RLY4"` in front of msg1 is not part of the Noise message; it tells a v4
client from an older one (a host logs a 70-byte msg1 starting with `TDH2`, the
v3 client's, and closes). Lengths are exact: msg2 is the host's ephemeral key
(32), its identity key encrypted (32 + 16) and the empty payload's tag (16);
msg3 is the client's identity key encrypted (48) and a tag (16). Both sides
refuse a DH result of all zeros (a low-order key), which Noise itself allows.

A client that knows the host's identity must refuse a different key in msg2
(the host's key changed = someone else) and closes without sending msg3. The
host learns the client's identity only from msg3, so it says whether it knows
that key in SERVER_HELLO. Both sides keep `h`, the handshake hash after msg3
(32 bytes): pairing is bound to it.

**Records.** After msg3 every message travels as one or more records:

```
u32 length || Noise transport message (ChaCha20-Poly1305 ciphertext || 16-byte tag)
```

- A message (8-byte header + payload) is split into chunks of at most 65,519
  bytes, one record each, so `length` is at most 65,535 (Noise's largest
  message). A sender writes all of a message's records together.
- Each direction has its own key (Noise's Split: the client sends with the
  first, the host with the second) and its own counter, starting at 0 and
  incremented per record. The nonce is 4 zero bytes followed by the counter as
  a **little-endian** u64 (Noise's ChaChaPoly encoding); the associated data is
  empty.
- The receiver decrypts the first record of a message, which must hold at
  least the 8-byte header, and checks the header's `length` against its limit
  (Framing) before reading anything more. It then appends records until it has
  8 + `length` bytes. A record that runs past the end of its message, or that
  fails to decrypt, ends the session. A receiver may refuse a record from its
  length alone when it is longer than any message it accepts.

**Pairing.** The host sends SERVER_HELLO right after msg3. If it says
`paired = 0`, or the client does not know the host, the client pairs before
its CLIENT_HELLO by running CPace (draft-irtf-cfrg-cpace-21, cipher suite
CPACE-X25519-SHA512) in the initiator-responder setting, with the client as
the initiator (A) and the host as the responder (B):

| type | name         | direction      | payload |
|------|--------------|----------------|---------|
| 0xA0 | PAIR         | client -> host | `Ya` (32), optionally followed by `u8 client_name_len` and `client_name` (UTF-8) when SERVER_HELLO advertises `CAP_PAIR_NAME` |
| 0xA3 | PAIR_REPLY   | host -> client | `Yb` (32) `‖` `Tb` (32) |
| 0xA4 | PAIR_CONFIRM | client -> host | `Ta` (32) |
| 0xA1 | PAIR_RESULT  | host -> client | `u8 result`: 1 = paired, 0 = wrong PIN, 2 = rate-limited, followed by `u16 seconds` until pairing is accepted again. On 0 and 2 the host then closes. |
| 0xA2 | UNPAIR       | client -> host | empty. Sent instead of CLIENT_HELLO (it may follow msg3 without waiting for SERVER_HELLO): the host forgets the client's key, answers STREAM_STOP reason 5 (`UNPAIRED`) and closes. |

**Optional name extension (v4).** SERVER_HELLO may append one capability byte
after `paired`. Bit `0x01` is `CAP_PAIR_NAME` (bit `0x02`, `CAP_VIDEO_OPTIONS`,
is described under "Picture options", bit `0x04`, `CAP_TIMING`, under "Clock
sync and frame timing", bit `0x08`, `CAP_DISPLAY_SCALE`, under "Display
scale"); an absent byte means zero, and clients
ignore unknown bits. Only when that bit is set, a client sends
PAIR = `Ya[32] | u8 client_name_len | client_name_utf8`. The name is capped
at 255 UTF-8 bytes, truncated on a Unicode scalar boundary, without a terminator;
the largest payload is 288 bytes. The complete suffix, including its length
byte, is CPace ADa. An empty name has ADa `[0]`, distinct from legacy empty ADa.
Hosts reject inconsistent suffix lengths and invalid UTF-8.

Without the capability, clients send just the original 32-byte Ya and use
empty ADa. New hosts accept this legacy form too. A refused PIN must never
be retried automatically using another protocol variant. The Noise handshake,
protocol version, identities, existing pairings, ADb (empty), PAIR_REPLY,
PAIR_CONFIRM and PAIR_RESULT layouts are unchanged.

CPace's inputs and functions, byte for byte (`lv_cat` prefixes each part with
its LEB128 length, `prepend_len` does it for one part; draft appendix A.1):

```
PRS      the PIN's ASCII digits
sid      h
ADa      the complete optional name suffix, or empty for legacy PAIR
ADb      empty
CI       lv_cat("relay-v4", client identity key, host identity key)
gen_str  lv_cat("CPace255", PRS, zpad zero bytes, CI, sid)
         zpad = max(0, 128 - 1 - len(prepend_len(PRS)) - len(prepend_len("CPace255")))
g        Elligator 2 of the first 32 bytes of SHA-512(gen_str), bit 255 cleared
Ya, Yb   X25519(ya, g), X25519(yb, g); ya, yb are 32 random bytes
K        X25519(ya, Yb) = X25519(yb, Ya)
ISK      SHA-512(lv_cat("CPace255_ISK", sid, K) || lv_cat(Ya, ADa) || lv_cat(Yb, ADb))
mac_key  SHA-512("CPaceMac" || sid || ISK)
Ta, Tb   HMAC-SHA512(mac_key, lv_cat(Ya, ADa)), HMAC-SHA512(mac_key, lv_cat(Yb, ADb)), first 32 bytes each
```

Elligator 2 on Curve25519 (A = 486662, Z = 2, draft appendix A.5): decode the
input as a u-coordinate, v = -A / (1 + 2u²), and the result is v if
v³ + Av² + v is a square mod p, else -v - A, as its canonical 32-byte
little-endian encoding. An X25519 result of all zeros aborts the run. Tags are
compared in constant time; confirmation follows the draft's section 10.4.

The client checks `Tb` before it sends anything more. A mismatch means a wrong
PIN (or a host that is not the one it claims to be; the two look the same) and
the client closes without PAIR_CONFIRM. The host, on PAIR:

1. When pairing is rate-limited (5 failures per 10 minutes), answers result 2
   with the remaining wait before looking at `Ya`, so a locked-out guesser
   learns nothing about the PIN.
2. Counts the attempt as a failure at once, so a client that leaves after
   seeing `Tb` has still spent its guess.
3. Sends PAIR_REPLY and waits briefly for PAIR_CONFIRM; the client sends it at
   once.
4. On a valid `Ta`, takes back that one failure, stores the client's key and name,
   answers result 1 and then replaces its PIN. On an invalid `Ta` it answers 0
   and closes.

Proofs use the original wire bytes. Only after confirmation does the host
replace control characters with spaces and trim the name for storage and UI,
before sending success. A new unnamed pairing uses `Paired MacBook`; an
unnamed re-pair preserves an existing label, and a named re-pair updates it.
Names are display labels; identity and Forget use the public key, and a name
change does not affect the pairing digest. Existing `paired <IP>` labels
gain a name on a successful named re-pair or streaming CLIENT_HELLO.
Pair-only closes after success without CLIENT_HELLO or any display operation;
legacy hosts continue to learn the name on the first streaming connection.

Each attempt is one online guess: a run reveals nothing that would test other
PINs offline, `sid` ties it to this Noise session and CI to both identity
keys, so a relay in the middle cannot pass a run through. The host accepts a
PIN from an already-paired client too (a client that lost its copy of the host
key). A client that only tests `result == 1` keeps working. An unpaired client
that sends anything but PAIR or UNPAIR gets STREAM_STOP with reason 4
(`NOT_PAIRED`).

**Forgetting.** A client that drops a pairing sends UNPAIR as its first
encrypted message so both sides forget each other in one step; the host
answers STREAM_STOP with reason 5 whether or not it knew the client, then
closes. The client removes the host locally regardless of whether the host was
reachable (the host side can then be cleaned up with `relay-host paired
--forget <fingerprint>`). A client the host does not know that sends UNPAIR is
answered the same way, not with `NOT_PAIRED`.

The host forgets a client from its tray or with `relay-host paired --forget`.
There is no message for it: the client learns of it through the `pg` TXT value
(Discovery, above), or through STREAM_STOP reason 4 (`NOT_PAIRED`) if it was
streaming at the time, and should forget the host locally in either case.

**Legacy test vector.** Every secret is one byte repeated 32 times: client identity
0x11, client ephemeral 0x22, host identity 0x33, host ephemeral 0x44, `ya`
0x55, `yb` 0x66. PIN `"123456"`, host name `"Test PC"`, `paired = 0`. The
handshake messages are shown without their length prefix, and so are the
records: `rec_hello` is SERVER_HELLO (host to client, counter 0), `rec_pair`
is PAIR (client to host, counter 0), `rec_reply` is PAIR_REPLY (host to
client, counter 1) and `rec_confirm` is PAIR_CONFIRM (client to host,
counter 1).

```
msg1         524c59340faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20
msg2         ff2ee45601ec1b67310c7790404585ae697331eee1c1f8cf2419731c1fff3e6b5cda1c2d8029877d73fad62823946ccd0c5da35c129100f43d33a59cf19ea8fc8a34ab0906b247c442369fee33d074a3cd84501b7ddd1c5eb1e0902fdeea606b
msg3         f4e4988e97bdcbf0f799d02dd2242624bda72d200e97e322c4f723213896a31ebf3f7e0cea270326c10b7a70497b6dc220995f6d75f9fdc693ad73606f56b4b7
h            78c958b2116d50f7f7e07d8f7334849359c14d6e9d3524f8b091d25d172dfcbb
CI           0872656c61792d7634207b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13207b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14
g            4da8240a286e94f94e63fb7a308fafab75d5ba9625097ccc0960c08ee5510912
Ya           d2ff03377c6866e7910d272a562919d586cc30c289a7e93baa6a11d16ae58c4a
Yb           f9d2846618c6c5eba1b22562444d002b263dcea78848303ca2e07715f4044673
K            5cd19a85622eab280d34b347deec67c9143cacd11c2679f5f45bba50e7731a50
ISK          b5cff33f2f751fd6d89e0679a2db943b92b84c9a31347d94d396c35c70fc3393ed331f63baef05915514bf5d417487d42580a838927e2cbadd90dffe9e9b488a
Ta           3f1656c004be3c70b2928e9d59596b41c594b184fbdd0daa875ccf738fa95f66
Tb           424d696ffbb7e8ef252e742f3541191ca4842c8cedcfe31189c86ad24e9dafd8
rec_hello    799e0c48aae62c91b0554ec35f909866393910523f91db8612ce2ae07994640b3a3e8c
rec_pair     8746b8a0817bd1b7961cdc80a04a68e507a49cb60203a1be841663bf145d5dab7558f3a726bb4f9b1c454fb29b2cfa4fa4ca4a2793bb094b
rec_reply    af30f22934cf7e9ef62b1c7e1d0703f756607a55bafd4a03f1c4dfb29937acd2f8f21b6f273d0075ee41be91a2cfc9fb5046777cf311f82a69efb3e0cd08507c16ca3090fa04f5791da57849f85765950b99643b6896fbfb
rec_confirm  2fc518fc7bf0afdd9ed6dde4ac630eb08bdd61249b288e9329cef276b99f26732c0c6730e7d3050486b170e3a31d4d49ff313829fe5594a3
```

The vector was generated by the Swift client (Noise.swift, CPace.swift, which
are themselves checked against the cacophony and draft-21 vectors); the host's
`crypto::tests::v4_vector` reproduces every line.

**Named pairing vector.** Use the same inputs as above, with client name
`Aman’s MacBook Pro` (U+2019 apostrophe, 20 UTF-8 bytes) and empty ADb. The
generator, CI, h, Ya, Yb and K are unchanged. ISK and both confirmation tags
change. Rust `crypto::tests::named_pairing_vector` and Swift
`CryptoTests.testNamedPairingVector` reproduce these values:

```text
ADa          14416d616ee2809973204d6163426f6f6b2050726f
ISK          babe000cfe7c4fd314c375fed097aa1d24fe6378e76301176e789efc7d1028bc6b478776897e730bd39f59a00f4229e177eb7237545ba54c9fe9109b3eaab508
Tb           499bc005e3877364ce6002d9fcecf22d02d1a0f76019e9f6f042150add403315
Ta           921c83bc4d09122459355ac523326b048f5bae10859d4584543415d41b946e2d
```

## Session

```
client                                   host
  |------------------- TCP connect ------->|
  |------------------- msg1 -------------->|
  |<------------------ msg2 ---------------|
  |------------------- msg3 -------------->|   keys derived on both sides
  |<----------------- SERVER_HELLO ---------|   says whether the client is paired
  |------------------- PAIR --------------->|   only when not paired yet
  |<----------------- PAIR_REPLY -----------|
  |------------------- PAIR_CONFIRM ------->|   only when PAIR_REPLY checked out
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
The pairing exchange (PAIR, PAIR_REPLY, PAIR_CONFIRM, PAIR_RESULT) and UNPAIR
are handled normally without touching the running session. A pair-only client
may close after PAIR_RESULT. If the client sends CLIENT_HELLO
(the request to take over the display), it atomically competes for the one
display lease; if another client owns it, the host answers STREAM_STOP reason
6 (`BUSY`) and closes. A connection waiting for a PIN does not reserve the
display. The running session is never preempted; the client should show "in
another session" rather than retry in a loop.

## Host → client

| type | name           | payload |
|------|----------------|---------|
| 0x01 | SERVER_HELLO   | `u16 proto_version`, `u8 name_len`, `name` (UTF-8), `u8 paired` (1 when the host knows the client's identity key), optional `u8 capabilities` (`0x01` = `CAP_PAIR_NAME`, `0x02` = `CAP_VIDEO_OPTIONS`, `0x04` = `CAP_TIMING`, `0x08` = `CAP_DISPLAY_SCALE`; missing = 0, ignore unknown bits) |
| 0x02 | STREAM_START   | `u16 width`, `u16 height`, `u16 fps`, `u16 bitrate_mbps`, `u8 codec`, `u8 video_format` |
| 0x03 | CODEC_CONFIG   | parameter-set NAL units: repeated `u32 len` + NAL bytes (no start codes). HEVC: VPS, SPS, PPS. H.264: SPS, PPS. |
| 0x04 | FRAME          | one access unit: repeated `u32 len` + NAL bytes (no start codes, parameter sets and AUDs stripped). `flags & 0x01` = keyframe (IRAP). |
| 0x05 | CURSOR         | `i32 x`, `i32 y` (pixels, relative to the streamed display), `u8 visible`. Reserved for a future cursor-overlay path; currently the Windows cursor is composited into the video. |
| 0x06 | STREAM_STOP    | `u8 reason` (0 = host shutting down, 1 = encoder failed, 2 = display lost, 3 = bad version, 4 = not paired, 5 = unpaired at the client's request, 6 = busy with another client, 7 = selected bitrate exceeded the connection's sustained bandwidth) |
| 0x07 | PING           | `u64 host_time_us` |
| 0x08 | FRAME_TIMING   | optional telemetry for the immediately preceding FRAME: `u64 sequence`, `u32 capture_us`, `u32 encode_us`, `u32 frame_send_us`, `u32 network_rtt_us`. A duration of `0xffffffff` is unavailable. |
| 0x09 | TIME_REPLY     | answer to TIME_REQUEST: `u64 client_time_us` (echoed), `u64 host_receive_us`, `u64 host_send_us` (Clock sync and frame timing, below) |
| 0x0A | FRAME_TIMING_EXT | after every FRAME, in place of FRAME_TIMING, once the client has sent a TIME_REQUEST: 68 bytes (Clock sync and frame timing, below) |

`codec`: 1 = H.264, 2 = HEVC, 3 = AV1 (reserved).

`video_format` (a reserved 0 before picture options) describes the stream the
host configured:

| bits | meaning |
|---|---|
| 0–1 | encoder quality used: 1 = fastest, 2 = balanced, 3 = best; 0 = not reported (older hosts) |
| 2 | the stream is 4:4:4 |
| 3 | the stream is 10-bit |
| 4–7 | 0 |

It is for status and logs: a decoder reads chroma format and bit depth from the
SPS, which stays authoritative (a host that has to fall back to another encoder
after STREAM_START encodes 8-bit 4:2:0 without sending a new STREAM_START).

FRAME payloads are already in the length-prefixed layout that `CMSampleBuffer`
and `hvcC`/`avcC` expect (4-byte NAL lengths), so the client can hand them to
VideoToolbox without rewriting. A new CODEC_CONFIG may arrive before any
keyframe; the client must rebuild its format description when the bytes differ
from the last one it saw.

`FRAME_TIMING` is sampled diagnostic data and does not alter the video stream.
Sequence numbers start at zero for each session and identify the preceding FRAME;
the host need not send telemetry for every frame. The host reports NVENC's capture and encode
durations; a duration it cannot measure is sent as unavailable. The client
estimates one-way network latency as half the measured ping round trip. Existing
clients can ignore this message and continue decoding the preceding FRAME normally.
The host sends FRAME_TIMING after every fourth FRAME, and FRAME_TIMING_EXT
instead (after every FRAME) once the client has sent a TIME_REQUEST.

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
| 0x81 | CLIENT_HELLO | `u16 proto_version`, `u16 width_px`, `u16 height_px`, `u16 refresh_hz`, `u16 bitrate_mbps`, `u8 flags`, `u8 codecs`, `u8 name_len`, `name`, optional `u8 encoder_quality`, `u8 video_flags` (Picture options, below), optional `u16 display_scale` (Display scale, below) |
| 0x87 | PONG         | echo of the PING payload |
| 0x88 | TIME_REQUEST | `u64 client_time_us` (the client's clock; opaque to the host). Only to a host with `CAP_TIMING`. |
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

**Picture options.** When SERVER_HELLO has `CAP_VIDEO_OPTIONS` (`0x02`), a
client may append two bytes after `name`:

| offset after `name` | type | field |
|---|---|---|
| 0 | u8 | `encoder_quality`: 0 = the host's default, 1 = fastest, 2 = balanced, 3 = best |
| 1 | u8 | `video_flags`: bit 0 = wants 4:4:4, bit 1 = wants 10-bit; other bits 0, ignored by the host |

- Clients send the extension only to a host with the capability. Hosts have
  always ignored bytes after `name`, so an older host is unaffected. A missing
  byte counts as 0.
- `encoder_quality` picks the encoder preset (NVENC P1 / P4 / P6, all with
  ultra-low-latency tuning). An
  explicit host `--quality` overrides it, as `--bitrate` overrides
  `bitrate_mbps`. With neither, or with a value the host does not know, the
  host uses fastest.
- The host applies a flag only to an HEVC session, and only when its encoder can
  do it (the capability `enc` advertises).
  H.264 sessions ignore both flags. 4:4:4 is HEVC Range Extensions (profile
  Rext) at 8 or 10 bits; 10-bit 4:2:0 is Main 10. The color description is the
  same in every format: BT.601 matrix, BT.709 primaries and transfer, limited
  range.
- A client should ask only for what it decodes. STREAM_START's `video_format`
  reports what the host applied.
- 4:4:4 needs more bits for the same luma quality. The bandwidth check (stop
  reason 7) is the same for every format.

**Display scale.** When SERVER_HELLO has `CAP_DISPLAY_SCALE` (`0x08`), a
client may append a `u16` after the picture options, so it always sends the
two picture-option bytes first (0, 0 when it wants nothing from them):

| offset after `name` | type | field |
|---|---|---|
| 2 | u16 | `display_scale`: Windows' scale for the virtual display, in percent; 0 = leave Windows' own choice |

- Clients send it only to a host with the capability; a host without it
  ignores the bytes. Missing, or only one byte of it, means 0.
- The host snaps the value to the nearest scale Windows offers (100, 125, 150,
  175, 200, 225, 250, 300, 350, 400, 450, 500; a tie goes to the smaller one)
  and then to what Windows allows for that monitor. Values outside 100–500 are
  ignored, as 0.
- The host sets it after the virtual display becomes the only display and
  before the first frame, and puts the previous value back before the display
  leaves the desktop. It never changes a physical monitor's scale: a host
  streaming an existing monitor (`--no-vdd`) ignores the field. The value is
  cosmetic: a host that cannot set it still streams.
- What a client should send: the ratio of the requested pixel size to the
  size the user sees on the client's screen, in points, × 100. A Retina Mac
  at its native pixel size sends 200; at 0.75 of it, 150; a 1× screen, 100.
  The host cannot derive this from the pixel size alone.

Keys are sent as HID usages so the protocol is platform-neutral; the client
decides how macOS modifiers map (default: ⌘→Ctrl, ⌥→Alt, ⌃→Win) and the host
translates HID usages to PS/2 scan codes for `SendInput`.

## Clock sync and frame timing

With the two clocks related, a client can measure a frame from DWM's present
on the PC to its own screen, and an input event to `SendInput`.

**Capability and opt-in.** A host with SERVER_HELLO capability `0x04`
(`CAP_TIMING`) answers TIME_REQUEST. A client sends TIME_REQUEST only to such
a host. The host sends TIME_REPLY and FRAME_TIMING_EXT only to a client that
has sent a TIME_REQUEST, so neither side ever receives a type it does not
know. CLIENT_HELLO is unchanged.

**The host clock.** Every host time below is QueryPerformanceCounter in
microseconds (`QPC × 1 000 000 / frequency`, as u64): the same base as DXGI's
`LastPresentTime`, which the host converts with the same function. It never
steps; its zero is arbitrary, so a client uses only differences and the
offset. `u64::MAX` is "unknown". (PING's `host_time_us` is a different
clock and is not comparable.)

**Parsing.** TIME_REQUEST, TIME_REPLY and FRAME_TIMING_EXT are read as "at
least this long; ignore the rest", so they can grow. (Clients built before
this section end the session on a FRAME_TIMING that is not exactly 24 bytes,
which is why FRAME_TIMING_EXT is a new type.)

**TIME_REQUEST / TIME_REPLY.** The host stamps `host_receive_us` as soon as
its reader has the request decrypted, and `host_send_us` immediately before
it writes the reply. Replies are written by the thread that sends video,
before its next FRAME, so a reply can wait up to a frame interval (longer
while capture is recovering and no frames flow); the two stamps take that out
of the math. The host keeps at most 16 unanswered requests and drops the
rest. With `t1 = client_time_us`, `t2 = host_receive_us`,
`t3 = host_send_us` and `t4` the client's clock when the reply arrived:

- `delay = (t4 − t1) − (t3 − t2)`
- `offset = ((t2 − t1) + (t3 − t4)) / 2` (signed; host minus client)

A client keeps the last few samples and uses the offset of the one with the
lowest delay; the client time of a host stamp `h` is `h − offset`. The Mac
(and `probe --timing`) sends five requests 50 ms apart after STREAM_START,
then one a second, and keeps eight samples.

**FRAME_TIMING_EXT** (`0x0A`). From the host's first TIME_REPLY on, it
follows every FRAME instead of FRAME_TIMING. 68 bytes:

| offset | field | type | meaning |
|---|---|---|---|
| 0 | `sequence` | u64 | as FRAME_TIMING |
| 8 | `present_us` | u64 | DWM's `LastPresentTime` of the newest desktop frame in this picture; `u64::MAX` when the tick re-encoded unchanged content or only the cursor moved |
| 16 | `submit_us` | u64 | when `NvEncEncodePicture` returned for this picture |
| 24 | `sent_us` | u64 | after the FRAME was written to the socket |
| 32 | `capture_us` | u32 | as FRAME_TIMING |
| 36 | `encode_us` | u32 | as FRAME_TIMING |
| 40 | `send_us` | u32 | as FRAME_TIMING's `frame_send_us` |
| 44 | `copy_gpu_us` | u32 | GPU time of the desktop → composition → encoder-input copies; `0xffffffff` (always, for now) |
| 48 | `network_rtt_us` | u32 | as FRAME_TIMING |
| 52 | `inputs_applied` | u64 | input messages (`0x90`–`0x93`) the host handled since the client's first TIME_REQUEST |
| 60 | `last_input_us` | u64 | when the `inputs_applied`-th of them was handled (after `SendInput` returned); `u64::MAX` before any |

On a fresh picture `present_us ≤ submit_us ≤ sent_us`. `inputs_applied`
counts every input message read after the first TIME_REQUEST, including ones
not applied (Observe, or a payload too short); a client counts every input
message it sends after its first TIME_REQUEST, and TCP's ordering makes the
N-th on each side the same message. The host updates the count and its time
together. Useful differences: `submit_us − present_us` (content age at
encode), `sent_us − submit_us` (encode + send), the client's receive time
minus `sent_us − offset` (one way), its present time minus `present_us −
offset` (desktop → screen), and `last_input_us − offset` minus the client's
send time of input N (input → applied).

## Notes

- The first host encoder (ffmpeg, milestone 1) learned an access unit was
  complete only when the next AU's delimiter arrived, which cost one frame
  interval of latency. The in-process NVENC encoder (milestone 5) removed that;
  the ffmpeg path itself was removed on 2026-10-17.
- Version negotiation: both sides send `proto_version` (currently 4) inside the
  hellos; the handshake's own version is the `RLY4` in front of msg1 (and the
  Noise prologue). A host that
  doesn't support the client's version sends STREAM_STOP and closes.
