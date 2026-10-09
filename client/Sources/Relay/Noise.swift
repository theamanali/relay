// Noise_XX_25519_ChaChaPoly_SHA256, the handshake of protocol v4.
// Follows the Noise Protocol Framework, revision 34
// (https://noiseprotocol.org/noise.html); section numbers below refer to it.
// Checked against the cacophony test vectors (NoiseTests) and, on the wire,
// against the host's `snow` implementation.
//
// Self-contained (Foundation + CryptoKit) so Tools/fakehost.swift can compile
// it alongside itself.

import CryptoKit
import Foundation

enum NoiseError: Error, LocalizedError, Equatable {
    case decryptFailed
    case shortMessage
    case nonceExhausted
    case lowOrderPoint
    case outOfOrder

    var errorDescription: String? {
        switch self {
        case .decryptFailed: return "Noise message failed authentication"
        case .shortMessage: return "Noise message too short"
        case .nonceExhausted: return "Noise nonce exhausted"
        case .lowOrderPoint: return "peer sent a low-order public key"
        case .outOfOrder: return "Noise handshake message out of order"
        }
    }
}

/// One direction's cipher (§5.1): ChaCha20-Poly1305 with a 64-bit counter
/// nonce, encoded as 4 zero bytes followed by the counter in little-endian.
struct NoiseCipherState {
    private(set) var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    private static func nonceBytes(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// `ciphertext || tag`, or the plaintext unchanged before a key exists.
    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        // 2^64-1 is reserved (§5.1).
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try Self.nonceBytes(nonce), authenticating: ad)
        nonce += 1
        return box.ciphertext + box.tag
    }

    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= 16 else { throw NoiseError.shortMessage }
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try Self.nonceBytes(nonce),
                ciphertext: ciphertext.dropLast(16),
                tag: ciphertext.suffix(16)
            )
            plain = try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseError.decryptFailed
        }
        // The nonce only moves on success, as §5.1 requires.
        nonce += 1
        return plain
    }
}

/// The chaining key, handshake hash and current cipher (§5.2).
struct NoiseSymmetricState {
    private(set) var ck: Data
    private(set) var h: Data
    private(set) var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    mutating func mixKey(_ ikm: Data) {
        let out = Self.hkdf(chainingKey: ck, ikm: ikm, outputs: 2)
        ck = out[0]
        cipher = NoiseCipherState(key: SymmetricKey(data: out[1]))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// (initiator → responder, responder → initiator).
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let out = Self.hkdf(chainingKey: ck, ikm: Data(), outputs: 2)
        return (NoiseCipherState(key: SymmetricKey(data: out[0])), NoiseCipherState(key: SymmetricKey(data: out[1])))
    }

    /// HKDF as §4.3 writes it, with HMAC-SHA256.
    static func hkdf(chainingKey: Data, ikm: Data, outputs: Int) -> [Data] {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: chainingKey))))
        var result = [Data]()
        var previous = Data()
        for i in 1...outputs {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous + [UInt8(i)], using: tempKey))
            result.append(previous)
        }
        return result
    }
}

/// The XX pattern (§7.5), either role:
///
///     -> e
///     <- e, ee, s, es
///     -> s, se
final class NoiseXX {
    static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

    enum Role { case initiator, responder }

    let role: Role
    private var state: NoiseSymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private var e: Curve25519.KeyAgreement.PrivateKey?
    private let fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var re: Curve25519.KeyAgreement.PublicKey?
    private var rs: Curve25519.KeyAgreement.PublicKey?
    private var messageIndex = 0

    /// `ephemeral` is for test vectors only; a real handshake makes a fresh one.
    init(role: Role, staticKey: Curve25519.KeyAgreement.PrivateKey, prologue: Data,
         ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.role = role
        self.s = staticKey
        self.fixedEphemeral = ephemeral
        state = NoiseSymmetricState(protocolName: Self.protocolName)
        state.mixHash(prologue)
    }

    /// The peer's static public key, once the handshake has carried it.
    var remoteStatic: Data? { rs?.rawRepresentation }

    /// `h`: a public value that identifies this handshake, used to bind pairing to it.
    var handshakeHash: Data { state.h }

    var isComplete: Bool { messageIndex == 3 }

    /// Whether the next message is ours to write.
    var isMyTurn: Bool { (messageIndex % 2 == 0) == (role == .initiator) }

    func writeMessage(payload: Data = Data()) throws -> Data {
        guard !isComplete, isMyTurn else { throw NoiseError.outOfOrder }
        var out = Data()
        switch messageIndex {
        case 0: // -> e
            out += writeE()
        case 1: // <- e, ee, s, es
            out += writeE()
            try mixDH(e!, re!)
            out += try state.encryptAndHash(s.publicKey.rawRepresentation)
            try mixDH(s, re!)
        default: // -> s, se
            out += try state.encryptAndHash(s.publicKey.rawRepresentation)
            try mixDH(s, re!)
        }
        out += try state.encryptAndHash(payload)
        messageIndex += 1
        return out
    }

    /// Returns the message's payload.
    func readMessage(_ message: Data) throws -> Data {
        guard !isComplete, !isMyTurn else { throw NoiseError.outOfOrder }
        var rest = Data(message)
        func take(_ n: Int) throws -> Data {
            guard rest.count >= n else { throw NoiseError.shortMessage }
            let part = Data(rest.prefix(n))
            rest = Data(rest.dropFirst(n))
            return part
        }
        let staticLength = 32 + 16 // always encrypted in XX: a key exists before either `s`
        switch messageIndex {
        case 0: // -> e
            try readE(try take(32))
        case 1: // <- e, ee, s, es
            try readE(try take(32))
            try mixDH(e!, re!)
            try readS(try take(staticLength))
            try mixDH(e!, rs!)
        default: // -> s, se
            try readS(try take(staticLength))
            try mixDH(e!, rs!)
        }
        let payload = try state.decryptAndHash(rest)
        messageIndex += 1
        return payload
    }

    /// The transport ciphers for this side: (send, receive).
    func split() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isComplete else { throw NoiseError.outOfOrder }
        let (c1, c2) = state.split()
        return role == .initiator ? (c1, c2) : (c2, c1)
    }

    private func writeE() -> Data {
        let key = fixedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
        e = key
        let pub = key.publicKey.rawRepresentation
        state.mixHash(pub)
        return pub
    }

    private func readE(_ bytes: Data) throws {
        re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes)
        state.mixHash(bytes)
    }

    private func readS(_ ciphertext: Data) throws {
        rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try state.decryptAndHash(ciphertext))
    }

    /// DH between one of our keys and one of theirs, mixed into the key.
    /// The token names (ee, es, se) fix which pair; the call sites pick it per role.
    private func mixDH(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey) throws {
        let shared: Data
        do {
            shared = try mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
        } catch {
            throw NoiseError.lowOrderPoint
        }
        // Noise allows an all-zero result; Relay has always refused one.
        if shared.allSatisfy({ $0 == 0 }) { throw NoiseError.lowOrderPoint }
        state.mixKey(shared)
    }
}
