import XCTest
@testable import Relay

final class SessionTextTests: XCTestCase {
    func testEndReasonsReadAsSentences() {
        XCTAssertEqual(SessionText.ended("the host rejected the PIN", streamed: false), "Wrong PIN — try again")
        XCTAssertEqual(SessionText.ended("host stopped the stream (reason 0)", streamed: true), "The PC ended the session")
        XCTAssertEqual(SessionText.ended("connection closed", streamed: false), "The PC closed the connection")
        XCTAssertEqual(SessionText.ended("host stopped the stream (reason 4)", streamed: false), "The PC doesn't know this MacBook — pair again")
        XCTAssertEqual(SessionText.ended("read error: Connection reset by peer", streamed: true), "Lost the connection to the PC")
        XCTAssertEqual(SessionText.ended("connection failed: Connection refused", streamed: false), "Couldn't reach the PC")
        XCTAssertEqual(
            SessionText.ended("handshake failed: host identity changed: expected A, got B. Remove it from hosts.txt to pair again.", streamed: false),
            "This PC's identity has changed — forget it and pair again"
        )
        XCTAssertEqual(SessionText.ended("something new", streamed: false), "Couldn't connect: something new")
    }

    func testOnlyStallsReachTheFooter() {
        XCTAssertNil(SessionText.footerStatus("Connected, securing…", hostName: "PC"))
        XCTAssertNil(SessionText.footerStatus("Secure channel to 04F6A881", hostName: "PC"))
        XCTAssertEqual(SessionText.footerStatus("Waiting for host: Connection refused", hostName: "Desk PC"), "Waiting for Desk PC…")
    }
}
