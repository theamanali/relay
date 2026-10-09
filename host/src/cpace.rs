//! CPace (draft-irtf-cfrg-cpace-21), cipher suite CPACE-X25519-SHA512, in the
//! initiator-responder setting: the PIN-based pairing of protocol v4 (see
//! docs/PROTOCOL.md). Mirrors the Mac's `client/Sources/Relay/CPace.swift`.
//!
//! Both sides turn the PIN (PRS), a channel identifier (CI) and the Noise
//! handshake hash (sid) into a secret curve point g and run one
//! Diffie-Hellman exchange over it. Matching PINs give matching keys; a
//! mismatch gives an attacker nothing to test other PINs against offline, so
//! each attempt is one guess. Explicit key confirmation follows the draft's
//! section 10.4. The Mac is the initiator (A), the PC the responder (B).

use anyhow::{bail, Result};
use hmac::{Hmac, Mac};
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha512};

use crate::field25519;

/// Domain separation for the generator and ISK (the draft's DSI).
pub const DSI: &[u8] = b"CPace255";
/// SHA-512's input block size: the generator string pads PRS out to it.
const HASH_BLOCK_BYTES: usize = 128;
pub const TAG_LEN: usize = 32;
/// Leads the channel identifier, so a CI cannot be mistaken for another
/// protocol's.
const CI_LABEL: &[u8] = b"relay-v4";

/// A u-coordinate on Curve25519 (a share or the generator).
pub type Point = [u8; 32];
pub type Isk = [u8; 64];
pub type Tag = [u8; TAG_LEN];

// --- string helpers (appendix A.1) ------------------------------------------

/// LEB128 length, then the bytes.
pub fn prepend_len(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 2);
    let mut length = data.len();
    loop {
        let low = (length & 0x7f) as u8;
        length >>= 7;
        if length == 0 {
            out.push(low);
            break;
        }
        out.push(low | 0x80);
    }
    out.extend_from_slice(data);
    out
}

pub fn lv_cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.iter().flat_map(|part| prepend_len(part)).collect()
}

/// CI for Relay: the protocol label, then the initiator's (Mac's) and the
/// responder's (PC's) static Noise keys, so the run is tied to both
/// identities (draft section 10.1.1).
pub fn channel_identifier(client_static: &[u8; 32], host_static: &[u8; 32]) -> Vec<u8> {
    lv_cat(&[CI_LABEL, client_static, host_static])
}

// --- generator (sections 8.1, 8.2) ------------------------------------------

pub fn generator_string(prs: &[u8], ci: &[u8], sid: &[u8]) -> Vec<u8> {
    let zpad = HASH_BLOCK_BYTES.saturating_sub(1 + prepend_len(prs).len() + prepend_len(DSI).len());
    lv_cat(&[DSI, prs, &vec![0u8; zpad], ci, sid])
}

pub fn generator(prs: &[u8], ci: &[u8], sid: &[u8]) -> Point {
    let hash = Sha512::digest(generator_string(prs, ci, sid));
    let u: [u8; 32] = hash[..32].try_into().expect("SHA-512 is 64 bytes");
    // Bit 255 is cleared by the map's u-coordinate decoding.
    field25519::elligator2(&u)
}

// --- group operations --------------------------------------------------------

/// X25519(scalar, point), refusing the neutral element (the all-zero output
/// that a low-order point produces).
pub fn scalar_mult_vfy(scalar: &[u8; 32], point: &Point) -> Result<Point> {
    let result = x25519_dalek::x25519(*scalar, *point);
    if result.iter().fold(0u8, |acc, b| acc | b) == 0 {
        bail!("pairing message carried an invalid point");
    }
    Ok(result)
}

/// 32 random bytes (X25519 clamps them).
pub fn sample_scalar() -> [u8; 32] {
    let mut y = [0u8; 32];
    OsRng.fill_bytes(&mut y);
    y
}

// --- ISK and confirmation (sections 7.2, 10.4) --------------------------------

pub fn isk(sid: &[u8], k: &Point, ya: &Point, ada: &[u8], yb: &Point, adb: &[u8]) -> Isk {
    let mut h = Sha512::new();
    h.update(lv_cat(&[b"CPace255_ISK", sid, k]));
    h.update(lv_cat(&[ya, ada]));
    h.update(lv_cat(&[yb, adb]));
    let mut out = [0u8; 64];
    out.copy_from_slice(&h.finalize());
    out
}

/// Ta over lv_cat(Ya, ADa), Tb over lv_cat(Yb, ADb), with
/// mac_key = H(b"CPaceMac" || sid || ISK); HMAC-SHA512 cut to 32 bytes.
pub fn confirmation_tag(sid: &[u8], isk: &Isk, share: &Point, ad: &[u8]) -> Tag {
    let mac_key = Sha512::new()
        .chain_update(b"CPaceMac")
        .chain_update(sid)
        .chain_update(isk)
        .finalize();
    let mut mac = <Hmac<Sha512> as Mac>::new_from_slice(&mac_key).expect("any key length is fine");
    mac.update(&lv_cat(&[share, ad]));
    mac.finalize().into_bytes()[..TAG_LEN]
        .try_into()
        .expect("HMAC-SHA512 is 64 bytes")
}

/// Byte-for-byte comparison that does not stop at the first difference.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

/// The Mac's side (A): send `share`, then `finish` with the PC's reply.
pub struct Initiator {
    pub share: Point,
    scalar: [u8; 32],
    sid: Vec<u8>,
    ad: Vec<u8>,
}

impl Initiator {
    /// `scalar` is for test vectors only; `None` draws a fresh one.
    pub fn new(
        prs: &[u8],
        ci: &[u8],
        sid: &[u8],
        ad: &[u8],
        scalar: Option<[u8; 32]>,
    ) -> Result<Self> {
        let scalar = scalar.unwrap_or_else(sample_scalar);
        let share = scalar_mult_vfy(&scalar, &generator(prs, ci, sid))?;
        Ok(Initiator {
            share,
            scalar,
            sid: sid.to_vec(),
            ad: ad.to_vec(),
        })
    }

    /// Check the PC's share and tag; return ISK and the tag to send back.
    /// Fails when the PINs differ (or the peer is not the PC it claims to be:
    /// the two look the same from here).
    pub fn finish(
        &self,
        peer_share: &Point,
        peer_ad: &[u8],
        peer_tag: &[u8],
    ) -> Result<(Isk, Tag)> {
        let k = scalar_mult_vfy(&self.scalar, peer_share)?;
        let isk = isk(&self.sid, &k, &self.share, &self.ad, peer_share, peer_ad);
        let expected = confirmation_tag(&self.sid, &isk, peer_share, peer_ad);
        if !constant_time_eq(&expected, peer_tag) {
            bail!("the PINs did not match");
        }
        Ok((
            isk,
            confirmation_tag(&self.sid, &isk, &self.share, &self.ad),
        ))
    }
}

/// The PC's side (B): answer the Mac's share with `share` + `tag`, then check
/// the Mac's tag.
pub struct Responder {
    pub share: Point,
    pub tag: Tag,
    pub isk: Isk,
    sid: Vec<u8>,
    peer_share: Point,
    peer_ad: Vec<u8>,
}

impl Responder {
    /// `scalar` is for test vectors only; `None` draws a fresh one.
    pub fn new(
        prs: &[u8],
        ci: &[u8],
        sid: &[u8],
        peer_share: &Point,
        peer_ad: &[u8],
        ad: &[u8],
        scalar: Option<[u8; 32]>,
    ) -> Result<Self> {
        let y = scalar.unwrap_or_else(sample_scalar);
        let share = scalar_mult_vfy(&y, &generator(prs, ci, sid))?;
        let k = scalar_mult_vfy(&y, peer_share)?;
        let isk = isk(sid, &k, peer_share, peer_ad, &share, ad);
        let tag = confirmation_tag(sid, &isk, &share, ad);
        Ok(Responder {
            share,
            tag,
            isk,
            sid: sid.to_vec(),
            peer_share: *peer_share,
            peer_ad: peer_ad.to_vec(),
        })
    }

    pub fn verify(&self, peer_tag: &[u8]) -> bool {
        let expected = confirmation_tag(&self.sid, &self.isk, &self.peer_share, &self.peer_ad);
        constant_time_eq(&expected, peer_tag)
    }
}

#[cfg(test)]
mod tests {
    //! Vectors from draft-irtf-cfrg-cpace-21, appendices A.1 and B.1
    //! (CPACE-X25519-SHA512), as the Mac's CPaceTests.swift carries them.
    use super::*;

    fn bytes(hex: &str) -> Vec<u8> {
        hex::decode(hex).unwrap()
    }

    fn b32(hex: &str) -> [u8; 32] {
        bytes(hex).try_into().unwrap()
    }

    const PRS: &[u8] = b"Password";
    const CI: &str = "0b415f696e69746961746f720b425f726573706f6e646572";
    const SID: &str = "7e4b4791d6a8ef019b936c79fb7f2c57";
    const YA: &str = "21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080";
    const YB: &str = "848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a";
    const ADA: &[u8] = b"ADa";
    const ADB: &[u8] = b"ADb";
    const G: &str = "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f";
    const SHARE_A: &str = "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32";
    const SHARE_B: &str = "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623";
    const K: &str = "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b";
    const ISK_IR: &str = "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263";

    #[test]
    fn string_helpers() {
        assert_eq!(hex::encode(prepend_len(b"")), "00");
        assert_eq!(hex::encode(prepend_len(b"1234")), "0431323334");
        let short: Vec<u8> = (0..127).collect();
        assert_eq!(prepend_len(&short)[0], 0x7f);
        assert_eq!(prepend_len(&short).len(), 128);
        let long: Vec<u8> = (0..128).collect();
        assert_eq!(hex::encode(&prepend_len(&long)[..2]), "8001");
        assert_eq!(prepend_len(&long).len(), 130);
        assert_eq!(
            hex::encode(lv_cat(&[b"1234", b"5", b"", b"678"])),
            "043132333401350003363738"
        );
    }

    #[test]
    fn generator_string_and_generator() {
        let expected = format!(
            "0843506163653235350850617373776f72646d{}180b415f696e69746961746f720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f2c57",
            "00".repeat(109)
        );
        assert_eq!(
            hex::encode(generator_string(PRS, &bytes(CI), &bytes(SID))),
            expected
        );
        assert_eq!(hex::encode(generator(PRS, &bytes(CI), &bytes(SID))), G);
    }

    #[test]
    fn shares_key_and_isk() {
        let g = generator(PRS, &bytes(CI), &bytes(SID));
        assert_eq!(hex::encode(scalar_mult_vfy(&b32(YA), &g).unwrap()), SHARE_A);
        assert_eq!(hex::encode(scalar_mult_vfy(&b32(YB), &g).unwrap()), SHARE_B);
        assert_eq!(
            hex::encode(scalar_mult_vfy(&b32(YA), &b32(SHARE_B)).unwrap()),
            K
        );
        assert_eq!(
            hex::encode(scalar_mult_vfy(&b32(YB), &b32(SHARE_A)).unwrap()),
            K
        );
        let isk = isk(&bytes(SID), &b32(K), &b32(SHARE_A), ADA, &b32(SHARE_B), ADB);
        assert_eq!(hex::encode(isk), ISK_IR);
    }

    #[test]
    fn initiator_and_responder_reproduce_the_vector() {
        let (ci, sid) = (bytes(CI), bytes(SID));
        let a = Initiator::new(PRS, &ci, &sid, ADA, Some(b32(YA))).unwrap();
        assert_eq!(hex::encode(a.share), SHARE_A);
        let b = Responder::new(PRS, &ci, &sid, &a.share, ADA, ADB, Some(b32(YB))).unwrap();
        assert_eq!(hex::encode(b.share), SHARE_B);
        assert_eq!(hex::encode(b.isk), ISK_IR);
        let (isk, tag_a) = a.finish(&b.share, ADB, &b.tag).unwrap();
        assert_eq!(hex::encode(isk), ISK_IR);
        assert!(b.verify(&tag_a));
        assert_ne!(tag_a, b.tag);
    }

    /// B.1.10: X25519 on low-order points (and non-canonical encodings of
    /// them) gives the neutral element and must abort; the second list are
    /// non-canonical encodings of ordinary points, which checks that bit 255
    /// is cleared.
    #[test]
    fn low_order_points() {
        let s = b32("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff");
        for u in [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0100000000000000000000000000000000000000000000000000000000000000",
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
            "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
            "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        ] {
            assert!(scalar_mult_vfy(&s, &b32(u)).is_err(), "u = {u}");
        }
        for (u, q) in [
            (
                "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806",
            ),
            (
                "dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38",
            ),
            (
                "d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456",
            ),
            (
                "cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
                "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a",
            ),
            (
                "4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
                "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175",
            ),
        ] {
            assert_eq!(
                hex::encode(scalar_mult_vfy(&s, &b32(u)).unwrap()),
                q,
                "u = {u}"
            );
        }
    }

    #[test]
    fn a_low_order_share_aborts_both_roles() {
        let (ci, sid) = (bytes(CI), bytes(SID));
        let a = Initiator::new(PRS, &ci, &sid, b"", None).unwrap();
        assert!(a.finish(&[0; 32], b"", &[0; 32]).is_err());
        assert!(Responder::new(PRS, &ci, &sid, &[0; 32], b"", b"", None).is_err());
    }

    #[test]
    fn matching_pins_pair_both_ways() {
        let sid = [9u8; 32];
        let ci = channel_identifier(&[1; 32], &[2; 32]);
        let mac = Initiator::new(b"123456", &ci, &sid, b"", None).unwrap();
        let pc = Responder::new(b"123456", &ci, &sid, &mac.share, b"", b"", None).unwrap();
        let (isk, tag) = mac.finish(&pc.share, b"", &pc.tag).unwrap();
        assert_eq!(isk, pc.isk);
        assert!(pc.verify(&tag));
    }

    /// A wrong PIN on either side: the Mac rejects the PC's tag (it cannot
    /// tell a wrong PIN from an impostor), and a forged Mac tag fails here.
    #[test]
    fn a_wrong_pin_fails_confirmation() {
        let sid = [7u8; 32];
        let ci = channel_identifier(&[1; 32], &[2; 32]);
        let mac = Initiator::new(b"123456", &ci, &sid, b"", None).unwrap();
        let pc = Responder::new(b"123457", &ci, &sid, &mac.share, b"", b"", None).unwrap();
        assert!(mac.finish(&pc.share, b"", &pc.tag).is_err());
        assert!(!pc.verify(&[0; TAG_LEN]));
        assert!(!pc.verify(&pc.tag[..1]), "a short tag must not pass");
    }

    /// Same PIN, different session (another Noise handshake) or different
    /// identities: no agreement. This is what stops a relay in the middle.
    #[test]
    fn session_and_identities_are_bound() {
        let pin = b"123456";
        let ci = channel_identifier(&[1; 32], &[2; 32]);
        let other_ci = channel_identifier(&[1; 32], &[3; 32]);
        let sid = [7u8; 32];
        let mac = Initiator::new(pin, &ci, &sid, b"", None).unwrap();
        let other_session = Responder::new(pin, &ci, &[8; 32], &mac.share, b"", b"", None).unwrap();
        assert!(mac
            .finish(&other_session.share, b"", &other_session.tag)
            .is_err());
        let other_host = Responder::new(pin, &other_ci, &sid, &mac.share, b"", b"", None).unwrap();
        assert!(mac.finish(&other_host.share, b"", &other_host.tag).is_err());
    }
}
