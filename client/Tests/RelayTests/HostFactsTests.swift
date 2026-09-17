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
        XCTAssertEqual(facts.rows.map(\.label), ["Windows:", "CPU:", "RAM:", "GPU:"])
        XCTAssertEqual(facts.rows.map(\.value), [
            "Windows 11 Pro 24H2 (build 26100)",
            "AMD Ryzen 9 7950X 16-Core Processor",
            "64 GB",
            "NVIDIA GeForce RTX 4080",
        ])
    }

    func testConnectAddressIsTheOneOnTheDialedInterfaceSubnet() {
        let subnets: [String: [IPv4Subnet]] = [
            "en5": [IPv4Subnet(address: IPv4Subnet.parse("10.0.0.20")!, mask: 0xFFFF_FF00)],       // cable to the switch
            "en0": [IPv4Subnet(address: IPv4Subnet.parse("192.168.1.30")!, mask: 0xFFFF_FF00)],    // Wi-Fi
            "utun4": [IPv4Subnet(address: IPv4Subnet.parse("100.90.1.2")!, mask: 0xFFFF_FFFF)],    // Tailscale, /32
        ]
        let pc = ["10.0.0.46", "192.168.1.77", "100.98.48.108"]
        // Seen on the cable and Wi-Fi: the cable wins.
        XCTAssertEqual(LocalNetworks.address(among: pc, reachedVia: ["en5", "en0"], subnets: subnets), "10.0.0.46")
        // Only sharing the Wi-Fi network.
        XCTAssertEqual(LocalNetworks.address(among: pc, reachedVia: ["en0"], subnets: subnets), "192.168.1.77")
        // Tailscale never matches, so a host seen only there shows no address.
        XCTAssertNil(LocalNetworks.address(among: pc, reachedVia: ["utun4"], subnets: subnets))
    }

    func testMissingFactsProduceNoLines() {
        XCTAssertTrue(HostFacts(txt: NWTXTRecord(["pk": "00"])).rows.isEmpty)
        var partial = HostFacts()
        partial.ramGB = 16
        XCTAssertEqual(partial.rows.map(\.label), ["RAM:"])
        XCTAssertEqual(partial.rows.map(\.value), ["16 GB"])
    }
}
