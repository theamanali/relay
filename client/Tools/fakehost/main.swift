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
// Every message this fake sends or reads fits one record, so it does not
// split or reassemble them (the app does; CryptoTests covers that).
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
print("pk=\(pkHex) pg=\(pgHex) PIN \(pin)")
print("advertise: dns-sd -R 'Fake PC' _relay._tcp . \(port) v=4 pk=\(pkHex) pg=\(pgHex)")

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
func writeAll(_ fd: Int32, _ d: Data) {
    d.withUnsafeBytes { p in var off = 0; while off < d.count { let r = write(fd, p.baseAddress! + off, d.count - off); if r <= 0 { return }; off += r } }
}

/// One direction of the record layer, one record per message.
final class Channel {
    var cipher: NoiseCipherState
    init(_ c: NoiseCipherState) { cipher = c }
    func seal(type: UInt8, payload: Data) -> Data {
        var m = Data([type, 0, 0, 0]); m.appendBE32(UInt32(payload.count)); m.append(payload)
        return frame(try! cipher.encrypt(ad: Data(), plaintext: m))
    }
    func open(_ body: Data) -> (UInt8, Data)? {
        guard let plain = try? cipher.decrypt(ad: Data(), ciphertext: body), plain.count >= 8,
              plain.count == 8 + Int(plain.be32(at: 4)) else { return nil }
        return (plain[plain.startIndex], Data(plain.dropFirst(8)))
    }
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
    if !legacyPair { hello.append(Proto.capPairName) }
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
        if let next = readFrame(fd), let (nextType, _) = rx.open(next) {
            print(String(format: "-- next message 0x%02x", nextType))
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
        print("-- CLIENT_HELLO; \(mode == "hang" ? "hanging" : "closing")")
        if mode == "hang" { _ = readFrame(fd) }
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
    print("== connection")
    serve(fd)
}
