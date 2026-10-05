import CryptoKit
import XCTest
@testable import Relay

final class CryptoTests: XCTestCase {
    /// The test vector in docs/PROTOCOL.md, also checked by host/src/crypto.rs
    /// (`vectors::known_answer`): every secret scalar is one byte repeated 32
    /// times, `paired` is 0 and the PIN is "123456".
    func testHandshakeMatchesProtocolTestVector() throws {
        let msg1 = "5444483200027b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f130faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"
        let msg2 = "5444483200027b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14ff2ee45601ec1b67310c7790404585ae697331eee1c1f8cf2419731c1fff3e6b00"
        let kC2H = "d8a97f4a0b7c64b0be967bbc40644991d83dc7e8660ee9c1afdfabe570be86a5"
        let kH2C = "f62792bb52e27a09c5932048f06bf373e6a680cf3d7ea78693e394d426405c9b"
        let kPair = "abcb29c363b089c882c6c4a4fe0d815fed0c48b0ab99fcf8a968b953e83f029f"
        let proof = "11ef35ab8b2347a264019c1995103913f92db8ef3080cea0407a04bd6adcc397"
        let frame = "47de84ee17d1168e959caa9768dd9532bdb13b964fbc3a614f30f853a16741f1270b1867ff11f18833740b2f1f5aa82d66b3c34c85db1f7c"

        func key(_ byte: UInt8) throws -> Curve25519.KeyAgreement.PrivateKey {
            try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
        }
        func hex(_ key: SymmetricKey) -> String {
            key.withUnsafeBytes { Data($0) }.hex
        }

        let pending = Handshake.Pending(identity: try key(0x11), ephemeral: try key(0x22))
        XCTAssertEqual(pending.message1.hex, msg1)

        // The host's half, built here from its secrets, must be the documented msg2.
        let hostStatic = try key(0x33).publicKey.rawRepresentation
        var hostMessage = Handshake.magic
        hostMessage.appendBE16(Handshake.version)
        hostMessage.append(hostStatic)
        hostMessage.append(try key(0x44).publicKey.rawRepresentation)
        hostMessage.append(0)
        XCTAssertEqual(hostMessage.hex, msg2)

        let result = try pending.complete(message2: try XCTUnwrap(Data(hex: msg2)))
        XCTAssertEqual(result.hostKey, hostStatic)
        XCTAssertFalse(result.paired)
        XCTAssertEqual(hex(result.keys.clientToHost), kC2H)
        XCTAssertEqual(hex(result.keys.hostToClient), kH2C)
        XCTAssertEqual(hex(result.keys.pair), kPair)

        let pinProof = Handshake.pinProof(result.keys.pair, pin: "123456")
        XCTAssertEqual(pinProof.hex, proof)

        // The client's first encrypted message: PAIR under k_c2h, counter 0.
        let sealed = try SecureChannel(key: result.keys.clientToHost)
            .seal(Proto.message(.pair, payload: pinProof))
        XCTAssertEqual(sealed.prefix(4).hex, String(format: "%08x", frame.count / 2))
        XCTAssertEqual(sealed.dropFirst(4).hex, frame)

        // And the host's side of the same channel reads it back.
        let opened = try SecureChannel(key: result.keys.clientToHost)
            .open(try XCTUnwrap(Data(hex: frame)))
        XCTAssertEqual(opened.header.type, Proto.Msg.pair.rawValue)
        XCTAssertEqual(opened.payload, pinProof)
    }

    func testHandshakeRejectsUnexpectedHostIdentity() throws {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let pending = Handshake.Pending(identity: client)
        let actualHost = Curve25519.KeyAgreement.PrivateKey()
        let hostEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let expectedHost = Curve25519.KeyAgreement.PrivateKey()

        var message2 = Handshake.magic
        message2.appendBE16(Handshake.version)
        message2.append(actualHost.publicKey.rawRepresentation)
        message2.append(hostEphemeral.publicKey.rawRepresentation)
        message2.append(1)

        XCTAssertThrowsError(try pending.complete(
            message2: message2,
            expectedHost: expectedHost.publicKey.rawRepresentation
        )) { error in
            guard case CryptoError.hostChanged(_, _) = error else {
                return XCTFail("expected hostChanged, got \(error)")
            }
        }
    }
}
