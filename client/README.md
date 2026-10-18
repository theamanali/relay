# Relay for Mac (client)

The Mac half of [Relay](../README.md): a native SwiftUI app that finds Relay PCs
over Bonjour, pairs with them, and shows the PC's virtual monitor full screen.
It decodes the stream in hardware with VideoToolbox, draws it with Metal, and
sends the keyboard and trackpad back. It uses only Apple frameworks (SwiftUI, AppKit,
Network.framework, CryptoKit, VideoToolbox, Metal); there are no third-party
packages.

- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Using it](#using-it)
- [Command-line flags](#command-line-flags)
- [Files](#files)
- [Testing](#testing)
- [How it works](#how-it-works)
- [Limitations](#limitations)

## Requirements

- An Apple silicon Mac (M1 or later) on macOS 14 or later. The minimum comes
  from Observation, used by the SwiftUI interface. Intel Macs are not supported.
- Metal and hardware H.264 or HEVC decoding are required; there is no software
  decoder or AVSampleBufferDisplayLayer fallback.
- The Swift 6.0 toolchain or later (Xcode or the Command Line Tools).
- Optional: Xcode's `actool`, which `bundle.sh` uses to compile the layered app
  icon. Without it the bundle gets the flat `Relay.icns`.

## Build and run

```sh
cd client
swift run Relay                 # development build, straight from the package
./bundle.sh && open Relay.app   # a real app bundle
```

`bundle.sh` builds a release binary and wraps it in `Relay.app`. It copies
`Info.plist`, compiles the icon, stamps `CFBundleVersion` with the commit count
(About shows "0.1.0 (134)", for example) and ad-hoc signs the bundle so macOS
attributes the Local Network permission prompt to it. Allow that prompt on first
launch, or Relay can't see the PC. It's under System Settings → Privacy &
Security → Local Network.

Release signing is configurable: set `RELAY_SIGN_IDENTITY` to a Developer ID
Application identity and optionally `RELAY_NOTARY_PROFILE` to an existing
`notarytool` keychain profile. Signing and notarization errors fail the build.
Without these variables the reproducible local build is ad-hoc signed, arm64
only, and is not notarized. The binary declares the installed SDK separately
from its macOS 14 runtime minimum. Bundle ID and persisted pairings are unchanged.

## Using it

### The PC list

Relay opens a small window listing the PCs it finds, under **Paired** and
**Available**. The window keeps the same size with zero or one PC, grows for
longer lists, and scrolls past five PCs.
Paired says "No paired devices yet" until a PC is paired, and Available shows
"Searching for other PCs…" while no unpaired PC is around, since Relay keeps
searching. Click a section's title to collapse or expand it (once it lists two
or more PCs). With no PC at all
the list shows "No PCs Found" with a spinner and what to do on the PC. Each row shows the link the connection will use: Ethernet, Wi-Fi,
or Direct cable when the PC gave itself a 169.254 address. Hovering a PC shows a
card with its Windows version, CPU, RAM, GPU, its address on each shared link
and its key fingerprint.

If a PC's worker crashes, Relay refreshes discovery after its row disappears
or a picker connection cannot reach it. A returning PC keeps its saved
pairing; reopening Relay or entering the PIN again should not be necessary.

- **Pair** (an available PC): enter the 6-digit PIN from the PC's tray icon. The
  PC moves to Paired; nothing is streamed yet. A wrong PIN reopens the sheet,
  and after too many the sheet says how long the PC will refuse them.
  Updated hosts learn this Mac's computer name immediately after successful
  pairing, so their Forget submenu can name it before the first stream. Older
  v4 hosts learn the name on the first Connect.
- **Connect** (a paired PC; also Return or a double-click): progress shows in the
  footer, the button becomes **Cancel**, and the full-screen window opens with
  the first decoded frame. When the PC would be reached over Wi-Fi, Relay first
  asks whether to continue: Wi-Fi works, but a direct Ethernet cable is the
  best connection. "Don't ask again" turns the question off. When the session ends, the list comes back with the
  same PC selected.
- A PC that is streaming to another Mac still allows Pair and Forget. Connect
  says "The PC is in another session" right away instead of taking over.
- A PC that vanished without saying goodbye (cable pulled, power cut) can stay
  listed for up to two minutes, until Bonjour's cache expires. Connecting to such
  a row gives up after 12 seconds with "Couldn't reach the PC", and Relay asks
  Bonjour to re-check the record, so the row disappears shortly after.

A row's context menu, and the **PC** menu for the selected row, have:

| item | shortcut | what it does |
|---|---|---|
| Connect / Pair | ⌘↩ | Same as the footer button. |
| Rename | ⌘R | Edit the name in place, like Finder. The nickname is stored on this Mac only; an empty name means the PC's own. |
| Revert Name to "‹PC name›" | ⇧⌘R | Shown while a nickname is set. |
| Forget | ⌘⌫ or Delete | Ask the PC to remove the pairing, and remove it here regardless. If the PC doesn't confirm, a sheet explains the failure and how to remove it through the PC's tray menu or `relay-host paired --forget`. |

### Picture settings

The footer has a resolution popup (native, 75% or 50% of the screen the window
is on, shown in pixels) and a refresh control with that screen's top rate and
60 Hz (120/60 on a ProMotion MacBook, 144/60 or 165/60 on such a monitor;
hidden on a 60 Hz screen). Both follow the window when it moves to another
display. The **View** menu mirrors both and adds a **Bitrate** submenu: Automatic
(showing what it would ask for) and presets.
The **Settings** gear in the footer opens a grouped pane (Video, Latency,
Input) of switches, laid out like System Settings:

- **Bitrate**: **Automatic bitrate** is on by default: each frame gets the share 120 Mbps gave
  Native at 120 Hz on a 14-inch MacBook Pro, so 60 Hz or a smaller size asks
  for less (20–200 Mbps), capped at 80 Mbps over Wi-Fi. Over a gigabit cable
  every 120 Mbps costs about 1 ms of transfer per frame. Switch it off to
  set a value of your own with the logarithmic slider (1–1000 Mbps) or the
  field; while it is on they are greyed out and show the automatic value.
  Switching it on again goes back. A value chosen before Automatic existed is kept.
- **Encoder**: Fastest (default), Balanced or Best quality, the PC's NVENC
  preset (P1 / P4 / P6). Better quality takes the PC longer per frame.
- **Full color (4:4:4)**: full color resolution, so colored text and thin
  colored lines stay sharp; needs more bitrate. Off by default.
- **10-bit color**: smoother gradients with less banding. Off by default.

  These three need the PC to offer them (its Relay advertises `enc` once
  updated, see `docs/VIDEO-OPTIONS-HANDOFF.md`) and, for the color options,
  this Mac to decode them in hardware; otherwise they are greyed out and say
  why.
- **VSync**: prevents tearing but adds up to a frame of delay.
  Off by default and switchable mid-session.
- **Show latency overlay**: a small HUD drawn into the stream's corner. Its
  headline is how far behind the PC your screen is (PC → your screen, measured
  across both machines; a PC without clock sync shows the Mac's own share,
  receive → screen), with frame rate, p95, skipped frames per second when
  there are any, and a sparkline.
  ⌃⌥⌘L cycles Off → Compact → Detailed; Detailed adds where the time goes: a
  bar split into PC, Network and Mac, each with its parts (image age and
  encode & send; one-way network; decode and display), then input → PC
  and the stream as rows (Video, Picture, Display when VSync is on,
  Link, and Data: the video actually arriving against the bitrate asked for,
  e.g. 48 of 120 Mbps). Also View ▸ Latency
  Overlay. Clock offset, ping estimate, frame transfer, decrypt and the
  counters are in the session report, not the HUD. It does
  not slow the stream: it is part of the video frame, not a window over it.
  It appears 3 seconds into a session: start-up frames are left out of every
  number, the session report's included.
  When a session ends with it on, the **session report** opens on the screen
  you streamed on (View ▸ Last Session Report any time). **Summary** leads
  with the HUD's header for the whole session (the median, p95 under it;
  frames shown, the share skipped under that), then the median per second
  over the session (red above the budget, as in the HUD, so a slow stretch
  shows when it happened), every frame as a histogram with the share over
  the budget, the latency split by stage (PC, Network, Mac), input → PC
  and the data received (total, and average against the bitrate asked
  for). **Details**
  swaps those for every stage's p50/p95/p99/max, grouped like the Summary
  (Desktop → screen, then PC, Network, Mac and Input), and the frame
  counters, link rate and clock estimate as label/value rows. The ping
  estimate (RTT/2) is listed only for a PC without clock sync. Copy puts everything on the clipboard as Markdown. Three
  of its rows are measured on the Mac alone: **Frame
  transfer (est.)** is a frame's size over the rate its later records
  arrived at (frames that fit one record, or that were already buffered,
  are skipped), **Decrypt** is the time spent opening its records, and
  **Input → sent** runs from the `NSEvent` timestamp to the socket.
- **Show session report on disconnect**: off by default; turn it on to open
  the report by itself when a session ends, whether or not the latency
  overlay was on (latency is measured either way). View ▸ Last Session
  Report opens it any time.
- **Control the PC**: whether your keyboard and pointer go to the PC; off
  watches only (also PC ▸ Control / Observe and ⌃⌥⌘K). The two options below
  apply only while it is on.
- **Mac-style modifier keys**: on by default, ⌘ is Ctrl, ⌥ is Alt and ⌃ is the
  Windows key, so ⌘C copies; off maps them by position (below). The note under
  it shows the mapping currently in use.
- **Natural scrolling**: content tracks finger movement on the PC. Follows this
  Mac's own setting until changed here.

All of it is remembered between launches. The matching command-line flag
overrides it for one launch.

### During a session

| shortcut | what it does |
|---|---|
| ⌃⌥⌘Q | Leave the session and return to the list (quits in `--host` mode). |
| ⌃⌥⌘K | Switch between controlling and observing the PC; also in the PC menu. |
| ⌃⌥⌘L | Cycle the latency overlay: off, compact, detailed. |

Everything else is sent to the PC, including ⌘ shortcuts, except ⌘Tab, ⌘Space
and the Fn media keys, which macOS keeps. The modifier mapping:

| Mac key | `mac` (default) | `physical` |
|---|---|---|
| ⌘ | Ctrl | Alt |
| ⌥ | Alt | Windows |
| ⌃ | Windows | Ctrl |

`mac` keeps Mac habits working (⌘C copies); `physical` sends keys by where they
sit on the keyboard. The Windows cursor is part of the video, so a mouse plugged
into the PC and the Mac's trackpad move the same pointer. For the lowest input
latency, as in games, plug the mouse, keyboard or controller into the PC. While the stream is
up, the Mac's display won't sleep and the screen saver won't start; closing the
lid still sleeps.

### When the PC forgets this Mac

If someone uses **Forget** in the PC's tray, the PC's advertised pairing digest
(`pg`) changes. Relay notices within seconds, checks with a handshake-only
connection that never touches the PC's display, moves the row to Available and
shows "PC forgot this MacBook". The same happens if a Connect, or a running
session, is told the Mac isn't paired.

## Command-line flags

```sh
swift run Relay --help
Relay.app/Contents/MacOS/Relay --help     # the bundled app; `open --args` hides the output
```

| flag | meaning |
|---|---|
| `--host <addr[:port]>` | Skip the list and Bonjour and connect straight to this address. Re-dials when the connection drops: after 1 s, or 5 s if the PC was busy. |
| `--pin <digits>` | PIN to pair with (otherwise Relay asks). |
| `--scale <f>` | Ask for `f` × the native pixel size; 0.75 and 0.5 keep the aspect ratio. |
| `--max-fps <n>` | Cap the refresh rate asked for (default: the screen's top rate). |
| `--bitrate <1…1000>` | Video bitrate in Mbps (default 120). |
| `--modifiers mac\|physical` | Keyboard mapping (above). |
| `--no-input` | Observe only. |
| `--latency-stats` | Start with the latency overlay on (compact, unless detailed was chosen). |
| `--metal-vsync` | Enable VSync for this launch, as the setting does: no tearing, slightly more latency. |
| `--codec h264\|hevc` | Offer the PC only this codec (it picks HEVC when both are offered). For latency measurements; H.264 has not been measured yet. |
| `--render-icons <dir>` | Write the PC's tray icons and exit (see [Icons](#icons)). |
| `--render-app-icon <dir>` | Write the Mac app icon and exit. |

## Files

`~/Library/Application Support/Relay/` (moved automatically from the old
`TravelDisplay` folder):

| file | what |
|---|---|
| `identity.key` | This Mac's long-term X25519 key (mode 600). |
| `hosts.txt` | Paired PCs: public key and the PC's name. A PC counts as paired only if the key it advertises is in this file. |
| `nicknames.txt` | Names given with Rename. |
| `verified-digests.txt` | The last pairing digest each PC was confirmed with. |

The picker and session settings are in the app's user defaults.

## Testing

On 2026-10-10, the Swift 6 build passed 107 tests on Apple silicon/macOS 27.0,
including model selection/rename, one-shot and invalidated PIN prompts and
renderer generation checks. The isolated real-HostConnection/fakehost suite
also passed. CI now requests arm64 `macos-14` and `macos-latest`, prints the
actual OS/toolchain, runs fakehost and verifies the release bundle/signature.
GitHub's latest runner is not necessarily Apple's latest stable OS; see the
[runner documentation](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Pending release/hardware checks are tracked in
[platform implementation status](../docs/PLATFORM-REVIEW.md#implementation-status).


```sh
swift test
./Tools/test-pair-name.sh
```

The unit tests cover:

- the crypto: the [protocol v4 test vector](../docs/PROTOCOL.md) shared with
  the Rust host (a full pairing transcript, through the app's own handshake
  and record code), Noise XX against the published cacophony vector, CPace
  against the vectors in draft-irtf-cfrg-cpace-21, and the field arithmetic
  behind CPace's PIN-to-point map against big-integer reference values;
- message parsing, record splitting at 65,519 bytes and reassembly;
- pairing-name capability negotiation, Unicode-safe name truncation, malformed
  names, the shared named CPace vector and name tampering;
- the picker's row model, pairing classification and the debouncer that tells a
  PC's goodbye from a cable being unplugged;
- the pairing-check scheduler, Bonjour reconfirm, and bounded discovery
  recovery after a lost row or failed dial;
- stream mode and bitrate selection, remembered settings and footer text;
- latency statistics and the newest-frame mailbox;
- offscreen Metal renders of synthetic frames (colour range, orientation,
  letterboxing).

`Tools/test-pair-name.sh` also covers real VerifyTask success, forgotten state
and a withheld greeting deadline: one completion, no streaming request. It
builds fakehost and a small harness using the real
`HostConnection`. It checks pair-only (named, legacy host, busy host, empty
name, Unicode truncation, controls and emoji), wrong PIN, rate limit without a fallback retry,
already-paired, verify-only, UNPAIR and pair-then-stream. Forget runs through
the actual `UnpairTask`, including a busy host, no confirmation before timeout,
and a changed identity refused before msg3. Its temporary fixed
Foundation home keeps identities and pairings isolated from the app's state;
it asserts that isolation before constructing a client and deletes it on exit.
No PC, display, installed service or real pairing is touched.

### Worker-crash rediscovery (finding 6)

Diagnosed on the real PC over the home LAN on 2026-10-17 Pacific
(2026-10-18 UTC). The service PTR never left `dns-sd -B`. After a mid-session
worker kill, `dns-sd -L` resolved the replacement worker with the same `pk`
and `pg`, while Relay's existing `NWBrowser` kept a TXT-less result:

```text
18:11:58.032 HostConnection: GAMING-PC ended: ... Connection reset by peer
18:12:05.429 dns-sd -L: GAMING-PC ... gaming-pc.local.:8468, full TXT
18:12:05.430 HostBrowser: generation 1 results [GAMING-PC{txt=false,key=false,links=en0,en7}]
18:12:08.161 HostBrowser: picker hosts [] (removal pending=false)
```

mDNSResponder logged replacement TXT remove/add events on both interfaces at
18:12:05.428. The failed layer was the long-lived browser's TXT result, rather
than pairing storage or missing host announcements. A separate idle kill
delivered full TXT after 126 ms, so the failure depends on timing.

`BrowseRecovery` recreates the browser 2.5, 10 and 30 seconds after a known
row is removed. A picker dial that never reaches `.ready` also requires one
fresh browse after reconfirm. Returning full TXT cancels remaining retries;
duplicate triggers do not extend the schedule, and retries stop after 30 s.
The existing debouncer survives browser replacement, preserving its removal
and TXT-withdrawal grace for other PCs. Browser generations reject retired
callbacks. Neither saved pairings nor the wire/TXT formats change.

Verification: 164 Swift tests, `Tools/test-pair-name.sh`, and a signed local
release bundle pass. An isolated smoke harness killed fakehost with SIGKILL,
triggered failed-dial recovery, observed browse generation 2, restarted the
same fake identity, and verified it without a PIN. GAMING-PC stayed visible
through that restart. The local advertiser was kept alive: a record registered
by this Mac cannot reproduce the real PC's TXT failure.

Fixed-client real-PC checks, home LAN, 2026-10-18 UTC, source `4f74101`:

| case | observed result |
|---|---|
| F6b 1, idle kill + Connect in the gap | Dial started 01:16:00.322, reached `.ready` 01:16:04.333 and streamed 01:16:05.779 without a PIN. TXT returned within grace; no row loss or app restart. The dial did not time out, so this did not exercise failed-dial recovery. |
| F6b 2, mid-session kill | Connection reset 01:17:08.847; full TXT returned 01:17:16.468 after a 127 ms withdrawal. Row stayed Paired; reconnect streamed 01:17:31.033 without a PIN or app restart. |
| Mid-session repeat | Reset 01:18:17.096; TXT-less result 01:18:24.978, row removed 01:18:27.652. Recovery was armed, then full TXT returned 01:18:27.982 (10.9 s after reset), restoring the row and cancelling the pending restart. Reconnect streamed 01:18:59.920 without a PIN or app restart. |
| Idle repeat, timed-out dial | Dial started 01:21:44.159 and timed out 01:21:56.758. Reconfirm and recovery ran; generation 2 returned full TXT at 01:21:59.416. Reconfirm subsequently flushed the PTR (`dns-sd -B` Rmv 01:22:03.450); the row expired 01:22:06.183. Browser generations 3/4/5 started 01:22:08.808 / :16.550 / :36.699. PTR Add arrived 01:22:44.651 and the Paired row returned 01:22:45.652, without reopening. PIN-free reconnect streamed 01:23:34.166. |
| Mid-session repeat, stuck TXT, auxiliary browse closed | Reset 01:23:55.426; resolver returned full TXT while generation 5 reported TXT-less at 01:24:03.509. Row removed 01:24:06.239; recovery recreated the browser 01:24:08.864. Generation 6 returned full TXT and restored the Paired row 01:24:08.895: **13.5 s after reset, 2.7 s after row removal**, without reopening. PIN-free reconnect streamed 01:24:31.189. |

The last run reproduces the original stuck-TXT failure and verifies that
browser replacement restores it. The timed-out dial also exercised real
reconfirm and every restart slot. That run took **39.5 s after row removal**
(48.9 s after dial failure), exceeding the approximate 10–30 s target. The
auxiliary `dns-sd -B` remained active during it; a shared daemon question may
affect restart timing, but that cause is not established. It was closed before
the final mid-session repeat; `dns-sd -L` and mDNSResponder logging continued.
These checks establish recovery without reopening or losing pairing, not a
universal 30-second bound. Direct TCP to the PC succeeded during the slow case.

### `fakehost`: a fake PC

[`Tools/fakehost/main.swift`](Tools/fakehost/main.swift) runs the real v4
handshake and pairing with the app's own `Noise.swift` and `CPace.swift` and
plays one host behaviour per run, so the connect and pairing paths can be
tested with no PC:

```sh
swiftc -O -o fakehost Tools/fakehost/main.swift Sources/Relay/{Noise,Field25519,CPace,Protocol,VideoBitrate}.swift
./fakehost 8470 busy            # prints the dns-sd line to advertise it
dns-sd -R "Fake PC" _relay._tcp . 8470 v=4 pk=<hex> pg=<hex>
```

Then `swift run Relay` lists "Fake PC", or `swift run Relay --host
127.0.0.1:8470` dials it directly.

| mode | the fake PC… |
|---|---|
| `busy` | allows Pair and Forget, answers Connect with "in another session" |
| `ratelimit <s>` | refuses pairing for `<s>` seconds |
| `wrong` | checks against a different PIN, so the Mac sees the PIN fail |
| `accept` | pairs with its PIN, then closes |
| `hang` | pairs with its PIN, then stays connected |
| `notpaired` | pairs, then says the Mac isn't paired when it connects |

Its PIN is `000000` unless `--pin <digits>` sets one: CPace needs the real PIN on
both sides. `--paired` makes it claim the Mac is already paired, and
`--forget`, `--pg <hex>` change the advertised pairing digest to exercise the
"PC forgot this MacBook" path. The header of the file has worked examples.
By default it advertises `CAP_PAIR_NAME`, accepts named and legacy PAIR, and
prints the confirmed name before success. `--legacy-pair` omits the capability
and rejects extended PAIR, to test a new Mac against an older v4 host.
`--ignore-unpair` withholds the Forget reply to test the unconfirmed outcome.
`--clip <file.hevc>` streams an Annex B HEVC clip after Connect, looped at
60 fps, so decoding and presentation can be checked without a PC (`--format`
sets STREAM_START's picture-format byte, `--size` its size); `--enc q,444,10`
offers the picture options. The file's header has an ffmpeg example.

If macOS blocks local devices, enable Relay in **System Settings → Privacy &
Security → Local Network**. If it is already enabled, quit and reopen Relay,
particularly after rebuilding the app bundle. A Forget timeout means the
PC's pairing state is unconfirmed; it does not establish that the PC still
remembers this Mac.

### `ctcheck`: timing of the PIN-to-point map

CPace turns the pairing PIN into a curve point with field arithmetic in
[`Field25519.swift`](Sources/Relay/Field25519.swift), which must take the same
time whatever the PIN. [`Tools/ctcheck.swift`](Tools/ctcheck.swift) checks this
with the dudect method: it times fixed against random inputs and compares them
with Welch's t-test.

```sh
swiftc -O -parse-as-library -o ctcheck Tools/ctcheck.swift Sources/Relay/Field25519.swift
./ctcheck        # about 25 s; exit status 1 if |t| > 10
```

On an M3 Pro: max |t| 1.5 over 200,000 runs. A 1 µs input-dependent difference
planted for comparison shows |t| 41.

## How it works

### A session, end to end

1. **Discover.** [`HostBrowser`](Sources/Relay/HostBrowser.swift) browses
   `_relay._tcp` and reads each PC's TXT record: identity key `pk`, pairing
   digest `pg`, and facts for the hover card.
2. **Connect.** [`HostConnection`](Sources/Relay/HostConnection.swift) dials over
   Network.framework, pinned to wired Ethernet when the PC was seen there, and
   runs the Noise XX handshake ([`Noise.swift`](Sources/Relay/Noise.swift)). It
   refuses a PC whose identity key changed before sending its own.
3. **Pair if needed** with CPace ([`CPace.swift`](Sources/Relay/CPace.swift)):
   the PC proves it knows the same PIN before the Mac confirms. Then send
   `CLIENT_HELLO` with the screen's pixel size, refresh rate, bitrate and
   supported codecs.
4. **Receive.** Messages arrive as encrypted records of up to 64 KiB.
   [`FrameReader`](Sources/Relay/FrameReader.swift) pulls them from the socket
   and [`SecureChannel`](Sources/Relay/Crypto.swift) decrypts and reassembles
   them; once a frame's first record is in, the rest is read in one go.
5. **Decode.** [`VideoRenderer`](Sources/Relay/VideoRenderer.swift) owns a
   real-time `VTDecompressionSession`. The wire already uses the length-prefixed
   NAL layout VideoToolbox wants, so each frame becomes a sample buffer with no
   rewriting.
6. **Present.** [`MetalPresenter`](Sources/Relay/MetalPresenter.swift) keeps only
   the newest decoded frame, wraps its IOSurface as two Metal textures (no copy)
   and converts YCbCr to RGB in one shader pass.
7. **Input.** [`StreamView`](Sources/Relay/StreamView.swift) turns pointer
   movement into coordinates relative to the picture and keys into USB HID codes
   ([`KeyMap`](Sources/Relay/KeyMap.swift)), so keyboard layout doesn't matter.

### Source map

| area | files |
|---|---|
| UI and lifecycle | [`RelayApp`](Sources/Relay/RelayApp.swift) (window, menus), [`PickerModel`](Sources/Relay/PickerModel.swift), [`HostPickerView`](Sources/Relay/HostPickerView.swift), [`HoverCard`](Sources/Relay/HoverCard.swift), [`PINEntryView`](Sources/Relay/PINEntryView.swift), [`Style`](Sources/Relay/Style.swift), [`AppDelegate`](Sources/Relay/AppDelegate.swift), [`HostPickerWindowController`](Sources/Relay/HostPickerWindowController.swift) |
| Discovery | [`HostBrowser`](Sources/Relay/HostBrowser.swift), [`BrowseRecovery`](Sources/Relay/BrowseRecovery.swift), [`BonjourReconfirm`](Sources/Relay/BonjourReconfirm.swift), [`LocalNetworks`](Sources/Relay/LocalNetworks.swift) |
| Connection and pairing | [`HostConnection`](Sources/Relay/HostConnection.swift), [`Crypto`](Sources/Relay/Crypto.swift), [`Protocol`](Sources/Relay/Protocol.swift), [`FrameReader`](Sources/Relay/FrameReader.swift), [`PairingVerifier`](Sources/Relay/PairingVerifier.swift), [`VerifyTask`](Sources/Relay/VerifyTask.swift), [`UnpairTask`](Sources/Relay/UnpairTask.swift) |
| Frame/control boundary | [`SessionPipeline`](Sources/Relay/SessionPipeline.swift) (frames remain off the main actor) |
| Video | [`VideoRenderer`](Sources/Relay/VideoRenderer.swift), [`MetalPresenter`](Sources/Relay/MetalPresenter.swift), [`LatestFrame`](Sources/Relay/LatestFrame.swift), [`LatencyStats`](Sources/Relay/LatencyStats.swift) |
| Input | [`StreamView`](Sources/Relay/StreamView.swift), [`KeyMap`](Sources/Relay/KeyMap.swift) |
| Settings | [`SessionPrefs`](Sources/Relay/SessionPrefs.swift), [`StreamMode`](Sources/Relay/StreamMode.swift), [`VideoBitrate`](Sources/Relay/VideoBitrate.swift) |
| Icons | [`IconExport`](Sources/Relay/IconExport.swift) |

### Icons

The PC tower glyph in [`Glyphs.swift`](Sources/Relay/Glyphs.swift) is the source
for every icon, so the two apps share one drawing:

```sh
swift run Relay --render-icons ../host/assets   # the PC's tray icons
swift run Relay --render-app-icon Assets        # AppIcon.icon + Relay.icns
```

`Assets/AppIcon.icon` is an Icon Composer document. Compiled by `actool`, it
lets macOS draw the light, dark, clear and tinted versions; a plain `.icns` has
no dark variant. Re-run both commands after changing the glyph, and commit the
output.

## Limitations

- macOS keeps ⌘Tab, ⌘Space and the Fn media keys.
- With VSync off (the default) the picture can tear; **VSync** (or
  `--metal-vsync`) trades a little latency for no tearing.
- Earlier hardware runs verified Metal colour, orientation and streaming. The
  SwiftUI migration still needs a real-PC streaming/latency comparison and
  qualification on a 60 Hz Air, 120 Hz Pro and external display.
- Development/testing currently uses macOS 27.0. Latest stable 27.0.1 and the
  macOS 14 runtime floor still need qualification; declaring a deployment target
  does not establish that those hardware/OS combinations have been tested.
- The PC must run protocol v4 too. An older PC hangs up during the handshake,
  and the Mac says it may need the latest Relay.
