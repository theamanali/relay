import CryptoKit
import XCTest
@testable import Relay

final class NoiseTests: XCTestCase {
    private func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try XCTUnwrap(Data(hex: hex)))
    }

    private func bytes(_ hex: String) throws -> Data {
        try XCTUnwrap(Data(hex: hex))
    }

    /// The Noise_XX_25519_ChaChaPoly_SHA256 entry of the cacophony test
    /// vectors (https://github.com/haskell-cryptography/cacophony, as carried
    /// in snow's tests/vectors/cacophony.txt): three handshake messages with
    /// payloads, then three transport messages that keep alternating
    /// directions, responder first.
    func testCacophonyVector() throws {
        let prologue = try bytes("4a6f686e2047616c74")
        let initiator = NoiseXX(
            role: .initiator,
            staticKey: try key("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"),
            prologue: prologue,
            ephemeral: try key("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"))
        let responder = NoiseXX(
            role: .responder,
            staticKey: try key("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"),
            prologue: prologue,
            ephemeral: try key("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"))

        let messages: [(payload: String, ciphertext: String)] = [
            ("4c756477696720766f6e204d69736573",
             "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"),
            ("4d757272617920526f746862617264",
             "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad"),
            ("462e20412e20486179656b",
             "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030"),
            ("4361726c204d656e676572",
             "96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df"),
            ("4a65616e2d426170746973746520536179",
             "3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5"),
            ("457567656e2042f6686d20766f6e2042617765726b",
             "eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3a58502ae3f"),
        ]

        for i in 0..<3 {
            let (writer, reader) = i % 2 == 0 ? (initiator, responder) : (responder, initiator)
            let sent = try writer.writeMessage(payload: try bytes(messages[i].payload))
            XCTAssertEqual(sent.hex, messages[i].ciphertext, "handshake message \(i)")
            XCTAssertEqual(try reader.readMessage(sent).hex, messages[i].payload, "handshake message \(i)")
        }
        XCTAssertTrue(initiator.isComplete)
        XCTAssertTrue(responder.isComplete)
        let handshakeHash = "c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e"
        XCTAssertEqual(initiator.handshakeHash.hex, handshakeHash)
        XCTAssertEqual(responder.handshakeHash.hex, handshakeHash)
        XCTAssertEqual(initiator.remoteStatic, try key("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893").publicKey.rawRepresentation)
        XCTAssertEqual(responder.remoteStatic, try key("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1").publicKey.rawRepresentation)

        var (iSend, iReceive) = try initiator.split()
        var (rSend, rReceive) = try responder.split()
        for i in 3..<6 {
            let payload = try bytes(messages[i].payload)
            if i % 2 == 0 {
                let sent = try iSend.encrypt(ad: Data(), plaintext: payload)
                XCTAssertEqual(sent.hex, messages[i].ciphertext, "transport message \(i)")
                XCTAssertEqual(try rReceive.decrypt(ad: Data(), ciphertext: sent), payload)
            } else {
                let sent = try rSend.encrypt(ad: Data(), plaintext: payload)
                XCTAssertEqual(sent.hex, messages[i].ciphertext, "transport message \(i)")
                XCTAssertEqual(try iReceive.decrypt(ad: Data(), ciphertext: sent), payload)
            }
        }
    }

    func testFreshHandshakeAgreesAndSplitsBothWays() throws {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let client = NoiseXX(role: .initiator, staticKey: clientKey, prologue: Data("RLY4".utf8))
        let host = NoiseXX(role: .responder, staticKey: hostKey, prologue: Data("RLY4".utf8))

        let msg1 = try client.writeMessage()
        XCTAssertEqual(msg1.count, 32)
        _ = try host.readMessage(msg1)
        let msg2 = try host.writeMessage()
        XCTAssertEqual(msg2.count, 32 + 48 + 16)
        _ = try client.readMessage(msg2)
        XCTAssertEqual(client.remoteStatic, hostKey.publicKey.rawRepresentation)
        let msg3 = try client.writeMessage()
        XCTAssertEqual(msg3.count, 48 + 16)
        _ = try host.readMessage(msg3)
        XCTAssertEqual(host.remoteStatic, clientKey.publicKey.rawRepresentation)
        XCTAssertEqual(client.handshakeHash, host.handshakeHash)

        var (cSend, cReceive) = try client.split()
        var (hSend, hReceive) = try host.split()
        let up = try cSend.encrypt(ad: Data(), plaintext: Data("hello".utf8))
        XCTAssertEqual(try hReceive.decrypt(ad: Data(), ciphertext: up), Data("hello".utf8))
        let down = try hSend.encrypt(ad: Data(), plaintext: Data("world".utf8))
        XCTAssertEqual(try cReceive.decrypt(ad: Data(), ciphertext: down), Data("world".utf8))
        // Each direction has its own key: our own message does not open on our receive side.
        XCTAssertThrowsError(try cReceive.decrypt(ad: Data(), ciphertext: try cSend.encrypt(ad: Data(), plaintext: Data("x".utf8))))
    }

    func testTamperedHandshakeMessageFails() throws {
        let client = NoiseXX(role: .initiator, staticKey: .init(), prologue: Data())
        let host = NoiseXX(role: .responder, staticKey: .init(), prologue: Data())
        _ = try host.readMessage(try client.writeMessage())
        var msg2 = try host.writeMessage()
        msg2[msg2.startIndex + 40] ^= 1 // inside the encrypted static key
        XCTAssertThrowsError(try client.readMessage(msg2)) { error in
            XCTAssertEqual(error as? NoiseError, .decryptFailed)
        }
    }

    func testDifferentProloguesFail() throws {
        let client = NoiseXX(role: .initiator, staticKey: .init(), prologue: Data("RLY4".utf8))
        let host = NoiseXX(role: .responder, staticKey: .init(), prologue: Data("RLY5".utf8))
        _ = try host.readMessage(try client.writeMessage())
        XCTAssertThrowsError(try client.readMessage(try host.writeMessage()))
    }

    func testMessagesOutOfTurnAreRefused() throws {
        let client = NoiseXX(role: .initiator, staticKey: .init(), prologue: Data())
        XCTAssertThrowsError(try client.readMessage(Data(count: 32))) { error in
            XCTAssertEqual(error as? NoiseError, .outOfOrder)
        }
        XCTAssertThrowsError(try client.split())
        _ = try client.writeMessage()
        XCTAssertThrowsError(try client.writeMessage())
    }

    func testCipherNonceAdvancesOnlyOnSuccess() throws {
        var sender = NoiseCipherState(key: SymmetricKey(size: .bits256))
        var receiver = NoiseCipherState(key: sender.key)
        let first = try sender.encrypt(ad: Data(), plaintext: Data("one".utf8))
        let second = try sender.encrypt(ad: Data(), plaintext: Data("two".utf8))
        XCTAssertEqual(sender.nonce, 2)
        // Out of order: the second message fails under nonce 0 and leaves it there.
        XCTAssertThrowsError(try receiver.decrypt(ad: Data(), ciphertext: second))
        XCTAssertEqual(receiver.nonce, 0)
        XCTAssertEqual(try receiver.decrypt(ad: Data(), ciphertext: first), Data("one".utf8))
        XCTAssertEqual(try receiver.decrypt(ad: Data(), ciphertext: second), Data("two".utf8))
    }
}
