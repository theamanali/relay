// CPace (draft-irtf-cfrg-cpace-21), cipher suite CPACE-X25519-SHA512, in the
// initiator-responder setting: the PIN-based pairing of protocol v4.
//
// Both sides turn the PIN (PRS), a channel identifier (CI) and the Noise
// handshake hash (sid) into a secret curve point g and run one Diffie-Hellman
// exchange over it. Matching PINs give matching keys; a mismatch gives an
// attacker nothing to test other PINs against offline, so each attempt is one
// guess. Explicit key confirmation follows the draft's section 10.4.
//
// Self-contained (Foundation + CryptoKit, plus Field25519.swift) so
// Tools/fakehost.swift can compile it too.

import CryptoKit
import Foundation

enum CPaceError: Error, LocalizedError, Equatable {
    case invalidPoint
    case confirmationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPoint: return "pairing message carried an invalid point"
        case .confirmationFailed: return "the PINs did not match"
        }
    }
}

enum CPace {
    static let dsi = Data("CPace255".utf8)
    /// SHA-512's input block size: the generator string pads PRS out to it.
    static let hashBlockBytes = 128
    static let tagBytes = 32

    // MARK: string helpers (appendix A.1)

    /// LEB128 length, then the bytes.
    static func prependLen(_ data: Data) -> Data {
        var out = Data()
        var length = data.count
        repeat {
            let low = UInt8(length & 0x7f)
            length >>= 7
            out.append(length == 0 ? low : low | 0x80)
        } while length != 0
        return out + data
    }

    static func lvCat(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0 += prependLen($1) }
    }

    /// CI for Relay: the protocol label, then the initiator's (Mac's) and the
    /// responder's (PC's) static Noise keys, so the run is tied to both
    /// identities (draft section 10.1.1).
    static func channelIdentifier(clientStatic: Data, hostStatic: Data) -> Data {
        lvCat(Data("relay-v4".utf8), clientStatic, hostStatic)
    }

    // MARK: generator (sections 8.1, 8.2)

    static func generatorString(prs: Data, ci: Data, sid: Data) -> Data {
        let zpad = max(0, hashBlockBytes - 1 - prependLen(prs).count - prependLen(dsi).count)
        return lvCat(dsi, prs, Data(count: zpad), ci, sid)
    }

    static func generator(prs: Data, ci: Data, sid: Data) -> Data {
        let hash = Data(SHA512.hash(data: generatorString(prs: prs, ci: ci, sid: sid))).prefix(32)
        return Elligator2.map(Data(hash))
    }

    // MARK: group operations

    /// X25519(y, g), refusing the neutral element (the all-zero output that a
    /// low-order point produces).
    static func scalarMultVfy(_ scalar: Data, _ point: Data) throws -> Data {
        let result: Data
        do {
            let y = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            let g = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: point)
            result = try y.sharedSecretFromKeyAgreement(with: g).withUnsafeBytes { Data($0) }
        } catch {
            throw CPaceError.invalidPoint
        }
        var acc: UInt8 = 0
        for b in result { acc |= b }
        if acc == 0 { throw CPaceError.invalidPoint }
        return result
    }

    /// 32 random bytes (X25519 clamps them).
    static func sampleScalar() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    // MARK: ISK and confirmation (sections 7.2, 10.4)

    static func isk(sid: Data, k: Data, ya: Data, ada: Data, yb: Data, adb: Data) -> Data {
        let transcript = lvCat(ya, ada) + lvCat(yb, adb)
        return Data(SHA512.hash(data: lvCat(dsi + Data("_ISK".utf8), sid, k) + transcript))
    }

    /// Ta over lv_cat(Ya, ADa), Tb over lv_cat(Yb, ADb), with
    /// mac_key = H(b"CPaceMac" || sid || ISK); HMAC-SHA512 cut to 32 bytes.
    static func confirmationTag(sid: Data, isk: Data, share: Data, ad: Data) -> Data {
        let macKey = Data(SHA512.hash(data: Data("CPaceMac".utf8) + sid + isk))
        let mac = HMAC<SHA512>.authenticationCode(for: lvCat(share, ad), using: SymmetricKey(data: macKey))
        return Data(mac).prefix(tagBytes)
    }

    /// Byte-for-byte comparison that does not stop at the first difference.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// The Mac's side (A): send `share`, then `finish` with the PC's reply.
struct CPaceInitiator {
    let share: Data
    private let scalar: Data
    private let sid: Data
    private let ad: Data

    /// `scalar` is for test vectors only.
    init(prs: Data, ci: Data, sid: Data, ad: Data = Data(), scalar: Data? = nil) throws {
        self.scalar = scalar ?? CPace.sampleScalar()
        self.sid = sid
        self.ad = ad
        share = try CPace.scalarMultVfy(self.scalar, CPace.generator(prs: prs, ci: ci, sid: sid))
    }

    /// Check the PC's share and tag; return ISK and the tag to send back.
    /// Throws `confirmationFailed` when the PINs differ (or the peer is not
    /// the PC it claims to be: the two look the same from here).
    func finish(peerShare: Data, peerAD: Data = Data(), peerTag: Data) throws -> (isk: Data, tag: Data) {
        let k = try CPace.scalarMultVfy(scalar, peerShare)
        let isk = CPace.isk(sid: sid, k: k, ya: share, ada: ad, yb: peerShare, adb: peerAD)
        let expected = CPace.confirmationTag(sid: sid, isk: isk, share: peerShare, ad: peerAD)
        guard CPace.constantTimeEqual(expected, peerTag) else { throw CPaceError.confirmationFailed }
        return (isk, CPace.confirmationTag(sid: sid, isk: isk, share: share, ad: ad))
    }
}

/// The PC's side (B): answer the Mac's share with `share` + `tag`, then check
/// the Mac's tag. Lives here for fakehost and tests.
struct CPaceResponder {
    let share: Data
    let tag: Data
    let isk: Data
    private let sid: Data
    private let peerShare: Data
    private let peerAD: Data

    init(prs: Data, ci: Data, sid: Data, peerShare: Data, peerAD: Data = Data(), ad: Data = Data(), scalar: Data? = nil) throws {
        let y = scalar ?? CPace.sampleScalar()
        self.sid = sid
        self.peerShare = peerShare
        self.peerAD = peerAD
        share = try CPace.scalarMultVfy(y, CPace.generator(prs: prs, ci: ci, sid: sid))
        let k = try CPace.scalarMultVfy(y, peerShare)
        isk = CPace.isk(sid: sid, k: k, ya: peerShare, ada: peerAD, yb: share, adb: ad)
        tag = CPace.confirmationTag(sid: sid, isk: isk, share: share, ad: ad)
    }

    func verify(peerTag: Data) -> Bool {
        CPace.constantTimeEqual(CPace.confirmationTag(sid: sid, isk: isk, share: peerShare, ad: peerAD), peerTag)
    }
}
