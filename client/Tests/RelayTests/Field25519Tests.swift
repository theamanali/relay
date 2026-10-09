import XCTest
@testable import Relay

/// Expected values come from Python's big integers (an independent
/// implementation of the same arithmetic and of the draft's Elligator 2
/// reference code), over edge cases (0, 1, p - 1, p, p + 5, all bits set) and
/// six random inputs. Inputs are RFC 7748 u-coordinates: bit 255 is ignored.
final class Field25519Tests: XCTestCase {
    private func fe(_ hex: String) throws -> Field25519 {
        Field25519(bytes: try XCTUnwrap(Data(hex: hex)))
    }

    // a, b, a*b, a+b, a-b, 1/a, legendre(a), canonical(a)
    private let arithmetic: [(String, String, String, String, String, String, String, String)] = [
        ("0000000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"),
        ("0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0200000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000"),
        ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0500000000000000000000000000000000000000000000000000000000000000", "e8ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"),
        ("f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "5a00000000000000000000000000000000000000000000000000000000000000", "1700000000000000000000000000000000000000000000000000000000000000", "e0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "9699999999999999999999999999999999999999999999999999999999999919", "0100000000000000000000000000000000000000000000000000000000000000", "0500000000000000000000000000000000000000000000000000000000000000"),
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "c0310e2cb501b6e4b5c71cb87f42c3afc476e4c7a8a198b136ee95373a169652", "7cad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "9552c60b3d5512e575d81acb31b558bd9f8701bc3d85774b5256228b6ea9f75e", "89e3388ee3388ee3388ee3388ee3388ee3388ee3388ee3388ee3388ee3388e23", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "1200000000000000000000000000000000000000000000000000000000000000"),
        ("6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031", "2c7a9fdaa3c551070dd23134e5ab4e790383be57437e4e7f38380357c8e2f35c", "8dd9e73c8b3aedb6da36f08098d9467607a26fee068de426427bf92922b2f852", "34818babfa1aee7e3918dae803bc070fb94e8d997d682c4219d8c1bf00fb176f", "766f1bbd0ba31cbe3fafaa860678f7befe212916003ff57e0f9e2570765ef955", "0100000000000000000000000000000000000000000000000000000000000000", "6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821"),
        ("232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031", "52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dc", "7aa02a86ca4d9f0dae688daf71cf034c67658ec8251b8bdf223c224ba9434c3a", "88ecaea88a1921f18a71d072ddd0e0ebd27d585127e8220409b70314e56b460e", "be6bade80506de4616ad4525b74c5e7b7bd58903623c95e01fec33563c4b9a55", "d311bfbb5d753808e3dcfd9c8de4ffea098aec08c29bc4f8ced24e4b8246fb7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031"),
        ("52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dc", "d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a", "3d0eb24572de7b1cb517b9c4142078536a22010628aa4915ebacf36c1d3f9547", "3e5b09443f5683f50160de9572067deec4da5801384ebfc628182f643f367f26", "7925f87b45bdbfb47264acb7b37d058292cd754c8d5dce5cc0b2a05969ea2c12", "eb58bd1b47758dd04a2d5841c6b489488b8413eef304f7826a5200c939d51e1a", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e5410565c"),
        ("d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a", "0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56", "8902d971ef0765d17968656365e178fe70049c9c745c6a7fd14ba4f93360406e", "ed9c09501b1221409579de72cd006acdc473d4be24a290c30dab997978c78320", "c5980778de86a200fa81536bf1870d9f6d990ef6854e60a65abaf4905d84ce73", "74f93630079f1402fca06eecfb6c3b9071a202da93007c932faf768b9efef341", "0100000000000000000000000000000000000000000000000000000000000000", "d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a"),
        ("0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090", "6774d941b07bf867727f9e88d37f21f9de5c291708fa2e184cc7b97414b98a34", "58ae96dc8cadd8178ae0e3bcba4a5f824dd8b159a7afd533c4861ec55c788b66", "aa556bfbafdda5271117a74a212efdab0902146ff7a35ae9ee698623beca2946", "faf144f51e569744a38840dd17daa99dcb033faed35a536ba8a5b9857a0d0f0d", "0100000000000000000000000000000000000000000000000000000000000000", "0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56"),
        ("57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63010", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63010", "85fe2ecd2576eafc375e7d1c7623f3b27c80695579701c258d36f93fa4326d6d", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63010"),
    ]

    // input, Elligator 2 u-coordinate
    private let elligator: [(String, String)] = [
        ("0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"),
        ("0100000000000000000000000000000000000000000000000000000000000000", "9cdb525555555555555555555555555555555555555555555555555555555555"),
        ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "9cdb525555555555555555555555555555555555555555555555555555555555"),
        ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000"),
        ("f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "e967a8afafafafafafafafafafafafafafafafafafafafafafafafafafafaf2f"),
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1e5942dd97c756040d27755f1e5b11349cd47d796c45d07052f7e5b11541c349"),
        ("6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "a977de05a378a269ba9b1105866bd5c1575cdee2721c5028addd297ba328117e"),
        ("232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031", "549029917101a07dc02460c89d4c6a0775e7da61d1eae47ff825fedf4c16bd2d"),
        ("52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dc", "8a2b86220724f0bc56cfa4e7ac8ef4b1e2ff3e7c23d21f5188c6f960aaeb6f0f"),
        ("d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a", "53c5bb1407f45eba13ff61c9153b275bd6e7aa3480ac026272c9068f2136c448"),
        ("0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56", "078f6c9260bd8af7d3b8c2603e24e7898c8e73aab15cdc1eeeb7cf4c91e20814"),
        ("57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090", "0a4516b29681913973d4c45a1b8057f31a0c3f7e622c0b9b5e45f2bf36c84067"),
    ]

    func testArithmeticMatchesBigIntegerReference() throws {
        for (i, row) in arithmetic.enumerated() {
            let a = try fe(row.0)
            let b = try fe(row.1)
            XCTAssertEqual((a * b).bytes.hex, row.2, "a*b, row \(i)")
            XCTAssertEqual((a + b).bytes.hex, row.3, "a+b, row \(i)")
            XCTAssertEqual((a - b).bytes.hex, row.4, "a-b, row \(i)")
            XCTAssertEqual(a.inverse.bytes.hex, row.5, "1/a, row \(i)")
            XCTAssertEqual(a.legendre.bytes.hex, row.6, "legendre, row \(i)")
            XCTAssertEqual(a.bytes.hex, row.7, "canonical, row \(i)")
        }
    }

    func testInverseTimesValueIsOne() throws {
        for row in arithmetic {
            let a = try fe(row.0)
            guard a.bytes != Field25519.zero.bytes else { continue }
            XCTAssertEqual((a * a.inverse).bytes, Field25519.one.bytes)
        }
    }

    func testLongChainsStayReduced() throws {
        // Repeated operations without an explicit reduction in between, as the
        // map does, must still encode canonically.
        var x = try fe(arithmetic[5].0)
        let y = try fe(arithmetic[6].0)
        for _ in 0..<200 {
            x = (x * y + x - y).squared
        }
        let encoded = x.bytes
        XCTAssertEqual(Field25519(bytes: encoded).bytes, encoded)
        XCTAssertLessThan(encoded.last!, 0x80)
    }

    func testEqualMaskAndSelect() throws {
        let a = try fe(arithmetic[6].0)
        let b = try fe(arithmetic[7].0)
        XCTAssertEqual(Field25519.equalMask(a, a), 1)
        XCTAssertEqual(Field25519.equalMask(a, b), 0)
        // p and 0 are the same element.
        XCTAssertEqual(Field25519.equalMask(try fe(arithmetic[3].0), .zero), 1)
        XCTAssertEqual(Field25519.select(a, b, bit: 1).bytes, a.bytes)
        XCTAssertEqual(Field25519.select(a, b, bit: 0).bytes, b.bytes)
    }

    func testElligator2MatchesReference() throws {
        for (input, u) in elligator {
            XCTAssertEqual(Elligator2.map(try XCTUnwrap(Data(hex: input))).hex, u, "input \(input)")
        }
    }
}
