import CryptoKit
import XCTest
@testable import Relay

/// Vectors from draft-irtf-cfrg-cpace-21, appendices A.1 and B.1
/// (CPACE-X25519-SHA512).
final class CPaceTests: XCTestCase {
    private func bytes(_ hex: String) throws -> Data {
        try XCTUnwrap(Data(hex: hex))
    }

    // B.1 inputs
    private let prs = Data("Password".utf8)
    private let ci = Data(hex: "0b415f696e69746961746f720b425f726573706f6e646572")!
    private let sid = Data(hex: "7e4b4791d6a8ef019b936c79fb7f2c57")!
    private let ya = Data(hex: "21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080")!
    private let yb = Data(hex: "848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a")!
    private let ada = Data("ADa".utf8)
    private let adb = Data("ADb".utf8)
    private let g = "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f"
    private let shareA = "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"
    private let shareB = "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623"
    private let k = "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b"
    private let iskIR = "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263"

    func testStringHelpers() throws {
        XCTAssertEqual(CPace.prependLen(Data()).hex, "00")
        XCTAssertEqual(CPace.prependLen(Data("1234".utf8)).hex, "0431323334")
        let short = Data((0..<127).map { UInt8($0) })
        XCTAssertEqual(CPace.prependLen(short).prefix(1).hex, "7f")
        XCTAssertEqual(CPace.prependLen(short).count, 128)
        let long = Data((0..<128).map { UInt8($0) })
        XCTAssertEqual(CPace.prependLen(long).prefix(2).hex, "8001")
        XCTAssertEqual(CPace.prependLen(long).count, 130)
        XCTAssertEqual(CPace.lvCat(Data("1234".utf8), Data("5".utf8), Data(), Data("678".utf8)).hex,
                       "043132333401350003363738")
    }

    func testGeneratorString() throws {
        let expected = "0843506163653235350850617373776f72646d" + String(repeating: "00", count: 109)
            + "180b415f696e69746961746f720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f2c57"
        XCTAssertEqual(CPace.generatorString(prs: prs, ci: ci, sid: sid).hex, expected)
    }

    func testGenerator() throws {
        XCTAssertEqual(CPace.generator(prs: prs, ci: ci, sid: sid).hex, g)
    }

    func testSharesKeyAndISK() throws {
        let generator = CPace.generator(prs: prs, ci: ci, sid: sid)
        XCTAssertEqual(try CPace.scalarMultVfy(ya, generator).hex, shareA)
        XCTAssertEqual(try CPace.scalarMultVfy(yb, generator).hex, shareB)
        XCTAssertEqual(try CPace.scalarMultVfy(ya, try bytes(shareB)).hex, k)
        XCTAssertEqual(try CPace.scalarMultVfy(yb, try bytes(shareA)).hex, k)
        let isk = CPace.isk(sid: sid, k: try bytes(k), ya: try bytes(shareA), ada: ada, yb: try bytes(shareB), adb: adb)
        XCTAssertEqual(isk.hex, iskIR)
    }

    func testInitiatorAndResponderReproduceTheVector() throws {
        let a = try CPaceInitiator(prs: prs, ci: ci, sid: sid, ad: ada, scalar: ya)
        XCTAssertEqual(a.share.hex, shareA)
        let b = try CPaceResponder(prs: prs, ci: ci, sid: sid, peerShare: a.share, peerAD: ada, ad: adb, scalar: yb)
        XCTAssertEqual(b.share.hex, shareB)
        XCTAssertEqual(b.isk.hex, iskIR)
        let (isk, tagA) = try a.finish(peerShare: b.share, peerAD: adb, peerTag: b.tag)
        XCTAssertEqual(isk.hex, iskIR)
        XCTAssertTrue(b.verify(peerTag: tagA))
        XCTAssertEqual(tagA.count, CPace.tagBytes)
        XCTAssertNotEqual(tagA, b.tag)
    }

    /// B.1.10: X25519 on low-order points (and on non-canonical encodings of
    /// them) must give the neutral element and abort; u6, u8 to ub are
    /// non-canonical encodings of ordinary points and must give the listed
    /// results, which checks that bit 255 is cleared.
    func testLowOrderPoints() throws {
        let s = try bytes("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
        let neutral = [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0100000000000000000000000000000000000000000000000000000000000000",
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
            "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
            "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        ]
        for u in neutral {
            XCTAssertThrowsError(try CPace.scalarMultVfy(s, try bytes(u)), "u = \(u)") { error in
                XCTAssertEqual(error as? CPaceError, .invalidPoint)
            }
        }
        let valid = [
            ("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
            ("dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
            ("d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
            ("cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880", "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
            ("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7", "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
        ]
        for (u, q) in valid {
            XCTAssertEqual(try CPace.scalarMultVfy(s, try bytes(u)).hex, q, "u = \(u)")
        }
    }

    /// A low-order share from the peer aborts both roles.
    func testLowOrderShareAborts() throws {
        let a = try CPaceInitiator(prs: prs, ci: ci, sid: sid)
        XCTAssertThrowsError(try a.finish(peerShare: Data(count: 32), peerTag: Data(count: 32))) { error in
            XCTAssertEqual(error as? CPaceError, .invalidPoint)
        }
        XCTAssertThrowsError(try CPaceResponder(prs: prs, ci: ci, sid: sid, peerShare: Data(count: 32))) { error in
            XCTAssertEqual(error as? CPaceError, .invalidPoint)
        }
    }

    func testMatchingPINsPairBothWays() throws {
        let sid = Data(SHA256.hash(data: Data("a handshake hash".utf8)))
        let ci = CPace.channelIdentifier(clientStatic: Data(repeating: 1, count: 32), hostStatic: Data(repeating: 2, count: 32))
        let mac = try CPaceInitiator(prs: Data("123456".utf8), ci: ci, sid: sid)
        let pc = try CPaceResponder(prs: Data("123456".utf8), ci: ci, sid: sid, peerShare: mac.share)
        let (isk, tag) = try mac.finish(peerShare: pc.share, peerTag: pc.tag)
        XCTAssertEqual(isk, pc.isk)
        XCTAssertTrue(pc.verify(peerTag: tag))
    }

    func testPairNameTamperingAndStrippingFailConfirmation() throws {
        let pin = Data("123456".utf8)
        let ad = Proto.pairNameAD("Aman’s MacBook Pro")
        let mac = try CPaceInitiator(prs: pin, ci: ci, sid: sid, ad: ad)
        let honest = try CPaceResponder(prs: pin, ci: ci, sid: sid, peerShare: mac.share, peerAD: ad)
        let (_, tag) = try mac.finish(peerShare: honest.share, peerTag: honest.tag)
        for tampered in [Proto.pairNameAD("Someone else's Mac"), Data(), Data([0])] {
            let pc = try CPaceResponder(prs: pin, ci: ci, sid: sid, peerShare: mac.share, peerAD: tampered)
            XCTAssertThrowsError(try mac.finish(peerShare: pc.share, peerTag: pc.tag)) { error in
                XCTAssertEqual(error as? CPaceError, .confirmationFailed)
            }
            XCTAssertFalse(pc.verify(peerTag: tag))
        }
    }

    func testEmptyNamedPairingHasDifferentProofFromLegacy() throws {
        let pin = Data("123456".utf8)
        let scalar = Data(repeating: 0x55, count: 32)
        let named = try CPaceInitiator(prs: pin, ci: ci, sid: sid, ad: Proto.pairNameAD(""), scalar: scalar)
        let legacy = try CPaceInitiator(prs: pin, ci: ci, sid: sid, scalar: scalar)
        XCTAssertEqual(named.share, legacy.share)
        let pc = try CPaceResponder(prs: pin, ci: ci, sid: sid, peerShare: named.share, peerAD: Data([0]))
        XCTAssertTrue(pc.verify(peerTag: try named.finish(peerShare: pc.share, peerTag: pc.tag).tag))
        XCTAssertThrowsError(try legacy.finish(peerShare: pc.share, peerTag: pc.tag))
    }

    /// A wrong PIN on either side: the Mac rejects the PC's tag (it cannot
    /// tell a wrong PIN from an impostor), and a forged Mac tag fails on the PC.
    func testWrongPINFailsConfirmation() throws {
        let sid = Data(repeating: 7, count: 32)
        let ci = CPace.channelIdentifier(clientStatic: Data(repeating: 1, count: 32), hostStatic: Data(repeating: 2, count: 32))
        let mac = try CPaceInitiator(prs: Data("123456".utf8), ci: ci, sid: sid)
        let pc = try CPaceResponder(prs: Data("123457".utf8), ci: ci, sid: sid, peerShare: mac.share)
        XCTAssertThrowsError(try mac.finish(peerShare: pc.share, peerTag: pc.tag)) { error in
            XCTAssertEqual(error as? CPaceError, .confirmationFailed)
        }
        XCTAssertFalse(pc.verify(peerTag: Data(count: CPace.tagBytes)))
    }

    /// Same PIN, different session (another Noise handshake) or different
    /// identities: no agreement. This is what stops a relay in the middle.
    func testSessionAndIdentitiesAreBound() throws {
        let pin = Data("123456".utf8)
        let ci = CPace.channelIdentifier(clientStatic: Data(repeating: 1, count: 32), hostStatic: Data(repeating: 2, count: 32))
        let otherCI = CPace.channelIdentifier(clientStatic: Data(repeating: 1, count: 32), hostStatic: Data(repeating: 3, count: 32))
        let sid = Data(repeating: 7, count: 32)

        let mac = try CPaceInitiator(prs: pin, ci: ci, sid: sid)
        let otherSession = try CPaceResponder(prs: pin, ci: ci, sid: Data(repeating: 8, count: 32), peerShare: mac.share)
        XCTAssertThrowsError(try mac.finish(peerShare: otherSession.share, peerTag: otherSession.tag))
        let otherHost = try CPaceResponder(prs: pin, ci: otherCI, sid: sid, peerShare: mac.share)
        XCTAssertThrowsError(try mac.finish(peerShare: otherHost.share, peerTag: otherHost.tag))
    }
}
