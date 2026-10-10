import CryptoKit
import XCTest
@testable import Relay

final class CryptoTests: XCTestCase {
    private func key(_ byte: UInt8) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func bytes(_ hex: String) throws -> Data {
        try XCTUnwrap(Data(hex: hex))
    }

    /// The test vector in docs/PROTOCOL.md, also checked by host/src/crypto.rs
    /// (`tests::v4_vector`): every secret is one byte repeated 32 times, the
    /// PIN is "123456", the host is "Test PC" and does not know the client.
    /// The client half runs through the app's own code; the host half is
    /// built from the same pieces in the responder role.
    func testProtocolV4Vector() throws {
        let msg1 = "524c59340faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"
        let msg2 = "ff2ee45601ec1b67310c7790404585ae697331eee1c1f8cf2419731c1fff3e6b5cda1c2d8029877d73fad62823946ccd0c5da35c129100f43d33a59cf19ea8fc8a34ab0906b247c442369fee33d074a3cd84501b7ddd1c5eb1e0902fdeea606b"
        let msg3 = "f4e4988e97bdcbf0f799d02dd2242624bda72d200e97e322c4f723213896a31ebf3f7e0cea270326c10b7a70497b6dc220995f6d75f9fdc693ad73606f56b4b7"
        let h = "78c958b2116d50f7f7e07d8f7334849359c14d6e9d3524f8b091d25d172dfcbb"
        let ci = "0872656c61792d7634207b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13207b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14"
        let g = "4da8240a286e94f94e63fb7a308fafab75d5ba9625097ccc0960c08ee5510912"
        let ya = "d2ff03377c6866e7910d272a562919d586cc30c289a7e93baa6a11d16ae58c4a"
        let yb = "f9d2846618c6c5eba1b22562444d002b263dcea78848303ca2e07715f4044673"
        let isk = "b5cff33f2f751fd6d89e0679a2db943b92b84c9a31347d94d396c35c70fc3393ed331f63baef05915514bf5d417487d42580a838927e2cbadd90dffe9e9b488a"
        let ta = "3f1656c004be3c70b2928e9d59596b41c594b184fbdd0daa875ccf738fa95f66"
        let tb = "424d696ffbb7e8ef252e742f3541191ca4842c8cedcfe31189c86ad24e9dafd8"
        let recHello = "799e0c48aae62c91b0554ec35f909866393910523f91db8612ce2ae07994640b3a3e8c"
        let recPair = "8746b8a0817bd1b7961cdc80a04a68e507a49cb60203a1be841663bf145d5dab7558f3a726bb4f9b1c454fb29b2cfa4fa4ca4a2793bb094b"
        let recReply = "af30f22934cf7e9ef62b1c7e1d0703f756607a55bafd4a03f1c4dfb29937acd2f8f21b6f273d0075ee41be91a2cfc9fb5046777cf311f82a69efb3e0cd08507c16ca3090fa04f5791da57849f85765950b99643b6896fbfb"
        let recConfirm = "2fc518fc7bf0afdd9ed6dde4ac630eb08bdd61249b288e9329cef276b99f26732c0c6730e7d3050486b170e3a31d4d49ff313829fe5594a3"

        let mac = Handshake.initiator(identity: try key(0x11), ephemeral: try key(0x22))
        let pc = NoiseXX(role: .responder, staticKey: try key(0x33), prologue: Handshake.magic, ephemeral: try key(0x44))

        let first = Handshake.magic + (try mac.writeMessage())
        XCTAssertEqual(first.hex, msg1)
        _ = try pc.readMessage(first.dropFirst(4))
        let second = try pc.writeMessage()
        XCTAssertEqual(second.hex, msg2)
        XCTAssertEqual(second.count, Handshake.message2Length)
        _ = try mac.readMessage(second)
        XCTAssertEqual(mac.remoteStatic, try key(0x33).publicKey.rawRepresentation)
        let third = try mac.writeMessage()
        XCTAssertEqual(third.hex, msg3)
        _ = try pc.readMessage(third)
        XCTAssertEqual(mac.handshakeHash.hex, h)

        let (macSendCipher, macReceiveCipher) = try mac.split()
        let (pcSendCipher, pcReceiveCipher) = try pc.split()
        let macSend = SecureChannel(cipher: macSendCipher)
        let macReceive = SecureChannel(cipher: macReceiveCipher)
        let pcSend = SecureChannel(cipher: pcSendCipher)
        let pcReceive = SecureChannel(cipher: pcReceiveCipher, maxPayload: 4096)

        // SERVER_HELLO: v4, "Test PC", not paired.
        let hello = Proto.message(.serverHello, payload: Data([0, 4, 7]) + Data("Test PC".utf8) + Data([0]))
        let helloRecord = try pcSend.seal(hello)
        XCTAssertEqual(helloRecord.dropFirst(4).hex, recHello)
        XCTAssertEqual(helloRecord.prefix(4).hex, String(format: "%08x", recHello.count / 2))
        let greeting = try XCTUnwrap(try macReceive.open(try bytes(recHello)))
        XCTAssertEqual(Proto.ServerHello(greeting.payload), Proto.ServerHello(Data([0, 4, 7]) + Data("Test PC".utf8) + Data([0])))
        XCTAssertEqual(Proto.ServerHello(greeting.payload)?.paired, false)

        // CPace, Mac (A) and PC (B).
        let channel = CPace.channelIdentifier(clientStatic: try key(0x11).publicKey.rawRepresentation,
                                              hostStatic: try key(0x33).publicKey.rawRepresentation)
        XCTAssertEqual(channel.hex, ci)
        let prs = Data("123456".utf8)
        XCTAssertEqual(CPace.generator(prs: prs, ci: channel, sid: mac.handshakeHash).hex, g)
        let a = try CPaceInitiator(prs: prs, ci: channel, sid: mac.handshakeHash, scalar: Data(repeating: 0x55, count: 32))
        XCTAssertEqual(a.share.hex, ya)
        XCTAssertEqual(try macSend.seal(Proto.message(.pair, payload: a.share)).dropFirst(4).hex, recPair)
        let pair = try XCTUnwrap(try pcReceive.open(try bytes(recPair)))
        XCTAssertEqual(pair.header.type, Proto.Msg.pair.rawValue)

        let b = try CPaceResponder(prs: prs, ci: channel, sid: pc.handshakeHash, peerShare: pair.payload,
                                   scalar: Data(repeating: 0x66, count: 32))
        XCTAssertEqual(b.share.hex, yb)
        XCTAssertEqual(b.isk.hex, isk)
        XCTAssertEqual(b.tag.hex, tb)
        XCTAssertEqual(try pcSend.seal(Proto.message(.pairReply, payload: b.share + b.tag)).dropFirst(4).hex, recReply)
        let reply = try XCTUnwrap(try macReceive.open(try bytes(recReply)))

        let (macISK, macTag) = try a.finish(peerShare: Data(reply.payload.prefix(32)), peerTag: Data(reply.payload.suffix(32)))
        XCTAssertEqual(macISK.hex, isk)
        XCTAssertEqual(macTag.hex, ta)
        XCTAssertEqual(try macSend.seal(Proto.message(.pairConfirm, payload: macTag)).dropFirst(4).hex, recConfirm)
        let confirm = try XCTUnwrap(try pcReceive.open(try bytes(recConfirm)))
        XCTAssertTrue(b.verify(peerTag: confirm.payload))
    }

    /// HostConnection checks the PC's key between msg2 and msg3, so that a PC
    /// with another key never sees ours: msg2 must already have revealed it.
    func testMessage2RevealsTheHostIdentityBeforeMsg3() throws {
        let mac = Handshake.initiator(identity: Curve25519.KeyAgreement.PrivateKey())
        let impostorKey = Curve25519.KeyAgreement.PrivateKey()
        let impostor = NoiseXX(role: .responder, staticKey: impostorKey, prologue: Handshake.magic)
        _ = try impostor.readMessage(try mac.writeMessage())
        _ = try mac.readMessage(try impostor.writeMessage())
        XCTAssertEqual(mac.remoteStatic, impostorKey.publicKey.rawRepresentation)
        XCTAssertFalse(mac.isComplete)
        XCTAssertNil(impostor.remoteStatic, "the PC has not seen the Mac's key yet")
    }

    func testAnOlderHandshakeMagicFails() throws {
        let mac = NoiseXX(role: .initiator, staticKey: .init(), prologue: Data("TDH2".utf8))
        let pc = NoiseXX(role: .responder, staticKey: .init(), prologue: Handshake.magic)
        _ = try pc.readMessage(try mac.writeMessage())
        XCTAssertThrowsError(try mac.readMessage(try pc.writeMessage()))
    }

    // MARK: records

    /// host/PAIR-NAME-HANDOFF.md and crypto::tests::named_pairing_vector.
    /// Same Noise and CPace secrets as v4; only the name AD changes the tags.
    func testNamedPairingVector() throws {
        let mac = Handshake.initiator(identity: try key(0x11), ephemeral: try key(0x22))
        let pc = NoiseXX(role: .responder, staticKey: try key(0x33), prologue: Handshake.magic, ephemeral: try key(0x44))
        _ = try pc.readMessage(try mac.writeMessage())
        _ = try mac.readMessage(try pc.writeMessage())
        _ = try pc.readMessage(try mac.writeMessage())
        XCTAssertEqual(mac.handshakeHash.hex, "78c958b2116d50f7f7e07d8f7334849359c14d6e9d3524f8b091d25d172dfcbb")
        let ci = CPace.channelIdentifier(clientStatic: try key(0x11).publicKey.rawRepresentation,
                                         hostStatic: try key(0x33).publicKey.rawRepresentation)
        let ad = Proto.pairNameAD("Aman’s MacBook Pro")
        XCTAssertEqual(ad.hex, "14416d616ee2809973204d6163426f6f6b2050726f")
        let a = try CPaceInitiator(prs: Data("123456".utf8), ci: ci, sid: mac.handshakeHash,
                                   ad: ad, scalar: Data(repeating: 0x55, count: 32))
        let request = try XCTUnwrap(Proto.PairRequest(a.share + ad))
        let b = try CPaceResponder(prs: Data("123456".utf8), ci: ci, sid: pc.handshakeHash,
                                   peerShare: request.share, peerAD: request.ad, scalar: Data(repeating: 0x66, count: 32))
        XCTAssertEqual(a.share.hex, "d2ff03377c6866e7910d272a562919d586cc30c289a7e93baa6a11d16ae58c4a")
        XCTAssertEqual(b.share.hex, "f9d2846618c6c5eba1b22562444d002b263dcea78848303ca2e07715f4044673")
        XCTAssertEqual(b.tag.hex, "499bc005e3877364ce6002d9fcecf22d02d1a0f76019e9f6f042150add403315")
        let (isk, tag) = try a.finish(peerShare: b.share, peerTag: b.tag)
        XCTAssertEqual(isk, b.isk)
        XCTAssertEqual(isk.hex, "babe000cfe7c4fd314c375fed097aa1d24fe6378e76301176e789efc7d1028bc6b478776897e730bd39f59a00f4229e177eb7237545ba54c9fe9109b3eaab508")
        XCTAssertEqual(tag.hex, "921c83bc4d09122459355ac523326b048f5bae10859d4584543415d41b946e2d")
        XCTAssertTrue(b.verify(peerTag: tag))
    }

    private func channelPair(maxPayload: Int = Int(Proto.maxPayload)) -> (SecureChannel, SecureChannel) {
        let key = SymmetricKey(size: .bits256)
        return (SecureChannel(cipher: NoiseCipherState(key: key)),
                SecureChannel(cipher: NoiseCipherState(key: key), maxPayload: maxPayload))
    }

    /// Split sealed output back into record bodies.
    private func records(_ wire: Data) throws -> [Data] {
        var reader = FrameReader(maxFrame: SecureChannel.maxRecord)
        reader.append(wire)
        var out = [Data]()
        while let record = try reader.next() { out.append(record) }
        XCTAssertEqual(reader.buffered, 0)
        return out
    }

    func testRecordsSplitAt65519PlaintextBytes() throws {
        let cases: [(payload: Int, records: [Int])] = [
            (0, [8 + 16]),
            (65_519 - 8, [65_535]),
            (65_519 - 7, [65_535, 1 + 16]),
            (3_000_000, Array(repeating: 65_535, count: 45) + [(3_000_008 - 45 * 65_519) + 16]),
        ]
        for (size, expected) in cases {
            let (send, receive) = channelPair()
            let message = Proto.message(.frame, flags: Proto.flagKeyframe, payload: Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }))
            let parts = try records(try send.seal(message))
            XCTAssertEqual(parts.map(\.count), expected, "payload \(size)")
            var opened: (header: Proto.Header, payload: Data)?
            for (i, part) in parts.enumerated() {
                // The receive loop's read size: exactly the rest of the message.
                if i > 0 {
                    XCTAssertEqual(receive.remainingWireBytes, parts[i...].reduce(0) { $0 + 4 + $1.count })
                }
                opened = try receive.open(part)
                XCTAssertEqual(opened == nil, i < parts.count - 1)
            }
            XCTAssertEqual(opened?.header.type, Proto.Msg.frame.rawValue)
            XCTAssertEqual(opened?.header.flags, Proto.flagKeyframe)
            XCTAssertEqual(opened?.payload, Data(message.dropFirst(8)))
            XCTAssertEqual(receive.remainingWireBytes, 0)
        }
    }

    func testMessagesFollowEachOtherOnOneCounter() throws {
        let (send, receive) = channelPair()
        let wire = try send.seal(Proto.message(.ping, payload: Data(count: 8)))
            + (try send.seal(Proto.message(.frame, payload: Data(count: 100_000))))
            + (try send.seal(Proto.pong(Data(count: 8))))
        var types = [UInt8]()
        for record in try records(wire) {
            if let message = try receive.open(record) { types.append(message.header.type) }
        }
        XCTAssertEqual(types, [Proto.Msg.ping.rawValue, Proto.Msg.frame.rawValue, Proto.Msg.pong.rawValue])
    }

    func testOversizedMessageIsRefusedAtItsFirstRecord() throws {
        let (send, receive) = channelPair(maxPayload: 4096)
        let parts = try records(try send.seal(Proto.message(.frame, payload: Data(count: 100_000))))
        XCTAssertThrowsError(try receive.open(parts[0])) { error in
            guard case CryptoError.tooLarge(100_000) = error else { return XCTFail("\(error)") }
        }
    }

    func testTamperedOrReorderedRecordsFail() throws {
        let (send, receive) = channelPair()
        let parts = try records(try send.seal(Proto.message(.frame, payload: Data(count: 70_000))))
        XCTAssertEqual(parts.count, 2)
        var tampered = parts[0]
        tampered[tampered.startIndex + 3] ^= 1
        XCTAssertThrowsError(try receive.open(tampered)) { error in
            guard case CryptoError.authFailed = error else { return XCTFail("\(error)") }
        }
        // The second record under the first record's nonce.
        let (_, fresh) = channelPair()
        XCTAssertThrowsError(try fresh.open(parts[1]))
    }

    func testRecordShorterThanAHeaderIsMalformed() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = NoiseCipherState(key: key)
        let receive = SecureChannel(cipher: NoiseCipherState(key: key))
        XCTAssertThrowsError(try receive.open(try sender.encrypt(ad: Data(), plaintext: Data([1, 2, 3]))))
    }
}
