// Arithmetic modulo p = 2^255 - 19, just enough for the Elligator 2 map that
// CPace uses to turn the PIN into a curve point. CryptoKit does X25519 but
// exposes no field operations.
//
// The representation and algorithms are TweetNaCl's (Bernstein, van Gastel,
// Janssen, Lange, Schwabe, Smetsers; public domain): sixteen signed 16-bit
// limbs in Int64, schoolbook multiplication, carries without branches. It is
// small enough to check by eye, which matters more here than speed: the map
// runs once per pairing. Limbs live in a fixed-size tuple reached through a
// pointer: no heap allocation, so nothing in the timing comes from the
// allocator.
//
// Constant time: the inputs are derived from the PIN, so nothing branches on
// or indexes by a limb value. Loops run a fixed number of times, selection
// uses masks, and all arithmetic uses the wrapping operators (&+ &- &* &<<),
// which compile without overflow checks (an overflow check is a branch on
// the value). Reviewed in the optimized arm64 build (Swift 6.4, 2026-10-08):
// every conditional branch tests a loop counter, a fixed exponent bit, an
// array length, the stack protector or a one-time initialization; none tests
// limb data. Tools/ctcheck.swift measures it (max |t| 1.5 over 200,000 runs;
// it flags a 1 µs difference at |t| 41).
//
// Self-contained (Foundation only) so Tools/fakehost.swift can compile it too.

import Foundation

struct Field25519 {
    /// Sixteen limbs, each nominally 16 bits, little-endian; not necessarily
    /// reduced. Compare encodings (`bytes`), not limbs.
    typealias Limbs = (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64,
                       Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64)
    private static let zeroLimbs: Limbs = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private var l: Limbs

    private init(_ limbs: Limbs) {
        l = limbs
    }

    /// The limbs as a pointer: plain loads and stores, no bounds checks.
    @inline(__always)
    private static func with<R>(_ x: inout Limbs, _ body: (UnsafeMutablePointer<Int64>) -> R) -> R {
        withUnsafeMutablePointer(to: &x) { $0.withMemoryRebound(to: Int64.self, capacity: 16, body) }
    }

    static let zero = Field25519(zeroLimbs)
    static let one = Field25519(small: 1)

    /// A small non-negative constant (< 2^32).
    init(small value: UInt32) {
        var l = Self.zeroLimbs
        l.0 = Int64(value & 0xffff)
        l.1 = Int64(value >> 16)
        self.l = l
    }

    /// RFC 7748 decodeUCoordinate: 32 little-endian bytes, bit 255 ignored.
    /// The value may be p or more; arithmetic reduces it.
    init(bytes: Data) {
        precondition(bytes.count == 32)
        let b = [UInt8](bytes)
        var l = Self.zeroLimbs
        Self.with(&l) { o in
            for i in 0..<16 {
                o[i] = Int64(b[2 * i]) &+ (Int64(b[2 * i + 1]) &<< 8)
            }
            o[15] &= 0x7fff
        }
        self.l = l
    }

    /// The canonical (fully reduced) 32-byte little-endian encoding.
    var bytes: Data {
        var t = l
        var m = Self.zeroLimbs
        var out = [UInt8](repeating: 0, count: 32)
        Self.with(&t) { t in
            Self.with(&m) { m in
                Self.carry(t)
                Self.carry(t)
                Self.carry(t)
                // Subtract p twice, keeping the result only when it did not go negative.
                for _ in 0..<2 {
                    m[0] = t[0] &- 0xffed
                    for i in 1..<15 {
                        m[i] = t[i] &- 0xffff &- ((m[i - 1] &>> 16) & 1)
                        m[i - 1] &= 0xffff
                    }
                    m[15] = t[15] &- 0x7fff &- ((m[14] &>> 16) & 1)
                    let borrow = (m[15] &>> 16) & 1
                    m[14] &= 0xffff
                    Self.swap(t, m, 1 &- borrow)
                }
            }
            for i in 0..<16 {
                out[2 * i] = UInt8(truncatingIfNeeded: t[i])
                out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] &>> 8)
            }
        }
        return Data(out)
    }

    static func + (a: Field25519, b: Field25519) -> Field25519 {
        var o = a.l
        var y = b.l
        with(&o) { o in with(&y) { y in for i in 0..<16 { o[i] = o[i] &+ y[i] } } }
        return Field25519(o)
    }

    static func - (a: Field25519, b: Field25519) -> Field25519 {
        var o = a.l
        var y = b.l
        with(&o) { o in with(&y) { y in for i in 0..<16 { o[i] = o[i] &- y[i] } } }
        return Field25519(o)
    }

    static prefix func - (a: Field25519) -> Field25519 {
        .zero - a
    }

    static func * (a: Field25519, b: Field25519) -> Field25519 {
        var x = a.l
        var y = b.l
        var o = zeroLimbs
        withUnsafeTemporaryAllocation(of: Int64.self, capacity: 31) { t in
            t.initialize(repeating: 0)
            with(&x) { x in
                with(&y) { y in
                    for i in 0..<16 {
                        for j in 0..<16 {
                            t[i + j] = t[i + j] &+ (x[i] &* y[j])
                        }
                    }
                }
            }
            // 2^256 = 38 (mod p): fold the high half back in.
            with(&o) { o in
                for i in 0..<15 {
                    o[i] = t[i] &+ (38 &* t[i + 16])
                }
                o[15] = t[15]
                carry(o)
                carry(o)
            }
        }
        return Field25519(o)
    }

    var squared: Field25519 { self * self }

    /// a^(p-2) = 1/a (and 0 for 0). p - 2 = 2^255 - 21: every bit from 254
    /// down to 0 is set except bits 4 and 2. The exponent is public, so the
    /// branch on the bit position leaks nothing.
    var inverse: Field25519 {
        var c = self
        for bit in stride(from: 253, through: 0, by: -1) {
            c = c.squared
            if bit != 2 && bit != 4 { c = c * self }
        }
        return c
    }

    /// a^((p-1)/2): 1 for a non-zero square, p - 1 for a non-square, 0 for 0.
    /// (p-1)/2 = 2^254 - 10: bits 253 down to 0 set except bits 3 and 0.
    var legendre: Field25519 {
        var c = self
        for bit in stride(from: 252, through: 0, by: -1) {
            c = c.squared
            if bit != 0 && bit != 3 { c = c * self }
        }
        return c
    }

    /// 1 if the two values are equal mod p, else 0, without branching.
    static func equalMask(_ a: Field25519, _ b: Field25519) -> Int64 {
        let x = [UInt8](a.bytes)
        let y = [UInt8](b.bytes)
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= x[i] ^ y[i] }
        // diff == 0 → 1, otherwise 0.
        return Int64((UInt32(diff) &- 1) >> 31)
    }

    /// `bit` 1 → a, 0 → b. `bit` must be 0 or 1.
    static func select(_ a: Field25519, _ b: Field25519, bit: Int64) -> Field25519 {
        var p = a.l
        var q = b.l
        with(&q) { q in with(&p) { p in swap(q, p, bit) } }
        return Field25519(q)
    }

    /// Swap p and q when b is 1; leave them when b is 0.
    private static func swap(_ p: UnsafeMutablePointer<Int64>, _ q: UnsafeMutablePointer<Int64>, _ b: Int64) {
        let c = ~(b &- 1)
        for i in 0..<16 {
            let t = c & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    /// Bring every limb back near 16 bits; the carry out of the top limb
    /// wraps around times 38 (2^256 = 38 mod p).
    private static func carry(_ o: UnsafeMutablePointer<Int64>) {
        for i in 0..<16 {
            o[i] = o[i] &+ (1 &<< 16)
            let c = o[i] &>> 16
            if i < 15 {
                o[i + 1] = o[i + 1] &+ (c &- 1)
            } else {
                o[0] = o[0] &+ (38 &* (c &- 1))
            }
            o[i] = o[i] &- (c &<< 16)
        }
    }
}

/// The Elligator 2 map onto Curve25519 as the CPace draft gives it
/// (draft-irtf-cfrg-cpace-21, appendix A.5; RFC 9380 section 6.7.1), returning
/// only the u-coordinate:
///
///     v = -A / (1 + Z r^2)            Z = 2, A = 486662
///     e = legendre(v^3 + A v^2 + v)
///     u = v if e = 1, else -v - A
///
/// 1 + 2 r^2 is never 0 (-1/2 is not a square mod p) and the curve
/// polynomial is never 0 at v, so no exceptional cases arise.
enum Elligator2 {
    static let a = Field25519(small: 486662)

    /// `input`: 32 bytes decoded as an RFC 7748 u-coordinate (bit 255 ignored).
    static func map(_ input: Data) -> Data {
        let r = Field25519(bytes: input)
        let v = -(a * (Field25519.one + Field25519(small: 2) * r.squared).inverse)
        let curve = v * (v * (v + a) + .one)
        let isSquare = Field25519.equalMask(curve.legendre, .one)
        let u = Field25519.select(v, -v - a, bit: isSquare)
        return u.bytes
    }
}
