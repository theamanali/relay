// Pairing and transport security, matching host/src/crypto.rs byte for byte.
// See docs/PROTOCOL.md, "Handshake and pairing".

import CryptoKit
import Foundation

enum CryptoError: Error, LocalizedError {
    case badHello(String)
    case hostChanged(expected: String, got: String)
    case authFailed
    case malformed
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .badHello(let why): return why
        case .hostChanged(let expected, let got):
            return "host identity changed: expected \(expected), got \(got). Remove it from hosts.txt to pair again."
        case .authFailed: return "message failed authentication"
        case .malformed: return "malformed message"
        case .tooLarge(let n): return "message of \(n) bytes is over the limit"
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
    // Keep each read/modify/write transaction atomic across connection and UI queues.
    private static let stateLock = NSRecursiveLock()
    static var directory: URL {
        stateLock.lock()
        defer { stateLock.unlock() }
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
        stateLock.lock()
        defer { stateLock.unlock() }
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
        stateLock.lock()
        defer { stateLock.unlock() }
        return load("hosts.txt")
    }

    static func remember(host key: Data, name: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var hosts = knownHosts()
        hosts[key] = name.replacingOccurrences(of: "\n", with: " ")
        save(hosts, to: "hosts.txt")
    }

    static func forget(host key: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var hosts = knownHosts()
        if hosts.removeValue(forKey: key) != nil { save(hosts, to: "hosts.txt") }
        setNickname(nil, for: key)
        setVerifiedDigest(nil, for: key)
    }

    /// The pairing digest (`pg`) each known host advertised when the
    /// handshake last confirmed it still knows this Mac: public key (hex) ->
    /// digest. A host advertising any other value is asked again.
    static func verifiedDigests() -> [Data: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return load("verified-digests.txt")
    }

    static func setVerifiedDigest(_ digest: String?, for key: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var digests = verifiedDigests()
        if let digest {
            digests[key] = digest
        } else {
            guard digests.removeValue(forKey: key) != nil else { return }
        }
        save(digests, to: "verified-digests.txt")
    }

    /// Names the user gave hosts on this Mac (public key -> name). Kept apart
    /// from hosts.txt, which the connection rewrites with the host's own name.
    static func nicknames() -> [Data: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return load("nicknames.txt")
    }

    static func setNickname(_ name: String?, for key: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
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
        stateLock.lock()
        defer { stateLock.unlock() }
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
        stateLock.lock()
        defer { stateLock.unlock() }
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

/// Protocol v4's handshake is Noise XX (Noise.swift) and its pairing CPace
/// (CPace.swift); these are the Relay-specific constants around them.
/// See docs/PROTOCOL.md, "Handshake and pairing".
enum Handshake {
    /// Sent in the clear before Noise's msg1, and the Noise prologue: it tells
    /// a v4 client from an older one.
    static let magic = Data("RLY4".utf8)
    /// msg2 (<- e, ee, s, es): 32 + (32 + 16) + 16 for the empty payload's tag.
    static let message2Length = 96

    static func initiator(identity: Curve25519.KeyAgreement.PrivateKey,
                          ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) -> NoiseXX {
        NoiseXX(role: .initiator, staticKey: identity, prologue: magic, ephemeral: ephemeral)
    }
}

// MARK: - Records

/// One direction of the encrypted channel (PROTOCOL.md, "Records"). A message
/// (8-byte header + payload) travels as records of at most 65,519 plaintext
/// bytes, each a Noise transport message under this direction's key, with
/// one counter for the whole session.
final class SecureChannel {
    /// Noise's largest message; also the most a record's length can claim.
    static let maxRecord = 65_535
    static let maxRecordPlaintext = maxRecord - 16
    /// Length prefix + tag around each record's plaintext.
    static let recordOverhead = 4 + 16

    private var cipher: NoiseCipherState
    private let maxPayload: Int
    /// The message being reassembled and its full size (header + payload);
    /// `expected` is 0 between messages.
    private var pending = Data()
    private var expected = 0

    init(cipher: NoiseCipherState, maxPayload: Int = Int(Proto.maxPayload)) {
        self.cipher = cipher
        self.maxPayload = maxPayload
    }

    /// Encrypt a whole protocol message into its records, each with its
    /// u32 length, ready for one write.
    func seal(_ message: Data) throws -> Data {
        var out = Data(capacity: message.count + Self.recordOverhead * (message.count / Self.maxRecordPlaintext + 1))
        var offset = message.startIndex
        repeat {
            let end = min(offset + Self.maxRecordPlaintext, message.endIndex)
            let record = try cipher.encrypt(ad: Data(), plaintext: Data(message[offset..<end]))
            out.appendBE32(UInt32(record.count))
            out.append(record)
            offset = end
        } while offset < message.endIndex
        return out
    }

    /// Decrypt one record body. Returns the message when this record
    /// completes it, nil while more records are to come.
    func open(_ record: Data) throws -> (header: Proto.Header, payload: Data)? {
        let plain: Data
        do {
            plain = try cipher.decrypt(ad: Data(), ciphertext: record)
        } catch {
            throw CryptoError.authFailed
        }
        if expected == 0 {
            // The first record of a message carries its header; check the
            // size before anything more is read.
            guard let header = Proto.Header(plain) else { throw CryptoError.malformed }
            guard Int(header.length) <= maxPayload else { throw CryptoError.tooLarge(Int(header.length)) }
            expected = Proto.headerSize + Int(header.length)
            pending = plain
        } else {
            pending.append(plain)
        }
        guard pending.count <= expected else { throw CryptoError.malformed }
        guard pending.count == expected, let header = Proto.Header(pending) else { return nil }
        let payload = pending.subdata(in: Proto.headerSize..<pending.count)
        pending = Data()
        expected = 0
        return (header, payload)
    }

    /// Wire bytes still to come for the message being reassembled (0 between
    /// messages), assuming full records as senders write them, so the
    /// receive loop can ask for the rest of a large frame in one read.
    var remainingWireBytes: Int {
        let rest = expected - pending.count
        guard expected > 0, rest > 0 else { return 0 }
        let records = (rest + Self.maxRecordPlaintext - 1) / Self.maxRecordPlaintext
        return rest + records * Self.recordOverhead
    }
}
