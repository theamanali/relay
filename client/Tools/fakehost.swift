// A fake Relay host for testing the client's connect and pairing paths on a
// Mac with no PC around (the mirror of host/src/bin/probe.rs). Speaks the
// real v2 handshake and encrypted framing with CryptoKit, then acts out one
// host answer per run:
//
//   busy          allow PAIR/UNPAIR; reject CLIENT_HELLO with STREAM_STOP(6)
//   ratelimit <s> PAIR -> PAIR_RESULT 2 + u16 seconds
//   wrong         PAIR -> PAIR_RESULT 0
//   accept        PAIR -> PAIR_RESULT 1 (then closes; use `hang` to stay up)
//   hang          like accept, then waits for the next message forever
//
// `--paired` makes msg2 claim the client is already paired, so a host the
// Mac has in hosts.txt connects without a PIN. The identity key is kept in
// ./fakehost.key so the advertised `pk` (and the Paired row) survive restarts.
//
//   swiftc -O -o fakehost Tools/fakehost.swift
//   ./fakehost 8470 busy                      # prints the dns-sd line to run
//   dns-sd -R "Fake PC" _relay._tcp . 8470 v=2 pk=<hex>
//
// Then `swift run Relay` shows "Fake PC" in the picker, or
// `swift run Relay --host 127.0.0.1:8470` dials it directly.
import CryptoKit
import Foundation
setbuf(stdout, nil)

let args = CommandLine.arguments
guard args.count >= 3, let port = UInt16(args[1]) else {
    print("usage: fakehost <port> busy|ratelimit <s>|wrong|accept|hang [--paired]"); exit(2)
}
let mode = args[2]
let limitSecs = mode == "ratelimit" ? UInt16(args[3]) ?? 599 : 0
let claimPaired = args.contains("--paired")

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
print("pk=\(pkHex)")
print("advertise: dns-sd -R 'Fake PC' _relay._tcp . \(port) v=2 pk=\(pkHex)")

extension Data {
    func be16(at o: Int) -> UInt16 { UInt16(self[startIndex + o]) << 8 | UInt16(self[startIndex + o + 1]) }
    func be32(at o: Int) -> UInt32 { UInt32(be16(at: o)) << 16 | UInt32(be16(at: o + 2)) }
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendBE32(_ v: UInt32) { appendBE16(UInt16(v >> 16)); appendBE16(UInt16(v & 0xffff)) }
    mutating func appendBE64(_ v: UInt64) { appendBE32(UInt32(v >> 32)); appendBE32(UInt32(v & 0xffffffff)) }
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
    return readExact(fd, Int(h.be32(at: 0)))
}
func writeAll(_ fd: Int32, _ d: Data) {
    d.withUnsafeBytes { p in var off = 0; while off < d.count { let r = write(fd, p.baseAddress! + off, d.count - off); if r <= 0 { return }; off += r } }
}

final class Channel {
    let key: SymmetricKey; var counter: UInt64 = 0
    init(_ k: SymmetricKey) { key = k }
    func nonce() -> ChaChaPoly.Nonce { var n = Data(count: 4); n.appendBE64(counter); counter += 1; return try! ChaChaPoly.Nonce(data: n) }
    func seal(type: UInt8, payload: Data) -> Data {
        var m = Data([type, 0, 0, 0]); m.appendBE32(UInt32(payload.count)); m.append(payload)
        let box = try! ChaChaPoly.seal(m, using: key, nonce: nonce())
        var f = Data(); f.appendBE32(UInt32(box.ciphertext.count + 16)); f.append(box.ciphertext); f.append(box.tag); return f
    }
    func open(_ body: Data) -> (UInt8, Data)? {
        guard body.count >= 16, let box = try? ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: key), plain.count >= 8 else { return nil }
        return (plain[plain.startIndex], plain.dropFirst(8))
    }
}

func serve(_ fd: Int32) {
    defer { close(fd); print("-- closed") }
    guard let m1 = readFrame(fd), m1.count == 70, m1.prefix(4) == Data("TDH2".utf8) else { print("bad msg1"); return }
    let sC = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: m1.subdata(in: 6..<38))
    let eC = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: m1.subdata(in: 38..<70))
    let eph = Curve25519.KeyAgreement.PrivateKey()
    var m2 = Data("TDH2".utf8); m2.appendBE16(2); m2.append(identity.publicKey.rawRepresentation); m2.append(eph.publicKey.rawRepresentation); m2.append(claimPaired ? 1 : 0)
    var f = Data(); f.appendBE32(71); f.append(m2); writeAll(fd, f)
    var tr = m1; tr.append(m2)
    let salt = Data(SHA256.hash(data: tr))
    var ikm = try! eph.sharedSecretFromKeyAgreement(with: eC).withUnsafeBytes { Data($0) }
    ikm.append(try! identity.sharedSecretFromKeyAgreement(with: eC).withUnsafeBytes { Data($0) })
    ikm.append(try! eph.sharedSecretFromKeyAgreement(with: sC).withUnsafeBytes { Data($0) })
    let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data("TravelDisplay v2".utf8), outputByteCount: 96).withUnsafeBytes { Data($0) }
    let rx = Channel(SymmetricKey(data: okm.subdata(in: 0..<32)))
    let tx = Channel(SymmetricKey(data: okm.subdata(in: 32..<64)))
    let fpBytes = SHA256.hash(data: sC.rawRepresentation).prefix(4).map { String(format: "%02X", $0) }.joined()
    print("-- handshake done with client \(fpBytes) (paired=\(claimPaired))")
    var hello = Data(); hello.appendBE16(2); let name = Array("Fake PC".utf8); hello.append(UInt8(name.count)); hello.append(contentsOf: name)
    writeAll(fd, tx.seal(type: 0x01, payload: hello))

    guard let body = readFrame(fd), let (type, payload) = rx.open(body) else { print("no first message"); return }
    print(String(format: "-- first message 0x%02x (%d bytes)", type, payload.count))
    if mode == "busy" {
        var requestType = type
        if requestType == 0xA0 {
            writeAll(fd, tx.seal(type: 0xA1, payload: Data([1])))
            print("-- PAIR_RESULT paired while display is busy")
            guard let next = readFrame(fd), let (nextType, _) = rx.open(next) else {
                print("-- pair-only client closed without requesting the display")
                return
            }
            requestType = nextType
            print(String(format: "-- next message 0x%02x", requestType))
        }
        if requestType == 0xA2 {
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
    case ("wrong", 0xA0):
        writeAll(fd, tx.seal(type: 0xA1, payload: Data([0]))); print("-- PAIR_RESULT wrong PIN")
    case ("accept", 0xA0), ("hang", 0xA0):
        writeAll(fd, tx.seal(type: 0xA1, payload: Data([1]))); print("-- PAIR_RESULT paired")
        if mode == "hang" { _ = readFrame(fd) }
    case (_, 0xA2):
        writeAll(fd, tx.seal(type: 0x06, payload: Data([5]))); print("-- UNPAIRED")
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
print("listening on \(port), mode \(mode)")
while true {
    let fd = accept(sock, nil, nil)
    guard fd >= 0 else { continue }
    var nd: Int32 = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))
    print("== connection")
    serve(fd)
}
