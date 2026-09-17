import Network
import XCTest
@testable import Relay

final class HostFactsTests: XCTestCase {
    func testParsesAdvertisedFacts() {
        let txt = NWTXTRecord([
            "cpu": "AMD Ryzen 9 7950X 16-Core Processor",
            "ram": "64",
            "gpu": "NVIDIA GeForce RTX 4080",
            "os": "Windows 11 Pro 24H2 (build 26100)",
            "ip": "192.168.1.5,100.101.102.103,169.254.10.20",
        ])
        let facts = HostFacts(txt: txt)
        XCTAssertEqual(facts.ramGB, 64)
        XCTAssertEqual(facts.ips, ["192.168.1.5", "100.101.102.103", "169.254.10.20"])
        XCTAssertEqual(facts.lines, [
            "Windows 11 Pro 24H2 (build 26100)",
            "CPU  AMD Ryzen 9 7950X 16-Core Processor",
            "RAM  64 GB",
            "GPU  NVIDIA GeForce RTX 4080",
            "IP   192.168.1.5",
            "IP   100.101.102.103 (Tailscale)",
            "IP   169.254.10.20 (self-assigned, no DHCP)",
        ])
    }

    func testMissingFactsProduceNoLines() {
        XCTAssertTrue(HostFacts(txt: NWTXTRecord(["pk": "00"])).lines.isEmpty)
        var partial = HostFacts()
        partial.ramGB = 16
        XCTAssertEqual(partial.lines, ["RAM  16 GB"])
    }
}
