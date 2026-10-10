# Relay for Mac (client)

The Mac half of [Relay](../README.md): a native AppKit app that finds Relay PCs
over Bonjour, pairs with them, and shows the PC's virtual monitor full screen.
It decodes the stream in hardware with VideoToolbox, draws it with Metal, and
sends the keyboard and trackpad back. It uses only Apple frameworks (AppKit,
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

- macOS 13 or later. Developed on Apple silicon.
- The Swift 5.9 toolchain or later (Xcode or the Command Line Tools).
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

## Using it

### The PC list

Relay opens a small window listing the PCs it finds, under **Paired** and
**Available**. Each row shows the link the connection will use: Ethernet, Wi-Fi,
or Direct cable when the PC gave itself a 169.254 address. Hovering a PC shows a
card with its Windows version, CPU, RAM, GPU, its address on each shared link
and its key fingerprint.

- **Pair** (an available PC): enter the 6-digit PIN from the PC's tray icon. The
  PC moves to Paired; nothing is streamed yet. A wrong PIN reopens the sheet,
  and after too many the sheet says how long the PC will refuse them.
  Updated hosts learn this Mac's computer name immediately after successful
  pairing, so their Forget submenu can name it before the first stream. Older
  v4 hosts learn the name on the first Connect.
- **Connect** (a paired PC; also Return or a double-click): progress shows in the
  footer, the button becomes **Cancel**, and the full-screen window opens with
  the first decoded frame. When the session ends, the list comes back with the
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
| Forget | ⌘⌫ or Delete | Remove the pairing on both sides. If the PC can't be reached, it's removed here anyway and the footer shows the `relay-host paired --forget` command to run on the PC. |

### Picture settings

The footer has a resolution popup (native, 75% or 50% of the screen the window
is on, shown in pixels) and a 120/60 Hz control (hidden on a screen with one
rate). The **View** menu mirrors both and adds a **Bitrate** submenu of presets.
**Advanced** in the footer opens:

- **Video bitrate**: a logarithmic slider from 1 to 1000 Mbps with exact entry;
  120 Mbps by default.
- **Keyboard mapping**: Mac-style or physical positions (below).
- **Control the PC / Observe only**: whether keyboard and mouse go to the PC.
- **Latency overlay**.

All of it is remembered between launches. The matching command-line flag
overrides it for one launch.

### During a session

| shortcut | what it does |
|---|---|
| ⌃⌥⌘Q | Leave the session and return to the list (quits in `--host` mode). |
| ⌃⌥⌘K | Switch between controlling and observing the PC; also in the PC menu. |
| ⌃⌥⌘L | Show or hide the latency overlay. |

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
| `--max-fps <n>` | Cap the refresh rate asked for (default 120). |
| `--bitrate <1…1000>` | Video bitrate in Mbps (default 120). |
| `--modifiers mac\|physical` | Keyboard mapping (above). |
| `--no-input` | Observe only. |
| `--latency-stats` | Start with the latency overlay on. |
| `--renderer metal\|avsbdl` | Presentation backend: Metal (default) or the older `AVSampleBufferDisplayLayer` path. |
| `--metal-vsync` | Turn VSync on for Metal: no tearing, slightly more latency. Off by default. |
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
- the pairing-check scheduler and Bonjour reconfirm;
- stream mode and bitrate selection, remembered settings and footer text;
- latency statistics and the newest-frame mailbox;
- offscreen Metal renders of synthetic frames (colour range, orientation,
  letterboxing).

`Tools/test-pair-name.sh` builds fakehost and a small harness using the real
`HostConnection`. It checks pair-only (named, legacy host, busy host, empty
name, Unicode truncation, controls and emoji), wrong PIN, rate limit without a fallback retry,
already-paired, verify-only, UNPAIR and pair-then-stream. Its temporary fixed
Foundation home keeps identities and pairings isolated from the app's state;
it asserts that isolation before constructing a client and deletes it on exit.
No PC, display, installed service or real pairing is touched.

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
| App and windows | [`main.swift`](Sources/Relay/main.swift), [`AppDelegate`](Sources/Relay/AppDelegate.swift) (launch options, session lifecycle, kiosk window), [`MainMenu`](Sources/Relay/MainMenu.swift) |
| PC list | [`HostPickerWindowController`](Sources/Relay/HostPickerWindowController.swift), [`HostRowView`](Sources/Relay/HostRowView.swift), [`PickerRows`](Sources/Relay/PickerRows.swift), [`HoverCard`](Sources/Relay/HoverCard.swift), [`PINEntryView`](Sources/Relay/PINEntryView.swift), [`SessionText`](Sources/Relay/SessionText.swift), [`Style`](Sources/Relay/Style.swift), [`Glyphs`](Sources/Relay/Glyphs.swift) |
| Discovery | [`HostBrowser`](Sources/Relay/HostBrowser.swift), [`BonjourReconfirm`](Sources/Relay/BonjourReconfirm.swift), [`LocalNetworks`](Sources/Relay/LocalNetworks.swift) |
| Connection and pairing | [`HostConnection`](Sources/Relay/HostConnection.swift), [`Crypto`](Sources/Relay/Crypto.swift), [`Protocol`](Sources/Relay/Protocol.swift), [`FrameReader`](Sources/Relay/FrameReader.swift), [`PairingVerifier`](Sources/Relay/PairingVerifier.swift), [`VerifyTask`](Sources/Relay/VerifyTask.swift), [`UnpairTask`](Sources/Relay/UnpairTask.swift) |
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
- With VSync off (the default) the picture can tear; `--metal-vsync` trades a
  little latency for no tearing.
- The Metal presenter is verified for colour and orientation on a real stream.
  Mode switches and reconnects are still being checked, and Metal versus
  `avsbdl` latency numbers have not been recorded yet.
- The PC must run protocol v4 too. An older PC hangs up during the handshake,
  and the Mac says it may need the latest Relay.
