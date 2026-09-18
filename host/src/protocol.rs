//! Wire format shared with the Swift client. See docs/PROTOCOL.md.

use std::io::{self, Read, Write};

pub const VERSION: u16 = 2;
pub const DEFAULT_PORT: u16 = 8468;
pub const SERVICE_TYPE: &str = "_relay._tcp.local.";
pub const MAX_PAYLOAD: u32 = 64 * 1024 * 1024;

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
    // client -> host
    pub const CLIENT_HELLO: u8 = 0x81;
    pub const PONG: u8 = 0x87;
    pub const MOUSE_MOVE: u8 = 0x90;
    pub const MOUSE_BUTTON: u8 = 0x91;
    pub const MOUSE_WHEEL: u8 = 0x92;
    pub const KEY: u8 = 0x93;
    // pairing (client -> host proof, host -> client verdict)
    pub const PAIR: u8 = 0xA0;
    pub const UNPAIR: u8 = 0xA2;
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
    pub wants_input: bool,
    pub codecs: u8,
    pub name: String,
}

impl ClientHello {
    pub fn parse(p: &[u8]) -> Option<Self> {
        if p.len() < 11 {
            return None;
        }
        let name_len = p[10] as usize;
        let name = p.get(11..11 + name_len)?;
        Some(ClientHello {
            version: u16::from_be_bytes([p[0], p[1]]),
            width: u16::from_be_bytes([p[2], p[3]]),
            height: u16::from_be_bytes([p[4], p[5]]),
            refresh: u16::from_be_bytes([p[6], p[7]]),
            wants_input: p[8] & 0x01 != 0,
            codecs: p[9],
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

pub fn server_hello(name: &str) -> Vec<u8> {
    let name = name.as_bytes();
    let n = name.len().min(255);
    let mut p = Vec::with_capacity(3 + n);
    p.extend_from_slice(&VERSION.to_be_bytes());
    p.push(n as u8);
    p.extend_from_slice(&name[..n]);
    p
}

pub fn stream_start(width: u16, height: u16, fps: u16, codec: Codec) -> Vec<u8> {
    let mut p = Vec::with_capacity(8);
    p.extend_from_slice(&width.to_be_bytes());
    p.extend_from_slice(&height.to_be_bytes());
    p.extend_from_slice(&fps.to_be_bytes());
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
    use super::FrameTiming;

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
}
