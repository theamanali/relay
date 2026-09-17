// Pairing and transport security, matching host/src/crypto.rs byte for byte.
// See docs/PROTOCOL.md, "Handshake".

import CryptoKit
import Foundation

enum CryptoError: Error, LocalizedError {
    case badHello(String)
    case lowOrderPoint
    case hostChanged(expected: String, got: String)
    case authFailed
    case malformed

    var errorDescription: String? {
        switch self {
        case .badHello(let why): return why
        case .lowOrderPoint: return "peer sent a low-order public key"
        case .hostChanged(let expected, let got):
            return "host identity changed: expected \(expected), got \(got). Remove it from hosts.txt to pair again."
        case .authFailed: return "message failed authentication"
        case .malformed: return "malformed message"
        }
    }
}

/// Short human-checkable form of a public key: first 4 bytes of SHA-256, upper hex.
func fingerprint(_ publicKey: Data) -> String {
    let digest = SHA256.hash(data: publicKey)
    return Data(digest).prefix(4).map { String(format: "%02X", $0) }.joined()
}

// MARK: - Persistent state (~/Library/Application Support/Relay)

enum ClientState {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Relay", isDirectory: true)
        let fm = FileManager.default
        // The app was called TravelDisplay; carry identity and pairings over
        // once so nothing needs re-pairing after the rename.
        let old = base.appendingPathComponent("TravelDisplay", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Long-lived X25519 identity, created on first launch.
    static func identity() throws -> Curve25519.KeyAgreement.PrivateKey {
        let file = directory.appendingPathComponent("identity.key")
        if let raw = try? Data(contentsOf: file), raw.count == 32 {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try key.rawRepresentation.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
    }

    /// Hosts paired with: public key (hex) -> name, one per line.
    static func knownHosts() -> [Data: String] {
        load("hosts.txt")
    }

    static func remember(host key: Data, name: String) {
        var hosts = knownHosts()
        hosts[key] = name.replacingOccurrences(of: "\n", with: " ")
        save(hosts, to: "hosts.txt")
    }

    static func forget(host key: Data) {
        var hosts = knownHosts()
        if hosts.removeValue(forKey: key) != nil { save(hosts, to: "hosts.txt") }
        setNickname(nil, for: key)
    }

    /// Names the user gave hosts on this Mac (public key -> name). Kept apart
    /// from hosts.txt, which the connection rewrites with the host's own name.
    static func nicknames() -> [Data: String] {
        load("nicknames.txt")
    }

    static func setNickname(_ name: String?, for key: Data) {
        var names = nicknames()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            guard names.removeValue(forKey: key) != nil else { return }
        } else {
            names[key] = trimmed.replacingOccurrences(of: "\n", with: " ")
        }
        save(names, to: "nicknames.txt")
    }

    private static func load(_ file: String) -> [Data: String] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else { return [:] }
        var map: [Data: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let first = parts.first, let key = Data(hex: String(first)), key.count == 32 else { continue }
            map[key] = parts.count > 1 ? String(parts[1]) : ""
        }
        return map
    }

    private static func save(_ map: [Data: String], to file: String) {
        let text = map.map { "\($0.key.hex) \($0.value)" }.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        self.init(bytes)
    }
}

// MARK: - Handshake

struct SessionKeys {
    let clientToHost: SymmetricKey
    let hostToClient: SymmetricKey
    let pair: SymmetricKey
}

enum Handshake {
    static let magic = Data("TDH2".utf8)
    static let version: UInt16 = 2
    static let info = Data("TravelDisplay v2".utf8) // wire constant kept from the original name (see PROTOCOL.md)

    /// One handshake in progress: keeps the ephemeral key and msg1 until msg2 arrives.
    struct Pending {
        let identity: Curve25519.KeyAgreement.PrivateKey
        let ephemeral: Curve25519.KeyAgreement.PrivateKey

        /// `ephemeral` defaults to a fresh key; it is only ever passed in to
        /// replay the test vector in docs/PROTOCOL.md.
        init(identity: Curve25519.KeyAgreement.PrivateKey,
             ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
            self.identity = identity
            self.ephemeral = ephemeral
        }

        /// msg1 = "TDH2" | version | S_c | E_c  (70 bytes)
        var message1: Data {
            var m = Handshake.magic
            m.appendBE16(Handshake.version)
            m.append(identity.publicKey.rawRepresentation)
            m.append(ephemeral.publicKey.rawRepresentation)
            return m
        }

        /// Consume msg2 = "TDH2" | version | S_h | E_h | paired (71 bytes).
        func complete(message2 raw: Data, expectedHost: Data? = nil) throws -> (keys: SessionKeys, hostKey: Data, paired: Bool) {
            let message2 = Data(raw) // fresh indices, in case a slice was passed
            guard message2.count == 71, message2.prefix(4) == Handshake.magic else {
                throw CryptoError.badHello("not a Relay v2 handshake")
            }
            let version = message2.be16(at: 4)
            guard version == Handshake.version else {
                throw CryptoError.badHello("host speaks handshake v\(version), this client v\(Handshake.version)")
            }
            let hostStatic = message2.subdata(in: 6..<38)
            if let expectedHost, expectedHost != hostStatic {
                throw CryptoError.hostChanged(
                    expected: fingerprint(expectedHost),
                    got: fingerprint(hostStatic)
                )
            }
            let hostEph = message2.subdata(in: 38..<70)
            let paired = message2[message2.startIndex + 70] != 0

            let sHost = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostStatic)
            let eHost = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEph)
            let dh1 = try Handshake.dh(ephemeral, eHost)   // E_c · E_h
            let dh2 = try Handshake.dh(ephemeral, sHost)   // E_c · S_h
            let dh3 = try Handshake.dh(identity, eHost)    // S_c · E_h

            var transcript = message1
            transcript.append(message2)
            let salt = Data(SHA256.hash(data: transcript))
            var ikm = dh1
            ikm.append(dh2)
            ikm.append(dh3)
            let okm = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: salt,
                info: Handshake.info,
                outputByteCount: 96
            ).withUnsafeBytes { Data($0) }
            let keys = SessionKeys(
                clientToHost: SymmetricKey(data: okm.subdata(in: 0..<32)),
                hostToClient: SymmetricKey(data: okm.subdata(in: 32..<64)),
                pair: SymmetricKey(data: okm.subdata(in: 64..<96))
            )
            return (keys, hostStatic, paired)
        }
    }

    private static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey,
                           _ pub: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
        if shared.allSatisfy({ $0 == 0 }) { throw CryptoError.lowOrderPoint }
        return shared
    }

    /// What we send to pair: HMAC-SHA256(k_pair, "pin:" || PIN).
    static func pinProof(_ pairKey: SymmetricKey, pin: String) -> Data {
        var msg = Data("pin:".utf8)
        msg.append(Data(pin.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: pairKey))
    }
}

// MARK: - Encrypted framing

/// One direction of the encrypted channel: ChaCha20-Poly1305 with a counter nonce.
final class SecureChannel {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    private func nextNonce() throws -> ChaChaPoly.Nonce {
        var n = Data(count: 4)
        n.appendBE64(counter)
        counter += 1
        return try ChaChaPoly.Nonce(data: n)
    }

    /// Encrypt a whole protocol message (8-byte header + payload). Returns
    /// `u32 length || ciphertext || tag`, ready for the wire.
    func seal(_ message: Data) throws -> Data {
        let box = try ChaChaPoly.seal(message, using: key, nonce: try nextNonce())
        var frame = Data(capacity: 4 + box.ciphertext.count + box.tag.count)
        frame.appendBE32(UInt32(box.ciphertext.count + box.tag.count))
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    /// Decrypt one frame body (ciphertext || tag) into header + payload.
    func open(_ body: Data) throws -> (header: Proto.Header, payload: Data) {
        guard body.count >= 16 else { throw CryptoError.malformed }
        let box = try ChaChaPoly.SealedBox(
            nonce: try nextNonce(),
            ciphertext: body.dropLast(16),
            tag: body.suffix(16)
        )
        let plain: Data
        do {
            plain = try ChaChaPoly.open(box, using: key)
        } catch {
            throw CryptoError.authFailed
        }
        guard let header = Proto.Header(plain), plain.count == Proto.headerSize + Int(header.length) else {
            throw CryptoError.malformed
        }
        return (header, plain.subdata(in: Proto.headerSize..<plain.count))
    }
}

extension Data {
    mutating func appendBE64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((v >> UInt64(shift)) & 0xff))
        }
    }
}
