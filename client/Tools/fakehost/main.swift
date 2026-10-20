// A fake Relay host for testing the client's connect and pairing paths on a
// Mac with no PC around (the mirror of host/src/bin/probe.rs). Speaks the real
// protocol v4 handshake (Noise XX) and pairing (CPace) with the client's own
// Noise.swift and CPace.swift, then acts out one host answer per run:
//
//   busy          allow pairing and UNPAIR; reject CLIENT_HELLO with STREAM_STOP(6)
//   ratelimit <s> PAIR -> PAIR_RESULT 2 + u16 seconds
//   wrong         answers PAIR with a different PIN than the one it prints,
//                 so the Mac sees PAIR_REPLY fail and says the PIN was wrong
//   accept        pairs with the printed PIN (then closes; use `hang` to stay up)
//   hang          like accept, then waits for the next message forever
//   notpaired     like accept, but CLIENT_HELLO gets STREAM_STOP(4): the PC
//                 forgot the Mac between the handshake and the stream
//
// The PIN is 000000 unless `--pin <6 digits>` says otherwise; CPace needs the
// real one on both sides. After a PAIR_RESULT 1 the process answers later
// handshakes with paired = 1, as a real host would, so a Mac that just paired
// verifies as still paired.
//
// `--paired` makes SERVER_HELLO claim the client is already paired, so a host
// the Mac has in hosts.txt connects without a PIN. The identity key is kept in
// ./fakehost.key so the advertised `pk` (and the Paired row) survive restarts.
//
// The printed dns-sd line also carries `pg`, the pairing digest a real host
// derives from its paired keys. Here it is a stand-in that only has to differ
// between runs: one value for `--paired`, another for `--forget` (SERVER_HELLO
// says not paired), a third for neither, or `--pg <8 hex>` to pick one. The
// Mac checks a known host's pairing over the handshake alone whenever the
// digest it advertises is not the one last verified, so:
//
//   ./fakehost 8470 hang --paired      # the Mac verifies once, row stays Paired
//   ./fakehost 8470 accept --forget    # re-run dns-sd with the new pg: the row
//                                      # moves to Available, "PC forgot this
//                                      # MacBook"; Pair (PIN 000000) brings it back
//   ./fakehost 8470 hang --paired --pg 0badf00d   # a moved digest with paired = 1
//                                      # only updates the stored one
//
// `--legacy-pair` omits CAP_PAIR_NAME and accepts only the legacy 32-byte PAIR.
// Otherwise named PAIR and legacy PAIR are both accepted, like the real host.
// `--ignore-unpair` reads UNPAIR but sends no reply, for Forget timeout tests.
// `--ignore-hello` withholds SERVER_HELLO for VerifyTask timeout tests.
//
//   swiftc -O -o fakehost Tools/fakehost/main.swift Sources/Relay/{Noise,Field25519,CPace,Protocol,VideoBitrate}.swift
//   ./fakehost 8470 busy                      # prints the dns-sd line to run
//   dns-sd -R "Fake PC" _relay._tcp . 8470 v=4 pk=<hex> pg=<hex>
//
// Then `swift run Relay` shows "Fake PC" in the picker, or
// `swift run Relay --host 127.0.0.1:8470` dials it directly.
//
// `--clip <file.hevc>` streams an Annex B HEVC clip after CLIENT_HELLO, looped
// at 60 fps or `--fps <n>` (STREAM_START, CODEC_CONFIG, FRAMEs, a PING a second), so the
// Mac's decode and presentation can be checked without a PC. `--size WxH`
// sets STREAM_START's size (1280x720) and `--format <n>` its video_format
// byte. `--enc <list>` (e.g. q,444,10) adds TXT `enc` to the printed dns-sd
// line and SERVER_HELLO's picture-options capability (0x02); CLIENT_HELLO's
// extension is printed either way.
//
//   ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=60 -t 2 -c:v libx265 -pix_fmt yuv444p -f hevc clip.hevc
//   ./fakehost 8471 hang --paired --clip clip.hevc --format 4 --enc q,444,10
//
// Clock sync (PROTOCOL.md "Clock sync and frame timing") is on unless
// `--no-timing`: SERVER_HELLO advertises CAP_TIMING, TIME_REQUESTs get
// TIME_REPLYs (written before the next FRAME, like the real host), and from
// the first reply on every FRAME is followed by FRAME_TIMING_EXT. Its clock
// is this Mac's uptime in µs plus `--clock-offset-ms <n>` (may be negative),
// so the app's estimate can be checked against a known answer. It pretends
// DWM presented each picture 0.8 ms before the tick and encoding took 0.2 ms;
// every fifth tick is a re-encode (present unknown).
//
// SERVER_HELLO advertises CAP_DISPLAY_SCALE (0x08) unless `--no-display-scale`
// (an older PC), and CLIENT_HELLO's `display_scale` is printed when present
// (PROTOCOL.md "Display scale").
//
// Messages this fake reads fit one record; FRAMEs it streams are split into
// records as the spec says (the app reassembles them; CryptoTests covers that).
import CryptoKit
import Foundation
setbuf(stdout, nil)

let args = CommandLine.arguments
guard args.count >= 3, let port = UInt16(args[1]) else {
    print("usage: fakehost <port> busy|ratelimit <s>|wrong|accept|hang|notpaired [--pin <digits>] [--paired | --forget] [--pg <8 hex>] [--legacy-pair] [--ignore-unpair] [--ignore-hello]"); exit(2)
}
let mode = args[2]
let limitSecs = mode == "ratelimit" && args.count > 3 ? UInt16(args[3]) ?? 599 : 0
let legacyPair = args.contains("--legacy-pair")
let forgot = args.contains("--forget")
var claimPaired = args.contains("--paired") && !forgot
var peerName = "Paired MacBook"
let pin: String = args.firstIndex(of: "--pin").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "000000"
// `wrong` checks PINs against another one, so whatever the Mac types fails.
let hostPIN = mode == "wrong" ? String(pin.reversed()) + "9" : pin

// Stable identity so a paired host stays the same key across runs.
let keyFile = URL(fileURLWithPath: "fakehost.key")
let identity: Curve25519.KeyAgreement.PrivateKey
if let raw = try? Data(contentsOf: keyFile), let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
    identity = k
} else {
    identity = Curve25519.KeyAgreement.PrivateKey()
    try! identity.rawRepresentation.write(to: keyFile)
}
let pkHex = identity.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

// The real digest is SHA-256("relay-pairing-digest-v1" || sorted paired keys)[..4];
// this one hashes the same label over a stand-in for the list.
func pairingDigest(_ list: String) -> String {
    var input = Data("relay-pairing-digest-v1".utf8)
    input.append(Data(list.utf8))
    return SHA256.hash(data: input).prefix(4).map { String(format: "%02x", $0) }.joined()
}
let pgHex: String
if let i = args.firstIndex(of: "--pg"), i + 1 < args.count {
    pgHex = args[i + 1]
} else {
    pgHex = pairingDigest(forgot ? "forgot" : claimPaired ? "paired" : "")
}
func argument(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
let enc = argument("--enc")
let videoFormat = argument("--format").flatMap { UInt8($0) } ?? 0
let streamSize = argument("--size").map { $0.split(separator: "x").compactMap { UInt16($0) } } ?? [1280, 720]
// `--no-frames`: STREAM_START, then nothing (a PC that can't capture).
let noFrames = args.contains("--no-frames")
// Static > window, moving, a capture gap with clock replies, recovered moving, static.
let sourceCycle = args.contains("--source-cycle")
let timing = !args.contains("--no-timing")
let displayScale = !args.contains("--no-display-scale")
let clockOffsetMicros = Int64((Double(argument("--clock-offset-ms") ?? "0") ?? 0) * 1_000)
/// The fake PC's clock: this Mac's uptime shifted by the offset.
func hostMicros() -> UInt64 {
    UInt64(max(0, Int64(DispatchTime.now().uptimeNanoseconds / 1_000) + clockOffsetMicros))
}

/// Shared between the reader thread (requests, inputs) and the streaming
/// thread (replies, FRAME_TIMING_EXT).
final class TimingState: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [(client: UInt64, received: UInt64)] = []
    private var started = false
    private(set) var replied = false
    private var inputs: UInt64 = 0
    private var lastInput = UInt64.max

    func request(client: UInt64) {
        lock.withLock {
            started = true
            if queued.count < 16 { queued.append((client, hostMicros())) }
        }
    }
    func input() { lock.withLock { if started { inputs += 1; lastInput = hostMicros() } } }
    func takeQueued() -> [(client: UInt64, received: UInt64)] {
        lock.withLock { defer { queued = [] }; if !queued.isEmpty { replied = true }; return queued }
    }
    var isReplied: Bool { lock.withLock { replied } }
    var inputCounts: (UInt64, UInt64) { lock.withLock { (inputs, lastInput) } }
}
let streamFPS = argument("--fps").flatMap { UInt16($0) }.map { min(max($0, 1), 240) } ?? 60
print("pk=\(pkHex) pg=\(pgHex) PIN \(pin)")
print("advertise: dns-sd -R 'Fake PC' _relay._tcp . \(port) v=4 pk=\(pkHex) pg=\(pgHex)\(enc.map { " enc=\($0)" } ?? "")")

/// An Annex B HEVC clip as CODEC_CONFIG parameter sets and FRAME access
/// units (AUDs dropped; a new unit starts at a slice whose
/// first_slice_segment_in_pic_flag is set).
struct Clip {
    var parameterSets: [Data] = []
    var units: [(keyframe: Bool, nals: [Data])] = []

    init?(path: String) {
        guard let bytes = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: path))) else { return nil }
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { starts.append((i, 3)); i += 3 }
            else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, 4)); i += 4 }
            else { i += 1 }
        }
        var current: [Data] = [], keyframe = false, hasSlice = false
        func flush() {
            if hasSlice { units.append((keyframe, current)) }
            current = []; keyframe = false; hasSlice = false
        }
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].0 : bytes.count
            var nal = Array(bytes[(start.0 + start.1)..<end])
            while nal.last == 0 { nal.removeLast() } // trailing zero bytes
            guard nal.count > 2 else { continue }
            let type = Int(nal[0] >> 1) & 0x3f
            switch type {
            case 32...34:
                if parameterSets.count < 3 { parameterSets.append(Data(nal)) }
            case 35: continue
            case 0...31:
                if nal[2] & 0x80 != 0, hasSlice { flush() }
                hasSlice = true
                if (16...23).contains(type) { keyframe = true }
                current.append(Data(nal))
            default:
                current.append(Data(nal))
            }
        }
        flush()
        guard parameterSets.count == 3, !units.isEmpty else { return nil }
    }
}
let clip: Clip? = argument("--clip").map { path in
    guard let clip = Clip(path: path) else { print("could not read an HEVC clip from \(path)"); exit(2) }
    print("clip: \(clip.units.count) frames, \(clip.units.filter(\.keyframe).count) keyframes")
    return clip
}

/// Ended by the reader thread when the client closes.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

func readExact(_ fd: Int32, _ n: Int) -> Data? {
    var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while out.count < n {
        let r = read(fd, &buf, min(buf.count, n - out.count))
        if r <= 0 { return nil }
        out.append(contentsOf: buf[0..<r])
    }
    return out
}
func readFrame(_ fd: Int32) -> Data? {
    guard let h = readExact(fd, 4) else { return nil }
    let n = Int(h.be32(at: 0))
    guard n <= 65_535 else { print("-- frame of \(n) bytes refused"); return nil }
    return readExact(fd, n)
}
func frame(_ body: Data) -> Data { var f = Data(); f.appendBE32(UInt32(body.count)); f.append(body); return f }
@discardableResult
func writeAll(_ fd: Int32, _ d: Data) -> Bool {
    d.withUnsafeBytes { p in
        var off = 0
        while off < d.count { let r = write(fd, p.baseAddress! + off, d.count - off); if r <= 0 { return false }; off += r }
        return true
    }
}

/// One direction of the record layer, one record per message.
final class Channel {
    var cipher: NoiseCipherState
    init(_ c: NoiseCipherState) { cipher = c }
    func seal(type: UInt8, payload: Data) -> Data {
        var m = Data([type, 0, 0, 0]); m.appendBE32(UInt32(payload.count)); m.append(payload)
        return frame(try! cipher.encrypt(ad: Data(), plaintext: m))
    }
    /// A message of any size: 65,519-byte chunks, one record each.
    func sealChunked(type: UInt8, flags: UInt8 = 0, payload: Data) -> Data {
        var m = Data([type, flags, 0, 0]); m.appendBE32(UInt32(payload.count)); m.append(payload)
        var out = Data(), offset = 0
        while offset < m.count {
            let end = min(offset + 65_519, m.count)
            out.append(frame(try! cipher.encrypt(ad: Data(), plaintext: m.subdata(in: offset..<end))))
            offset = end
        }
        return out
    }
    func open(_ body: Data) -> (UInt8, Data)? {
        guard let plain = try? cipher.decrypt(ad: Data(), ciphertext: body), plain.count >= 8,
              plain.count == 8 + Int(plain.be32(at: 4)) else { return nil }
        return (plain[plain.startIndex], Data(plain.dropFirst(8)))
    }
}

/// CLIENT_HELLO's codecs and optional extensions: u16 version, width,
/// height, refresh, bitrate, u8 flags, u8 codecs, u8 name length, name, then
/// the optional u8 quality, u8 video flags, then the optional u16 display_scale.
func describeHello(_ payload: Data) -> String {
    let p = [UInt8](payload)
    let codecs = p.count > 11 ? p[11] : 0
    let nameEnd = p.count > 12 ? 13 + Int(p[12]) : p.count
    var ext = p.count >= nameEnd + 2 ? "quality \(p[nameEnd]) video flags 0b\(String(p[nameEnd + 1], radix: 2))" : "no extension"
    if p.count >= nameEnd + 4 {
        ext += ", display scale \(UInt16(p[nameEnd + 2]) << 8 | UInt16(p[nameEnd + 3]))%"
    } else if displayScale {
        ext += ", no display scale"
    }
    let size = p.count >= 6 ? "\(UInt16(p[2]) << 8 | UInt16(p[3]))x\(UInt16(p[4]) << 8 | UInt16(p[5])), " : ""
    return "\(size)codecs 0b\(String(codecs, radix: 2)), \(ext)"
}

func serve(_ fd: Int32) {
    defer { close(fd); print("-- closed") }
    guard let m1 = readFrame(fd) else { print("no msg1"); return }
    guard m1.count == 36, m1.prefix(4) == Data("RLY4".utf8) else {
        print(m1.prefix(4) == Data("TDH2".utf8) ? "-- a v3 client (TDH2); closing" : "bad msg1 (\(m1.count) bytes)"); return
    }
    let noise = NoiseXX(role: .responder, staticKey: identity, prologue: Data("RLY4".utf8))
    do {
        _ = try noise.readMessage(m1.dropFirst(4))
        writeAll(fd, frame(try noise.writeMessage()))
    } catch { print("handshake failed: \(error)"); return }
    guard let m3 = readFrame(fd) else { print("-- client closed after msg2 (it expected another PC key)"); return }
    let clientKey: Data
    let tx: Channel, rx: Channel
    do {
        _ = try noise.readMessage(m3)
        clientKey = noise.remoteStatic!
        let (send, receive) = try noise.split()
        tx = Channel(send); rx = Channel(receive)
    } catch { print("msg3 failed: \(error)"); return }
    let fp = SHA256.hash(data: clientKey).prefix(4).map { String(format: "%02X", $0) }.joined()
    print("-- handshake done with client \(fp) (paired=\(claimPaired))")
    if args.contains("--ignore-hello") {
        print("-- withholding SERVER_HELLO")
        while readExact(fd, 1) != nil {}
        return
    }
    var hello = Data(); hello.appendBE16(4); let name = Array("Fake PC".utf8); hello.append(UInt8(name.count)); hello.append(contentsOf: name)
    hello.append(claimPaired ? 1 : 0)
    if !legacyPair {
        hello.append(Proto.capPairName | (enc != nil ? Proto.capVideoOptions : 0) | (timing ? Proto.capTiming : 0)
                     | (displayScale ? Proto.capDisplayScale : 0))
    }
    writeAll(fd, tx.seal(type: 0x01, payload: hello))

    /// CPace as the responder (B), after the Mac's PAIR. Returns whether it confirmed.
    func pair(_ payload: Data) -> Bool {
        guard let request = Proto.PairRequest(payload), !legacyPair || request.ad.isEmpty else {
            print("-- malformed PAIR; closing"); return false
        }
        let ci = CPace.channelIdentifier(clientStatic: clientKey, hostStatic: identity.publicKey.rawRepresentation)
        guard let b = try? CPaceResponder(prs: Data(hostPIN.utf8), ci: ci, sid: noise.handshakeHash,
                                         peerShare: request.share, peerAD: request.ad) else {
            print("-- invalid Ya; closing"); return false
        }
        writeAll(fd, tx.seal(type: 0xA3, payload: b.share + b.tag))
        guard let body = readFrame(fd), let (type, tag) = rx.open(body), type == 0xA4 else {
            print("-- client closed after PAIR_REPLY (the PINs differ)"); return false
        }
        guard b.verify(peerTag: tag) else {
            writeAll(fd, tx.seal(type: 0xA1, payload: Data([0]))); print("-- PAIR_CONFIRM did not check out: PAIR_RESULT 0"); return false
        }
        // Like the real host, commit the label only after confirmation and
        // before success. Log it so pair-only checks can verify the timing.
        let name = request.name?.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { peerName = name }
        print("-- confirmed peer name: \(peerName)")
        claimPaired = true
        writeAll(fd, tx.seal(type: 0xA1, payload: Data([1]))); print("-- PAIR_RESULT paired")
        return true
    }

    /// The clip, looped at `streamFPS` until the client goes away.
    func stream(_ clip: Clip) {
        var start = Data()
        start.appendBE16(streamSize.first ?? 1280); start.appendBE16(streamSize.last ?? 720)
        start.appendBE16(streamFPS); start.appendBE16(120); start.append(2); start.append(videoFormat)
        var config = Data()
        for set in clip.parameterSets { config.appendBE32(UInt32(set.count)); config.append(set) }
        guard writeAll(fd, tx.seal(type: 0x02, payload: start)) else { return }
        if noFrames {
            // Stay connected until the Mac leaves: it sends TIME_REQUESTs
            // right after STREAM_START, and returning on the first message
            // closed the socket before its no-picture timeout could fire.
            print("-- STREAM_START sent; withholding frames")
            while readFrame(fd) != nil {}
            return
        }
        guard writeAll(fd, tx.sealChunked(type: 0x03, payload: config)) else { return }
        let closed = Flag()
        let clock = TimingState()
        // PONGs, input and TIME_REQUESTs. rx is this thread's alone from here.
        Thread.detachNewThread {
            while let body = readFrame(fd) {
                guard let (type, payload) = rx.open(body) else { continue }
                if type == 0x88, timing, payload.count >= 8 { clock.request(client: payload.be64(at: 0)) }
                if (0x90...0x93).contains(type) { clock.input() }
            }
            closed.set()
        }
        var sent = 0, lastPing = Date.distantPast
        let interval = 1_000_000_000 / UInt64(streamFPS)
        let began = DispatchTime.now().uptimeNanoseconds
        var next = began
        var recovered = false
        while !closed.isSet {
            let unit = clip.units[sent % clip.units.count]
            var body = Data()
            for nal in unit.nals { body.appendBE32(UInt32(nal.count)); body.append(nal) }
            for request in clock.takeQueued() {
                var reply = Data()
                reply.appendBE64(request.client); reply.appendBE64(request.received); reply.appendBE64(hostMicros())
                writeAll(fd, tx.seal(type: 0x09, payload: reply))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
            if sourceCycle, elapsed >= 8, elapsed < 10 {
                usleep(10_000)
                continue // capture recovery still answers TIME_REQUEST
            }
            if sourceCycle, elapsed >= 10, !recovered {
                writeAll(fd, tx.sealChunked(type: 0x03, payload: config))
                recovered = true
            }
            let freshSource = sourceCycle ? ((6..<8).contains(elapsed) || (10..<12).contains(elapsed)) : sent % 5 != 4
            let tick = hostMicros()
            guard writeAll(fd, tx.sealChunked(type: 0x04, flags: unit.keyframe ? 0x01 : 0, payload: body)) else { break }
            let sentAt = hostMicros()
            if clock.isReplied {
                let (inputs, lastInput) = clock.inputCounts
                var ext = Data()
                ext.appendBE64(UInt64(sent))
                ext.appendBE64(freshSource ? tick - 800 : .max)
                ext.appendBE64(tick)
                ext.appendBE64(sentAt)
                for field: UInt32 in [300, 200, UInt32(min(sentAt - tick, 1_000_000)), .max, .max] { ext.appendBE32(field) }
                ext.appendBE64(inputs)
                ext.appendBE64(lastInput)
                writeAll(fd, tx.seal(type: 0x0A, payload: ext))
            }
            sent += 1
            if Date().timeIntervalSince(lastPing) >= 1 {
                lastPing = Date()
                var ping = Data(); ping.appendBE32(0); ping.appendBE32(UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1e6)))
                writeAll(fd, tx.seal(type: 0x07, payload: ping))
            }
            // On a fixed schedule: sleeping a whole interval after each send
            // delivered ~50 of 60 fps. A sender that falls behind resumes from
            // now rather than bursting.
            next += interval
            let now = DispatchTime.now().uptimeNanoseconds
            if next > now { usleep(UInt32((next - now) / 1_000)) } else { next = now }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        print("-- streamed \(sent) frames in \(String(format: "%.1f s (%.1f fps)", seconds, Double(sent) / seconds)); client gone")
    }

    guard let body = readFrame(fd), let (type, payload) = rx.open(body) else { print("-- no first message (a pairing check ends here)"); return }
    print(String(format: "-- first message 0x%02x (%d bytes)", type, payload.count))
    if type == 0xA2 && args.contains("--ignore-unpair") {
        print("-- UNPAIR received; withholding confirmation")
        _ = readFrame(fd) // ends when UnpairTask times out and cancels
        return
    }
    if mode == "busy" {
        var requestType = type
        if requestType == 0xA0 {
            guard pair(payload) else { return }
            print("-- paired while display is busy")
            guard let next = readFrame(fd), let (nextType, _) = rx.open(next) else {
                print("-- pair-only client closed without requesting the display")
                return
            }
            requestType = nextType
            print(String(format: "-- next message 0x%02x", requestType))
        }
        if requestType == 0xA2 {
            claimPaired = false
            writeAll(fd, tx.seal(type: 0x06, payload: Data([5])))
            print("-- UNPAIRED while display is busy")
            return
        }
        guard requestType == 0x81 else { print("-- unexpected busy-time request"); return }
        writeAll(fd, tx.seal(type: 0x06, payload: Data([6])))
        print("-- CLIENT_HELLO refused with STREAM_STOP(6); half-closing and draining")
        shutdown(fd, SHUT_WR)
        var buf = [UInt8](repeating: 0, count: 1024); var total = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { let r = read(fd, &buf, buf.count); if r <= 0 { break }; total += r }
        print("-- drained \(total) bytes, client hung up")
        return
    }
    switch (mode, type) {
    case ("ratelimit", 0xA0):
        var p = Data([2]); p.appendBE16(limitSecs)
        writeAll(fd, tx.seal(type: 0xA1, payload: p)); print("-- PAIR_RESULT rate-limited \(limitSecs) s")
    case ("wrong", 0xA0), ("accept", 0xA0), ("hang", 0xA0), ("notpaired", 0xA0):
        guard pair(payload) else { break }
        if let next = readFrame(fd), let (nextType, nextPayload) = rx.open(next) {
            print(String(format: "-- next message 0x%02x", nextType))
            if nextType == 0x81 { print("-- CLIENT_HELLO (\(describeHello(nextPayload)))") }
            if mode == "notpaired" && nextType == 0x81 {
                writeAll(fd, tx.seal(type: 0x06, payload: Data([4])))
                print("-- CLIENT_HELLO refused with STREAM_STOP(4)")
            }
            if mode == "hang" { _ = readFrame(fd) }
        } else {
            print("-- pair-only client closed without requesting the display")
        }
    case (_, 0xA2):
        claimPaired = false
        writeAll(fd, tx.seal(type: 0x06, payload: Data([5]))); print("-- UNPAIRED")
    case ("notpaired", 0x81):
        writeAll(fd, tx.seal(type: 0x06, payload: Data([4]))); print("-- CLIENT_HELLO refused with STREAM_STOP(4)")
    case (_, 0x81):
        print("-- CLIENT_HELLO (\(describeHello(payload))); \(clip != nil ? "streaming" : mode == "hang" ? "hanging" : "closing")")
        if let clip { stream(clip) } else if mode == "hang" { _ = readFrame(fd) }
    default:
        print("-- unexpected; closing")
    }
    usleep(200_000)
}

let sock = socket(AF_INET6, SOCK_STREAM, 0)
var one: Int32 = 1
setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in6(); addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); addr.sin6_family = sa_family_t(AF_INET6); addr.sin6_port = port.bigEndian; addr.sin6_addr = in6addr_any
let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
guard bound == 0, listen(sock, 8) == 0 else { print("bind/listen failed: \(errno)"); exit(1) }
var actualAddr = sockaddr_in6()
var actualLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
_ = withUnsafeMutablePointer(to: &actualAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &actualLength) } }
print("listening on \(UInt16(bigEndian: actualAddr.sin6_port)), mode \(mode)")
while true {
    let fd = accept(sock, nil, nil)
    guard fd >= 0 else { continue }
    var nd: Int32 = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nd, socklen_t(MemoryLayout<Int32>.size)) // a streamed write after close fails instead
    print("== connection")
    serve(fd)
}
