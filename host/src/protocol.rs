//! Wire format shared with the Swift client. See docs/PROTOCOL.md.

use std::io::{self, Read, Write};

pub const VERSION: u16 = 4;
pub const DEFAULT_PORT: u16 = 8468;
pub const SERVICE_TYPE: &str = "_relay._tcp.local.";
pub const MAX_PAYLOAD: u32 = 64 * 1024 * 1024;
pub const DEFAULT_BITRATE_MBPS: u16 = 120;
pub const MIN_BITRATE_MBPS: u16 = 1;
pub const MAX_BITRATE_MBPS: u16 = 1_000;
/// Optional SERVER_HELLO capability byte, after `paired`.
/// See host/PAIR-NAME-HANDOFF.md until the Mac/spec rollout is complete.
pub const CAP_PAIR_NAME: u8 = 0x01;

/// PAIR's optional name suffix is also CPace's ADa, byte for byte. Binding
/// it into confirmation prevents even a channel intermediary changing the name.
pub struct PairRequest<'a> {
    pub share: &'a [u8; 32],
    pub name: Option<&'a str>,
    pub ad: &'a [u8],
}

impl<'a> PairRequest<'a> {
    pub fn parse(payload: &'a [u8]) -> Option<Self> {
        let share = payload.get(..32)?.try_into().ok()?;
        let ad = &payload[32..];
        let name = if ad.is_empty() {
            None // legacy v4 PAIR
        } else {
            if ad.len() != 1 + usize::from(ad[0]) {
                return None;
            }
            Some(std::str::from_utf8(&ad[1..]).ok()?)
        };
        Some(Self { share, name, ad })
    }
}

/// u8 byte length + UTF-8, truncated only at a character boundary. An empty
/// name has the one-byte ADa [0]; a legacy request has empty ADa instead.
pub fn pair_name_ad(name: &str) -> Vec<u8> {
    let mut n = name.len().min(255);
    while !name.is_char_boundary(n) {
        n -= 1;
    }
    let mut out = Vec::with_capacity(n + 1);
    out.push(n as u8);
    out.extend_from_slice(&name.as_bytes()[..n]);
    out
}

#[allow(dead_code)] // the full table documents the protocol even where the host has no use yet
pub mod msg {
    // host -> client
    pub const SERVER_HELLO: u8 = 0x01;
    pub const STREAM_START: u8 = 0x02;
    pub const CODEC_CONFIG: u8 = 0x03;
    pub const FRAME: u8 = 0x04;
    pub const CURSOR: u8 = 0x05;
    pub const STREAM_STOP: u8 = 0x06;
    pub const PING: u8 = 0x07;
    /// Timing for the immediately preceding FRAME. Optional telemetry; clients
    /// that do not know this message safely ignore it.
    pub const FRAME_TIMING: u8 = 0x08;
    pub const PAIR_RESULT: u8 = 0xA1;
    /// CPace: the host's share and confirmation tag, in answer to PAIR.
    pub const PAIR_REPLY: u8 = 0xA3;
    // client -> host
    pub const CLIENT_HELLO: u8 = 0x81;
    pub const PONG: u8 = 0x87;
    pub const MOUSE_MOVE: u8 = 0x90;
    pub const MOUSE_BUTTON: u8 = 0x91;
    pub const MOUSE_WHEEL: u8 = 0x92;
    pub const KEY: u8 = 0x93;
    // pairing (CPace inside the channel; see docs/PROTOCOL.md)
    pub const PAIR: u8 = 0xA0;
    pub const UNPAIR: u8 = 0xA2;
    /// CPace: the client's confirmation tag, after PAIR_REPLY checked out.
    pub const PAIR_CONFIRM: u8 = 0xA4;
}

pub const FLAG_KEYFRAME: u8 = 0x01;
pub const UNKNOWN_MICROS: u32 = u32::MAX;

/// Per-frame diagnostics sent immediately after the matching FRAME.
/// Durations use microseconds; `UNKNOWN_MICROS` means unavailable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameTiming {
    pub sequence: u64,
    pub capture_us: u32,
    pub encode_us: u32,
    pub send_us: u32,
    pub network_rtt_us: u32,
}

impl FrameTiming {
    pub const PAYLOAD_LEN: usize = 24;

    pub fn payload(self) -> [u8; Self::PAYLOAD_LEN] {
        let mut p = [0u8; Self::PAYLOAD_LEN];
        p[0..8].copy_from_slice(&self.sequence.to_be_bytes());
        p[8..12].copy_from_slice(&self.capture_us.to_be_bytes());
        p[12..16].copy_from_slice(&self.encode_us.to_be_bytes());
        p[16..20].copy_from_slice(&self.send_us.to_be_bytes());
        p[20..24].copy_from_slice(&self.network_rtt_us.to_be_bytes());
        p
    }

    pub fn parse(p: &[u8]) -> Option<Self> {
        (p.len() == Self::PAYLOAD_LEN).then(|| Self {
            sequence: u64::from_be_bytes(p[0..8].try_into().unwrap()),
            capture_us: u32::from_be_bytes(p[8..12].try_into().unwrap()),
            encode_us: u32::from_be_bytes(p[12..16].try_into().unwrap()),
            send_us: u32::from_be_bytes(p[16..20].try_into().unwrap()),
            network_rtt_us: u32::from_be_bytes(p[20..24].try_into().unwrap()),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Codec {
    H264 = 1,
    Hevc = 2,
}

impl Codec {
    pub fn bit(self) -> u8 {
        match self {
            Codec::H264 => 0b01,
            Codec::Hevc => 0b10,
        }
    }
}

#[allow(dead_code)]
pub mod stop_reason {
    pub const HOST_SHUTDOWN: u8 = 0;
    pub const ENCODER_FAILED: u8 = 1;
    pub const DISPLAY_LOST: u8 = 2;
    pub const BAD_VERSION: u8 = 3;
    pub const NOT_PAIRED: u8 = 4;
    pub const UNPAIRED: u8 = 5;
    /// Another client owns the display; sent in reply to CLIENT_HELLO.
    pub const BUSY: u8 = 6;
    /// The connection could not carry encoded frames at the requested bitrate.
    pub const BANDWIDTH_EXCEEDED: u8 = 7;
}

/// PAIR_RESULT payload: `u8 result`, followed by `u16 seconds` until pairing
/// is accepted again when the result is `RATE_LIMITED`.
pub mod pair_result {
    pub const WRONG_PIN: u8 = 0;
    pub const PAIRED: u8 = 1;
    pub const RATE_LIMITED: u8 = 2;
}

#[derive(Debug, Clone)]
pub struct ClientHello {
    pub version: u16,
    pub width: u16,
    pub height: u16,
    pub refresh: u16,
    pub bitrate_mbps: u16,
    pub wants_input: bool,
    pub codecs: u8,
    pub name: String,
}

impl ClientHello {
    pub fn parse(p: &[u8]) -> Option<Self> {
        if p.len() < 13 {
            return None;
        }
        let bitrate_mbps = u16::from_be_bytes([p[8], p[9]]);
        if !(MIN_BITRATE_MBPS..=MAX_BITRATE_MBPS).contains(&bitrate_mbps) {
            return None;
        }
        let name_len = p[12] as usize;
        let name = p.get(13..13 + name_len)?;
        Some(ClientHello {
            version: u16::from_be_bytes([p[0], p[1]]),
            width: u16::from_be_bytes([p[2], p[3]]),
            height: u16::from_be_bytes([p[4], p[5]]),
            refresh: u16::from_be_bytes([p[6], p[7]]),
            bitrate_mbps,
            wants_input: p[10] & 0x01 != 0,
            codecs: p[11],
            name: String::from_utf8_lossy(name).into_owned(),
        })
    }
}

/// Append the 8-byte message header.
pub fn push_header(buf: &mut Vec<u8>, ty: u8, flags: u8, payload_len: usize) {
    buf.push(ty);
    buf.push(flags);
    buf.extend_from_slice(&[0, 0]);
    buf.extend_from_slice(&(payload_len as u32).to_be_bytes());
}

/// Write one cleartext message (only used by tests and tooling; sessions
/// go through `crypto::SecureWriter`).
pub fn write_msg(w: &mut impl Write, ty: u8, flags: u8, payload: &[u8]) -> io::Result<()> {
    let mut hdr = Vec::with_capacity(8);
    push_header(&mut hdr, ty, flags, payload.len());
    w.write_all(&hdr)?;
    w.write_all(payload)
}

/// Write a message whose payload is a list of NAL units, each prefixed with a
/// 4-byte big-endian length (the layout VideoToolbox wants).
pub fn write_nal_msg(w: &mut impl Write, ty: u8, flags: u8, nals: &[Vec<u8>]) -> io::Result<()> {
    let total: usize = nals.iter().map(|n| 4 + n.len()).sum();
    let mut buf = Vec::with_capacity(8 + total);
    push_header(&mut buf, ty, flags, total);
    for n in nals {
        buf.extend_from_slice(&(n.len() as u32).to_be_bytes());
        buf.extend_from_slice(n);
    }
    w.write_all(&buf)
}

/// paired: whether this host knows the client's identity key (the client
/// learns it here because the handshake only reveals its key in msg3).
pub fn server_hello(name: &str, paired: bool) -> Vec<u8> {
    let name = name.as_bytes();
    let n = name.len().min(255);
    let mut p = Vec::with_capacity(4 + n);
    p.extend_from_slice(&VERSION.to_be_bytes());
    p.push(n as u8);
    p.extend_from_slice(&name[..n]);
    p.push(paired as u8);
    p
}

/// Older v4 clients read through `paired` and ignore the optional suffix.
/// Keep server_hello() as the legacy form for the original v4 test vector.
pub fn server_hello_with_capabilities(name: &str, paired: bool) -> Vec<u8> {
    let mut p = server_hello(name, paired);
    p.push(CAP_PAIR_NAME);
    p
}

pub fn stream_start(width: u16, height: u16, fps: u16, bitrate_mbps: u16, codec: Codec) -> Vec<u8> {
    let mut p = Vec::with_capacity(10);
    p.extend_from_slice(&width.to_be_bytes());
    p.extend_from_slice(&height.to_be_bytes());
    p.extend_from_slice(&fps.to_be_bytes());
    p.extend_from_slice(&bitrate_mbps.to_be_bytes());
    p.push(codec as u8);
    p.push(0);
    p
}

/// Read one message: (type, flags, payload).
pub fn read_msg(r: &mut impl Read) -> io::Result<(u8, u8, Vec<u8>)> {
    let mut hdr = [0u8; 8];
    r.read_exact(&mut hdr)?;
    let len = u32::from_be_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]);
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("payload of {len} bytes exceeds protocol maximum"),
        ));
    }
    let mut payload = vec![0u8; len as usize];
    r.read_exact(&mut payload)?;
    Ok((hdr[0], hdr[1], payload))
}

#[cfg(test)]
mod timing_tests {
    use super::*;

    #[test]
    fn pairing_name_encoding_is_bounded_and_preserves_unicode() {
        for name in [
            "Aman’s MacBook Pro",
            "",
            &"界".repeat(86),
            &format!("{}🦀", "a".repeat(254)),
        ] {
            let ad = pair_name_ad(name);
            let payload = [&[7; 32][..], &ad].concat();
            let parsed = PairRequest::parse(&payload).unwrap();
            assert!(payload.len() <= 288);
            assert_eq!(parsed.ad, ad);
            assert!(name.starts_with(parsed.name.unwrap()));
            assert_eq!(parsed.name.unwrap().len(), usize::from(ad[0]));
        }
        assert_eq!(pair_name_ad(&format!("{}🦀", "a".repeat(254)))[0], 254);
    }

    #[test]
    fn pairing_accepts_legacy_but_rejects_malformed_names() {
        let legacy = PairRequest::parse(&[7; 32]).unwrap();
        assert!(legacy.name.is_none() && legacy.ad.is_empty());
        assert!(PairRequest::parse(&[7; 31]).is_none());
        for suffix in [&[1][..], &[0, 1], &[1, 0xff], &[2, b'a']] {
            assert!(PairRequest::parse(&[&[7; 32][..], suffix].concat()).is_none());
        }
        assert_eq!(
            PairRequest::parse(&[&[7; 32][..], &[0]].concat())
                .unwrap()
                .name,
            Some("")
        );
    }

    #[test]
    fn name_capability_follows_the_legacy_server_hello() {
        let legacy = server_hello("Test PC", true);
        let extended = server_hello_with_capabilities("Test PC", true);
        assert_eq!(&extended[..legacy.len()], legacy);
        assert_eq!(extended[legacy.len()], CAP_PAIR_NAME);
    }

    #[test]
    fn frame_timing_round_trips() {
        let timing = FrameTiming {
            sequence: 0x0102_0304_0506_0708,
            capture_us: 231,
            encode_us: 3_204,
            send_us: 61,
            network_rtt_us: 482,
        };
        assert_eq!(FrameTiming::parse(&timing.payload()), Some(timing));
        assert_eq!(FrameTiming::parse(&timing.payload()[..23]), None);
    }

    fn hello(bitrate_mbps: u16) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&VERSION.to_be_bytes());
        payload.extend_from_slice(&3024u16.to_be_bytes());
        payload.extend_from_slice(&1964u16.to_be_bytes());
        payload.extend_from_slice(&120u16.to_be_bytes());
        payload.extend_from_slice(&bitrate_mbps.to_be_bytes());
        payload.push(1);
        payload.push(Codec::H264.bit() | Codec::Hevc.bit());
        payload.push(3);
        payload.extend_from_slice(b"Mac");
        payload
    }

    #[test]
    fn client_hello_accepts_bitrate_boundaries() {
        assert_eq!(
            ClientHello::parse(&hello(MIN_BITRATE_MBPS))
                .unwrap()
                .bitrate_mbps,
            MIN_BITRATE_MBPS
        );
        assert_eq!(
            ClientHello::parse(&hello(MAX_BITRATE_MBPS))
                .unwrap()
                .bitrate_mbps,
            MAX_BITRATE_MBPS
        );
    }

    #[test]
    fn client_hello_rejects_invalid_bitrates() {
        assert!(ClientHello::parse(&hello(0)).is_none());
        assert!(ClientHello::parse(&hello(MAX_BITRATE_MBPS + 1)).is_none());
    }

    #[test]
    fn server_hello_ends_with_paired() {
        let mut expected = vec![0, 4, 7];
        expected.extend_from_slice(b"Test PC");
        expected.push(1);
        assert_eq!(server_hello("Test PC", true), expected);
        assert_eq!(server_hello("", false), [0, 4, 0, 0]);
    }

    #[test]
    fn stream_start_reports_selected_bitrate() {
        assert_eq!(
            stream_start(3024, 1964, 120, 500, Codec::Hevc),
            [0x0b, 0xd0, 0x07, 0xac, 0, 120, 0x01, 0xf4, 2, 0]
        );
    }
}
