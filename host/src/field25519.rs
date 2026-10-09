//! Arithmetic modulo p = 2^255 - 19, just enough for the Elligator 2 map that
//! CPace uses to turn the PIN into a curve point. No released curve25519-dalek
//! exposes the map or its field (both are `pub(crate)` there), so this is a
//! line-by-line port of the Mac's `client/Sources/Relay/Field25519.swift`.
//!
//! The representation and algorithms are TweetNaCl's (Bernstein, van Gastel,
//! Janssen, Lange, Schwabe, Smetsers; public domain): sixteen signed 16-bit
//! limbs in i64, schoolbook multiplication, carries without branches. It is
//! small enough to check by eye, which matters more here than speed: the map
//! runs once per pairing.
//!
//! Constant time: the inputs are derived from the PIN, so nothing branches on
//! or indexes by a limb value. Loops run a fixed number of times, selection
//! uses masks, and all arithmetic wraps (the `wrapping_*` calls also keep
//! debug builds from inserting overflow checks, which are branches on the
//! value). The index loops are kept as TweetNaCl writes them.
#![allow(clippy::needless_range_loop)]

use std::ops::{Add, Mul, Neg, Sub};

/// Sixteen limbs, each nominally 16 bits, little-endian; not necessarily
/// reduced. Compare encodings (`to_bytes`), not limbs.
#[derive(Clone, Copy)]
pub(crate) struct Fe([i64; 16]);

impl Fe {
    pub const ZERO: Fe = Fe([0; 16]);
    pub const ONE: Fe = Fe::small(1);

    /// A small non-negative constant.
    pub const fn small(value: u32) -> Fe {
        let mut l = [0i64; 16];
        l[0] = (value & 0xffff) as i64;
        l[1] = (value >> 16) as i64;
        Fe(l)
    }

    /// RFC 7748 decodeUCoordinate: 32 little-endian bytes, bit 255 ignored.
    /// The value may be p or more; arithmetic reduces it.
    pub fn from_bytes(b: &[u8; 32]) -> Fe {
        let mut o = [0i64; 16];
        for i in 0..16 {
            o[i] = i64::from(b[2 * i]) + (i64::from(b[2 * i + 1]) << 8);
        }
        o[15] &= 0x7fff;
        Fe(o)
    }

    /// The canonical (fully reduced) 32-byte little-endian encoding.
    pub fn to_bytes(self) -> [u8; 32] {
        let mut t = self.0;
        let mut m = [0i64; 16];
        carry(&mut t);
        carry(&mut t);
        carry(&mut t);
        // Subtract p twice, keeping the result only when it did not go negative.
        for _ in 0..2 {
            m[0] = t[0].wrapping_sub(0xffed);
            for i in 1..15 {
                m[i] = t[i].wrapping_sub(0xffff).wrapping_sub((m[i - 1] >> 16) & 1);
                m[i - 1] &= 0xffff;
            }
            m[15] = t[15].wrapping_sub(0x7fff).wrapping_sub((m[14] >> 16) & 1);
            let borrow = (m[15] >> 16) & 1;
            m[14] &= 0xffff;
            swap(&mut t, &mut m, 1i64.wrapping_sub(borrow));
        }
        let mut out = [0u8; 32];
        for i in 0..16 {
            out[2 * i] = t[i] as u8;
            out[2 * i + 1] = (t[i] >> 8) as u8;
        }
        out
    }

    pub fn square(self) -> Fe {
        self * self
    }

    /// a^(p-2) = 1/a (and 0 for 0). p - 2 = 2^255 - 21: every bit from 254
    /// down to 0 is set except bits 4 and 2. The exponent is public, so the
    /// branch on the bit position leaks nothing.
    pub fn inverse(self) -> Fe {
        let mut c = self;
        for bit in (0..=253).rev() {
            c = c.square();
            if bit != 2 && bit != 4 {
                c = c * self;
            }
        }
        c
    }

    /// a^((p-1)/2): 1 for a non-zero square, p - 1 for a non-square, 0 for 0.
    /// (p-1)/2 = 2^254 - 10: bits 253 down to 0 set except bits 3 and 0.
    pub fn legendre(self) -> Fe {
        let mut c = self;
        for bit in (0..=252).rev() {
            c = c.square();
            if bit != 0 && bit != 3 {
                c = c * self;
            }
        }
        c
    }

    /// 1 if the two values are equal mod p, else 0, without branching.
    pub fn equal_mask(a: Fe, b: Fe) -> i64 {
        let (x, y) = (a.to_bytes(), b.to_bytes());
        let mut diff = 0u8;
        for i in 0..32 {
            diff |= x[i] ^ y[i];
        }
        // diff == 0 -> 1, otherwise 0.
        (u32::from(diff).wrapping_sub(1) >> 31) as i64
    }

    /// `bit` 1 -> a, 0 -> b. `bit` must be 0 or 1.
    pub fn select(a: Fe, b: Fe, bit: i64) -> Fe {
        let mut p = a.0;
        let mut q = b.0;
        swap(&mut q, &mut p, bit);
        Fe(q)
    }
}

impl Add for Fe {
    type Output = Fe;
    fn add(self, b: Fe) -> Fe {
        let mut o = self.0;
        for i in 0..16 {
            o[i] = o[i].wrapping_add(b.0[i]);
        }
        Fe(o)
    }
}

impl Sub for Fe {
    type Output = Fe;
    fn sub(self, b: Fe) -> Fe {
        let mut o = self.0;
        for i in 0..16 {
            o[i] = o[i].wrapping_sub(b.0[i]);
        }
        Fe(o)
    }
}

impl Neg for Fe {
    type Output = Fe;
    fn neg(self) -> Fe {
        Fe::ZERO - self
    }
}

impl Mul for Fe {
    type Output = Fe;
    fn mul(self, b: Fe) -> Fe {
        let (x, y) = (self.0, b.0);
        let mut t = [0i64; 31];
        for i in 0..16 {
            for j in 0..16 {
                t[i + j] = t[i + j].wrapping_add(x[i].wrapping_mul(y[j]));
            }
        }
        // 2^256 = 38 (mod p): fold the high half back in.
        let mut o = [0i64; 16];
        for i in 0..15 {
            o[i] = t[i].wrapping_add(38i64.wrapping_mul(t[i + 16]));
        }
        o[15] = t[15];
        carry(&mut o);
        carry(&mut o);
        Fe(o)
    }
}

/// Swap p and q when b is 1; leave them when b is 0.
fn swap(p: &mut [i64; 16], q: &mut [i64; 16], b: i64) {
    let c = !(b.wrapping_sub(1));
    for i in 0..16 {
        let t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

/// Bring every limb back near 16 bits; the carry out of the top limb wraps
/// around times 38 (2^256 = 38 mod p).
fn carry(o: &mut [i64; 16]) {
    for i in 0..16 {
        o[i] = o[i].wrapping_add(1 << 16);
        let c = o[i] >> 16;
        if i < 15 {
            o[i + 1] = o[i + 1].wrapping_add(c.wrapping_sub(1));
        } else {
            o[0] = o[0].wrapping_add(38i64.wrapping_mul(c.wrapping_sub(1)));
        }
        o[i] = o[i].wrapping_sub(c << 16);
    }
}

const A: Fe = Fe::small(486662);

/// The Elligator 2 map onto Curve25519 as the CPace draft gives it
/// (draft-irtf-cfrg-cpace-21, appendix A.5; RFC 9380 section 6.7.1),
/// returning only the u-coordinate:
///
/// ```text
/// v = -A / (1 + Z r^2)            Z = 2, A = 486662
/// e = legendre(v^3 + A v^2 + v)
/// u = v if e = 1, else -v - A
/// ```
///
/// 1 + 2 r^2 is never 0 (-1/2 is not a square mod p) and the curve
/// polynomial is never 0 at v, so no exceptional cases arise. `input` is
/// decoded as an RFC 7748 u-coordinate (bit 255 ignored).
pub(crate) fn elligator2(input: &[u8; 32]) -> [u8; 32] {
    let r = Fe::from_bytes(input);
    let v = -(A * (Fe::ONE + Fe::small(2) * r.square()).inverse());
    let curve = v * (v * (v + A) + Fe::ONE);
    let is_square = Fe::equal_mask(curve.legendre(), Fe::ONE);
    Fe::select(v, -v - A, is_square).to_bytes()
}

#[cfg(test)]
mod tests {
    //! Expected values are the Mac's (client/Tests/RelayTests/
    //! Field25519Tests.swift), which come from Python's big integers over
    //! edge cases (0, 1, p - 1, p, p + 5, all bits set) and six random inputs.
    use super::*;

    fn fe(hex: &str) -> Fe {
        Fe::from_bytes(&hex::decode(hex).unwrap().try_into().unwrap())
    }

    fn hex(f: Fe) -> String {
        hex::encode(f.to_bytes())
    }

    // a, b, a*b, a+b, a-b, 1/a, legendre(a), canonical(a)
    #[rustfmt::skip]
    const ARITHMETIC: [[&str; 8]; 12] = [
        ["0000000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"],
        ["0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0200000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000", "0100000000000000000000000000000000000000000000000000000000000000"],
        ["ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"],
        ["edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0500000000000000000000000000000000000000000000000000000000000000", "e8ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"],
        ["f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "5a00000000000000000000000000000000000000000000000000000000000000", "1700000000000000000000000000000000000000000000000000000000000000", "e0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "9699999999999999999999999999999999999999999999999999999999999919", "0100000000000000000000000000000000000000000000000000000000000000", "0500000000000000000000000000000000000000000000000000000000000000"],
        ["ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "c0310e2cb501b6e4b5c71cb87f42c3afc476e4c7a8a198b136ee95373a169652", "7cad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "9552c60b3d5512e575d81acb31b558bd9f8701bc3d85774b5256228b6ea9f75e", "89e3388ee3388ee3388ee3388ee3388ee3388ee3388ee3388ee3388ee3388e23", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "1200000000000000000000000000000000000000000000000000000000000000"],
        ["6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031", "2c7a9fdaa3c551070dd23134e5ab4e790383be57437e4e7f38380357c8e2f35c", "8dd9e73c8b3aedb6da36f08098d9467607a26fee068de426427bf92922b2f852", "34818babfa1aee7e3918dae803bc070fb94e8d997d682c4219d8c1bf00fb176f", "766f1bbd0ba31cbe3fafaa860678f7befe212916003ff57e0f9e2570765ef955", "0100000000000000000000000000000000000000000000000000000000000000", "6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821"],
        ["232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031", "52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dc", "7aa02a86ca4d9f0dae688daf71cf034c67658ec8251b8bdf223c224ba9434c3a", "88ecaea88a1921f18a71d072ddd0e0ebd27d585127e8220409b70314e56b460e", "be6bade80506de4616ad4525b74c5e7b7bd58903623c95e01fec33563c4b9a55", "d311bfbb5d753808e3dcfd9c8de4ffea098aec08c29bc4f8ced24e4b8246fb7f", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031"],
        ["52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dc", "d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a", "3d0eb24572de7b1cb517b9c4142078536a22010628aa4915ebacf36c1d3f9547", "3e5b09443f5683f50160de9572067deec4da5801384ebfc628182f643f367f26", "7925f87b45bdbfb47264acb7b37d058292cd754c8d5dce5cc0b2a05969ea2c12", "eb58bd1b47758dd04a2d5841c6b489488b8413eef304f7826a5200c939d51e1a", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e5410565c"],
        ["d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a", "0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56", "8902d971ef0765d17968656365e178fe70049c9c745c6a7fd14ba4f93360406e", "ed9c09501b1221409579de72cd006acdc473d4be24a290c30dab997978c78320", "c5980778de86a200fa81536bf1870d9f6d990ef6854e60a65abaf4905d84ce73", "74f93630079f1402fca06eecfb6c3b9071a202da93007c932faf768b9efef341", "0100000000000000000000000000000000000000000000000000000000000000", "d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a"],
        ["0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090", "6774d941b07bf867727f9e88d37f21f9de5c291708fa2e184cc7b97414b98a34", "58ae96dc8cadd8178ae0e3bcba4a5f824dd8b159a7afd533c4861ec55c788b66", "aa556bfbafdda5271117a74a212efdab0902146ff7a35ae9ee698623beca2946", "faf144f51e569744a38840dd17daa99dcb033faed35a536ba8a5b9857a0d0f0d", "0100000000000000000000000000000000000000000000000000000000000000", "0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56"],
        ["57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63010", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63010", "85fe2ecd2576eafc375e7d1c7623f3b27c80695579701c258d36f93fa4326d6d", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63010"],
    ];

    // input, Elligator 2 u-coordinate
    #[rustfmt::skip]
    const ELLIGATOR: [[&str; 2]; 12] = [
        ["0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000"],
        ["0100000000000000000000000000000000000000000000000000000000000000", "9cdb525555555555555555555555555555555555555555555555555555555555"],
        ["ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "9cdb525555555555555555555555555555555555555555555555555555555555"],
        ["edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "0000000000000000000000000000000000000000000000000000000000000000"],
        ["f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", "e967a8afafafafafafafafafafafafafafafafafafafafafafafafafafafaf2f"],
        ["ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1e5942dd97c756040d27755f1e5b11349cd47d796c45d07052f7e5b11541c349"],
        ["6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd7491560821", "a977de05a378a269ba9b1105866bd5c1575cdee2721c5028addd297ba328117e"],
        ["232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5905bf031", "549029917101a07dc02460c89d4c6a0775e7da61d1eae47ff825fedf4c16bd2d"],
        ["52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dc", "8a2b86220724f0bc56cfa4e7ac8ef4b1e2ff3e7c23d21f5188c6f960aaeb6f0f"],
        ["d99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a", "53c5bb1407f45eba13ff61c9153b275bd6e7aa3480ac026272c9068f2136c448"],
        ["0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56", "078f6c9260bd8af7d3b8c2603e24e7898c8e73aab15cdc1eeeb7cf4c91e20814"],
        ["57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090", "0a4516b29681913973d4c45a1b8057f31a0c3f7e622c0b9b5e45f2bf36c84067"],
    ];

    #[test]
    fn arithmetic_matches_the_big_integer_reference() {
        for (i, row) in ARITHMETIC.iter().enumerate() {
            let (a, b) = (fe(row[0]), fe(row[1]));
            assert_eq!(hex(a * b), row[2], "a*b, row {i}");
            assert_eq!(hex(a + b), row[3], "a+b, row {i}");
            assert_eq!(hex(a - b), row[4], "a-b, row {i}");
            assert_eq!(hex(a.inverse()), row[5], "1/a, row {i}");
            assert_eq!(hex(a.legendre()), row[6], "legendre, row {i}");
            assert_eq!(hex(a), row[7], "canonical, row {i}");
        }
    }

    #[test]
    fn inverse_times_value_is_one() {
        for row in ARITHMETIC {
            let a = fe(row[0]);
            if a.to_bytes() == Fe::ZERO.to_bytes() {
                continue;
            }
            assert_eq!((a * a.inverse()).to_bytes(), Fe::ONE.to_bytes());
        }
    }

    #[test]
    fn long_chains_stay_reduced() {
        // Repeated operations without an explicit reduction in between, as
        // the map does, must still encode canonically.
        let mut x = fe(ARITHMETIC[5][0]);
        let y = fe(ARITHMETIC[6][0]);
        for _ in 0..200 {
            x = (x * y + x - y).square();
        }
        let encoded = x.to_bytes();
        assert_eq!(Fe::from_bytes(&encoded).to_bytes(), encoded);
        assert!(encoded[31] < 0x80);
    }

    #[test]
    fn equal_mask_and_select() {
        let (a, b) = (fe(ARITHMETIC[6][0]), fe(ARITHMETIC[7][0]));
        assert_eq!(Fe::equal_mask(a, a), 1);
        assert_eq!(Fe::equal_mask(a, b), 0);
        // p and 0 are the same element.
        assert_eq!(Fe::equal_mask(fe(ARITHMETIC[3][0]), Fe::ZERO), 1);
        assert_eq!(Fe::select(a, b, 1).to_bytes(), a.to_bytes());
        assert_eq!(Fe::select(a, b, 0).to_bytes(), b.to_bytes());
    }

    #[test]
    fn elligator2_matches_the_reference() {
        for [input, u] in ELLIGATOR {
            let input: [u8; 32] = hex::decode(input).unwrap().try_into().unwrap();
            assert_eq!(
                hex::encode(elligator2(&input)),
                u,
                "input {}",
                hex::encode(input)
            );
        }
    }
}
