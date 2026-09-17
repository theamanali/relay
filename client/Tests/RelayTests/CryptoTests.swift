import CryptoKit
import XCTest
@testable import Relay

final class CryptoTests: XCTestCase {
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
