# Handoff for the PC session: clock sync and per-frame timing

**Status (2026-10-18): done on both sides.** The Mac half landed in
`cac14a2` (fakehost `f5c0716`) with no wire change, and a real-PC session
over the cable measured Desktop → screen p50 14.9 ms (details: `AGENTS.md`
Status, "Clock sync + frame timing"). One deviation from the Mac-side notes
below: Sent → received ends when the whole frame has arrived, not at its
first record, since `sent_us` is stamped after the last byte is written.
Earlier status: host, `probe` and `docs/PROTOCOL.md` done and installed. Every byte, value and name below shipped
as written; three details were pinned down while implementing and are
marked *(as built)*. The spec is now PROTOCOL.md "Clock sync and frame
timing". Verified on Windows: fmt, 223 unit tests + the probe integration
test, clippy `-D warnings` on 1.98 and 1.99, release build; `probe --timing`
against an elevated `--no-vdd` dev host on loopback (offset 0–4 µs, min
delay 35–66 µs, no fresh frame out of order, re-encoded and cursor-only
ticks `u64::MAX`, inputs counted 1:1, input → applied p50 0.13 ms); installed
with `install-host.ps1 -SkipDriver`, hash `107FDB55…1C8B84F3`, and the
service advertises capabilities `0x07`. A streaming `probe --timing --wiggle`
against the service at 3024×1964@120 (virtual display) gave the same picture:
offset 5 µs, min delay 42 µs, 534 fresh frames all in order, 214 `u64::MAX`,
inputs 369 sent / 368 reported with one in flight, layout restored. Evidence:
`AGENTS.md` Status.

The Mac already measures what it can alone (frame transfer estimate, decrypt,
input → sent; `AGENTS.md`, Latency HUD). This handoff is the part that needs
the PC's clock. Order as AGENTS.md says: host and `probe` first, then
`docs/PROTOCOL.md`, then the Mac. If you change a byte, a value or a name,
change it here too so the Mac session builds against what you shipped.

## Why

Today every number is per side. The PC reports capture + encode + send
durations; the Mac reports receive → decode → screen; the network figure is
half a ping round-trip sampled once a second. Nothing measures a frame
end to end, and these are invisible:

- DWM present → the capture tick (the phase servo aims for 0.8 ms; the real
  average is only in `host.log` as "desktop frame age at submit");
- re-encoded frames: the Mac counts them as fresh, so a fast pipeline can be
  showing old content;
- the frame's one-way trip, including both kernels' buffering;
- input from the Mac's socket to `SendInput`.

With the two clocks related (offset known to ~±0.1–0.3 ms on a cable), the
Mac can show **DWM present → on the Mac's screen**, measured, plus each
piece of it, and **input event → applied on the PC**.

## Proposal

### 1. Capability

SERVER_HELLO capability bit **`0x04` = `CAP_TIMING`** (next to `0x01`
`CAP_PAIR_NAME`, `0x02` `CAP_VIDEO_OPTIONS`). Old Macs ignore unknown bits.
The Mac sends TIME_REQUEST only to a host that advertises it; the host sends
TIME_REPLY and FRAME_TIMING_EXT only to a client that has sent a
TIME_REQUEST. No CLIENT_HELLO change, and neither side ever receives a type
it does not know.

### 2. The host clock

One clock for everything below: **QPC in microseconds**
(`QueryPerformanceCounter * 1_000_000 / frequency`, as `u64`), the same base
as DXGI's `LastPresentTime`, so DWM's present converts with the same
function. Never `SystemTime` (PING uses it today; it can step). The value is
opaque to the Mac: only differences and the offset matter.

### 3. Clock sync messages

| type | name | direction | payload (big-endian) |
|---|---|---|---|
| `0x88` | TIME_REQUEST | client → host | `u64 client_time_us` (opaque to the host) |
| `0x09` | TIME_REPLY | host → client | `u64 client_time_us` (echoed), `u64 host_receive_us`, `u64 host_send_us` |

- `host_receive_us`: stamped in `read_loop` as soon as `rx.recv()` returns
  the request.
- `host_send_us`: stamped immediately before the reply is written.
- The writer belongs to the `pump` thread. `read_loop` can queue the request
  (a `Mutex<Vec<…>>` or channel) and `pump` sends replies at its next
  iteration. The wait in between (up to a frame) is fine: the reply carries
  receive and send times separately, and NTP's math removes host processing
  time.
- Send replies before the next FRAME, so a long frame write does not delay
  them more than necessary.
- *(as built)* The host keeps at most 16 unanswered requests and drops the
  rest. While capture is recovering (no frames), replies go out at the
  recovery loop's pace, about once a second; the stamps make that harmless.

The Mac does the math (described under Mac side), sending a few requests at
stream start, then one a second.

### 4. FRAME_TIMING_EXT

| type | name | direction |
|---|---|---|
| `0x0A` | FRAME_TIMING_EXT | host → client |

Once the client has sent a TIME_REQUEST, send this **after every FRAME, in
place of FRAME_TIMING**, which keeps its current meaning for other clients.
*(as built)* The switch happens when the host writes its first TIME_REPLY,
so that reply always arrives before the first FRAME_TIMING_EXT.
Payload, 68 bytes, big-endian:

| field | type | meaning |
|---|---|---|
| `sequence` | u64 | the same counter FRAME_TIMING uses |
| `present_us` | u64 | DWM's `LastPresentTime` of the newest desktop frame folded into this picture, host clock; `u64::MAX` when the tick re-encoded an unchanged image (or only the cursor moved) |
| `submit_us` | u64 | host clock when `NvEncEncodePicture` returned *(as built)* |
| `sent_us` | u64 | host clock after `send_nals(FRAME)` returned |
| `capture_us` | u32 | as FRAME_TIMING |
| `encode_us` | u32 | as FRAME_TIMING |
| `send_us` | u32 | as FRAME_TIMING |
| `copy_gpu_us` | u32 | GPU time of the desktop → composition → slot copies from D3D11 timestamp queries; `0xffffffff` when unavailable |
| `network_rtt_us` | u32 | as FRAME_TIMING |
| `inputs_applied` | u64 | input messages (`0x90`–`0x93`) handled since the first TIME_REQUEST |
| `last_input_us` | u64 | host clock when the `inputs_applied`-th one was handled; `u64::MAX` before any |

Notes:
- `present_us` comes from `pending_present_qpc`, which the capture loop
  already keeps for `CaptureInfo.age`. Convert with the same QPC → µs
  function, not `qpc_age`. It has to travel with the picture through
  `CaptureInfo` → `CompletedOutput` → `EncoderTiming` to `pump`.
- `copy_gpu_us` is the least valuable field (expected ~0–0.3 ms, and
  mostly inside "encode" already). Leave it `0xffffffff` at first if the
  queries are awkward. If you do add them, use `TIMESTAMP_DISJOINT` +
  `TIMESTAMP` queries read back with `GetData(…, DONOTFLUSH)` a frame or more
  later. Never wait on them (see "Never block inside AcquireNextFrame";
  the same device lock applies).
- `inputs_applied` counts every input message `read_loop` handles,
  **including** ones with no injector (Observe) and ones whose length check
  fails. The Mac counts every input message it sends after its first
  TIME_REQUEST; TCP's ordering makes the two counts the same messages. Keep
  the pair consistent (a `Mutex<(u64, u64)>` or one atomic word for each
  with count stored last).
- 68 bytes × 120 fps ≈ 8 KB/s: negligible next to the video.

**Parsing rule for both sides, learned the hard way:** accept a payload
**at least** this long and ignore the rest. Today's Mac rejects any
FRAME_TIMING that is not exactly 24 bytes and ends the session, which is why
this is a new type rather than a longer FRAME_TIMING.

### 5. `probe`

`probe --timing`: send TIME_REQUESTs as the Mac will (below), print the
offset and minimum delay estimate once a second, and per frame
`present → submit`, `submit → sent`, and `sent → received` converted with
the offset. On loopback the two clocks are the same QPC, so the offset
should be ~0 and `sent → received` tiny: a good self-check of the math.

## Mac side (for the Mac session after the host lands)

- Parse the three messages, `>=` lengths.
- `ClockSync` (pure, unit-tested): for each reply, `t1` = client send,
  `t2` = host receive, `t3` = host send, `t4` = client receive;
  `delay = (t4 − t1) − (t3 − t2)`, `offset = ((t2 − t1) + (t3 − t4)) / 2`
  (signed). Keep the last ~8 samples and use the offset of the one with the
  lowest delay. Mac time of a host stamp `h` is `h − offset`.
- Send 5 TIME_REQUESTs 50 ms apart after STREAM_START, then one a second.
  Clock drift is tens of ppm (a few µs/s), so once a second is plenty.
- New HUD/report rows: **Desktop → screen** (`present_us` → Metal's
  `presentedTime`; reused frames skipped), **Content age**
  (`submit_us − present_us`), **Sent → received**
  (`sent_us` → the frame's first record decrypted, which also measures
  what the Frame transfer estimate approximates), **Input → applied**
  (event timestamp of input message N → `last_input_us`). Keep Network
  (RTT/2) as a cross-check for a while.
- fakehost: implement both messages with its own clock plus an artificial
  offset, so the math is tested against a known answer.

## Edge cases

- **No sync yet** (fewer than one reply, or replies with absurd delay over
  ~50 ms): show –– rather than a guess.
- **Clock steps:** QPC does not step. The Mac's clock is `systemUptime`,
  which does not either; sleep ends the session anyway.
- **Asymmetric paths** (Wi-Fi, VPN): the offset error is up to half the
  asymmetry; label the rows measured-with-sync and keep showing delay so
  a bad link is visible.
- **Old PC with a new Mac, or the reverse:** nothing changes, by the
  capability and request rules above.

## Acceptance

PC session:
- Unit tests: payload round trips for the three messages, `>=` parsing, the
  input counter's count/time consistency, QPC conversion.
- `cargo test`, `cargo clippy --all-targets -D warnings`, release build.
- `probe --timing` against a `--no-vdd` dev host: offset ~0 on loopback,
  `present ≤ submit ≤ sent` on every fresh frame, `present_us` = `u64::MAX`
  on re-encoded ones (static desktop), inputs counted with `probe` sending
  moves.
- An installed-service probe run like the picture-options checks.
- `docs/PROTOCOL.md` updated in the same change as the host.

Then the Mac session: tests for `ClockSync` against known offsets, fakehost
with an artificial offset, and a real-PC session reporting the new rows.
