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
pub const CAP_PAIR_NAME: u8 = 0x01;
/// The host reads CLIENT_HELLO's picture-options extension after `name`.
pub const CAP_VIDEO_OPTIONS: u8 = 0x02;
/// The host answers TIME_REQUEST, and sends FRAME_TIMING_EXT instead of
/// FRAME_TIMING once the client has sent one.
pub const CAP_TIMING: u8 = 0x04;
/// The host reads CLIENT_HELLO's `display_scale` after the picture options.
pub const CAP_DISPLAY_SCALE: u8 = 0x08;

/// CLIENT_HELLO extension `encoder_quality`: 0 = the host's default, then
/// fastest / balanced / best (NVENC P1 / P4 / P6). STREAM_START reports the
/// value used in `video_format` bits 0-1.
pub mod encoder_quality {
    pub const DEFAULT: u8 = 0;
    pub const FASTEST: u8 = 1;
    pub const BALANCED: u8 = 2;
    pub const BEST: u8 = 3;
}

/// CLIENT_HELLO extension `video_flags`. Unknown bits are ignored.
pub mod video_flags {
    pub const FULL_COLOR: u8 = 0x01;
    pub const TEN_BIT: u8 = 0x02;
}

/// STREAM_START's last byte (`reserved` before picture options): bits 0-1
/// the encoder quality used (0 = not reported), bit 2 4:4:4, bit 3 10-bit.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VideoFormat {
    pub quality: u8,
    pub full_color: bool,
    pub ten_bit: bool,
}

impl VideoFormat {
    pub fn byte(self) -> u8 {
        (self.quality & 0x03) | u8::from(self.full_color) << 2 | u8::from(self.ten_bit) << 3
    }

    pub fn parse(byte: u8) -> Self {
        Self {
            quality: byte & 0x03,
            full_color: byte & 0x04 != 0,
            ten_bit: byte & 0x08 != 0,
        }
    }
}

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
    /// Answer to TIME_REQUEST: the echoed client time plus host receive and
    /// send times (`TimeReply`).
    pub const TIME_REPLY: u8 = 0x09;
    /// FRAME_TIMING with host-clock stamps (`FrameTimingExt`), after every
    /// FRAME once the client has sent a TIME_REQUEST.
    pub const FRAME_TIMING_EXT: u8 = 0x0A;
    pub const PAIR_RESULT: u8 = 0xA1;
    /// CPace: the host's share and confirmation tag, in answer to PAIR.
    pub const PAIR_REPLY: u8 = 0xA3;
    // client -> host
    pub const CLIENT_HELLO: u8 = 0x81;
    pub const PONG: u8 = 0x87;
    /// `u64 client_time_us`, opaque to the host (CAP_TIMING).
    pub const TIME_REQUEST: u8 = 0x88;
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

/// A host-clock time (`crate::clock`) that is not known: a re-encoded
/// picture's `present_us`, `last_input_us` before any input.
pub const UNKNOWN_TIME: u64 = u64::MAX;

fn be_u64(p: &[u8], at: usize) -> u64 {
    u64::from_be_bytes(p[at..at + 8].try_into().unwrap())
}

fn be_u32(p: &[u8], at: usize) -> u32 {
    u32::from_be_bytes(p[at..at + 4].try_into().unwrap())
}

/// TIME_REQUEST: the client's clock, echoed back untouched. Like every timing
/// payload, at least this long; anything after it is ignored.
pub fn parse_time_request(p: &[u8]) -> Option<u64> {
    (p.len() >= 8).then(|| be_u64(p, 0))
}

/// TIME_REPLY. NTP's four stamps: the client's send time (echoed) and
/// receive time (its own), the host's receive and send times.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeReply {
    pub client_time_us: u64,
    pub host_receive_us: u64,
    pub host_send_us: u64,
}

impl TimeReply {
    pub const PAYLOAD_LEN: usize = 24;

    pub fn payload(self) -> [u8; Self::PAYLOAD_LEN] {
        let mut p = [0u8; Self::PAYLOAD_LEN];
        p[0..8].copy_from_slice(&self.client_time_us.to_be_bytes());
        p[8..16].copy_from_slice(&self.host_receive_us.to_be_bytes());
        p[16..24].copy_from_slice(&self.host_send_us.to_be_bytes());
        p
    }

    pub fn parse(p: &[u8]) -> Option<Self> {
        (p.len() >= Self::PAYLOAD_LEN).then(|| Self {
            client_time_us: be_u64(p, 0),
            host_receive_us: be_u64(p, 8),
            host_send_us: be_u64(p, 16),
        })
    }
}

/// FRAME_TIMING_EXT: FRAME_TIMING plus host-clock stamps for the preceding
/// FRAME and the input counter. A new type because today's Mac ends the
/// session on a FRAME_TIMING that is not exactly 24 bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameTimingExt {
    pub sequence: u64,
    /// Source desktop frame time: DDA LastPresentTime or WGC compositor
    /// SystemRelativeTime, converted to the host clock. `UNKNOWN_TIME` on
    /// re-encode without a fresh source (including DDA cursor-only ticks).
    pub present_us: u64,
    /// When NvEncEncodePicture returned for this picture.
    pub submit_us: u64,
    /// After the FRAME was written to the socket.
    pub sent_us: u64,
    pub capture_us: u32,
    pub encode_us: u32,
    pub send_us: u32,
    /// GPU time of the desktop/composition/slot copies; `UNKNOWN_MICROS`.
    pub copy_gpu_us: u32,
    pub network_rtt_us: u32,
    /// Input messages handled since the first TIME_REQUEST.
    pub inputs_applied: u64,
    /// When the `inputs_applied`-th was handled; `UNKNOWN_TIME` before any.
    pub last_input_us: u64,
}

impl FrameTimingExt {
    pub const PAYLOAD_LEN: usize = 68;

    pub fn payload(self) -> [u8; Self::PAYLOAD_LEN] {
        let mut p = [0u8; Self::PAYLOAD_LEN];
        p[0..8].copy_from_slice(&self.sequence.to_be_bytes());
        p[8..16].copy_from_slice(&self.present_us.to_be_bytes());
        p[16..24].copy_from_slice(&self.submit_us.to_be_bytes());
        p[24..32].copy_from_slice(&self.sent_us.to_be_bytes());
        p[32..36].copy_from_slice(&self.capture_us.to_be_bytes());
        p[36..40].copy_from_slice(&self.encode_us.to_be_bytes());
        p[40..44].copy_from_slice(&self.send_us.to_be_bytes());
        p[44..48].copy_from_slice(&self.copy_gpu_us.to_be_bytes());
        p[48..52].copy_from_slice(&self.network_rtt_us.to_be_bytes());
        p[52..60].copy_from_slice(&self.inputs_applied.to_be_bytes());
        p[60..68].copy_from_slice(&self.last_input_us.to_be_bytes());
        p
    }

    pub fn parse(p: &[u8]) -> Option<Self> {
        (p.len() >= Self::PAYLOAD_LEN).then(|| Self {
            sequence: be_u64(p, 0),
            present_us: be_u64(p, 8),
            submit_us: be_u64(p, 16),
            sent_us: be_u64(p, 24),
            capture_us: be_u32(p, 32),
            encode_us: be_u32(p, 36),
            send_us: be_u32(p, 40),
            copy_gpu_us: be_u32(p, 44),
            network_rtt_us: be_u32(p, 48),
            inputs_applied: be_u64(p, 52),
            last_input_us: be_u64(p, 60),
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
    /// Picture-options extension after `name`, sent only to hosts that
    /// advertise `CAP_VIDEO_OPTIONS`; `None` when absent (means 0).
    pub encoder_quality: Option<u8>,
    pub video_flags: Option<u8>,
    /// Windows display scale for the virtual monitor in percent, after the
    /// picture options; sent only to hosts with `CAP_DISPLAY_SCALE`. `None`
    /// when absent; 0 means leave Windows' own choice.
    pub display_scale: Option<u16>,
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
        let name_end = 13 + name_len;
        let name = p.get(13..name_end)?;
        Some(ClientHello {
            version: u16::from_be_bytes([p[0], p[1]]),
            width: u16::from_be_bytes([p[2], p[3]]),
            height: u16::from_be_bytes([p[4], p[5]]),
            refresh: u16::from_be_bytes([p[6], p[7]]),
            bitrate_mbps,
            wants_input: p[10] & 0x01 != 0,
            codecs: p[11],
            name: String::from_utf8_lossy(name).into_owned(),
            // Anything after the extension is ignored, as before it existed.
            encoder_quality: p.get(name_end).copied(),
            video_flags: p.get(name_end + 1).copied(),
            display_scale: p
                .get(name_end + 2..name_end + 4)
                .map(|b| u16::from_be_bytes([b[0], b[1]])),
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
    p.push(CAP_PAIR_NAME | CAP_VIDEO_OPTIONS | CAP_TIMING | CAP_DISPLAY_SCALE);
    p
}

pub fn stream_start(
    width: u16,
    height: u16,
    fps: u16,
    bitrate_mbps: u16,
    codec: Codec,
    format: VideoFormat,
) -> Vec<u8> {
    let mut p = Vec::with_capacity(10);
    p.extend_from_slice(&width.to_be_bytes());
    p.extend_from_slice(&height.to_be_bytes());
    p.extend_from_slice(&fps.to_be_bytes());
    p.extend_from_slice(&bitrate_mbps.to_be_bytes());
    p.push(codec as u8);
    p.push(format.byte());
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
        assert_eq!(extended.len(), legacy.len() + 1);
        assert_eq!(
            extended[legacy.len()],
            CAP_PAIR_NAME | CAP_VIDEO_OPTIONS | CAP_TIMING | CAP_DISPLAY_SCALE
        );
        assert_eq!(extended[legacy.len()], 0x0f);
    }

    #[test]
    fn timing_message_types_do_not_collide() {
        let host = [
            msg::SERVER_HELLO,
            msg::STREAM_START,
            msg::CODEC_CONFIG,
            msg::FRAME,
            msg::CURSOR,
            msg::STREAM_STOP,
            msg::PING,
            msg::FRAME_TIMING,
            msg::TIME_REPLY,
            msg::FRAME_TIMING_EXT,
        ];
        assert_eq!(&host[8..], [0x09, 0x0a]);
        for (i, a) in host.iter().enumerate() {
            assert!(host[i + 1..].iter().all(|b| a != b));
        }
        assert_eq!(msg::TIME_REQUEST, 0x88);
        const { assert!(msg::TIME_REQUEST != msg::PONG && msg::TIME_REQUEST < msg::MOUSE_MOVE) };
    }

    #[test]
    fn time_request_takes_at_least_eight_bytes() {
        let t = 0x0102_0304_0506_0708u64;
        assert_eq!(parse_time_request(&t.to_be_bytes()), Some(t));
        let mut longer = t.to_be_bytes().to_vec();
        longer.extend_from_slice(&[0xff; 9]);
        assert_eq!(parse_time_request(&longer), Some(t));
        assert_eq!(parse_time_request(&longer[..7]), None);
        assert_eq!(parse_time_request(&[]), None);
    }

    #[test]
    fn time_reply_round_trips_and_ignores_trailing_bytes() {
        let reply = TimeReply {
            client_time_us: 1,
            host_receive_us: 0x1122_3344_5566_7788,
            host_send_us: u64::MAX - 1,
        };
        let payload = reply.payload();
        assert_eq!(payload.len(), 24);
        assert_eq!(&payload[..8], [0, 0, 0, 0, 0, 0, 0, 1]);
        assert_eq!(TimeReply::parse(&payload), Some(reply));
        assert_eq!(
            TimeReply::parse(&[&payload[..], &[7; 5]].concat()),
            Some(reply)
        );
        assert_eq!(TimeReply::parse(&payload[..23]), None);
    }

    #[test]
    fn frame_timing_ext_layout_and_round_trip() {
        let timing = FrameTimingExt {
            sequence: 0x0102_0304_0506_0708,
            present_us: UNKNOWN_TIME,
            submit_us: 0x1000,
            sent_us: 0x2000,
            capture_us: 0x30,
            encode_us: 0x40,
            send_us: 0x50,
            copy_gpu_us: UNKNOWN_MICROS,
            network_rtt_us: 0x60,
            inputs_applied: 0x70,
            last_input_us: 0x80,
        };
        let p = timing.payload();
        assert_eq!(p.len(), 68);
        assert_eq!(&p[0..8], [1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(&p[8..16], [0xff; 8]);
        assert_eq!(&p[16..24], 0x1000u64.to_be_bytes());
        assert_eq!(&p[24..32], 0x2000u64.to_be_bytes());
        assert_eq!(&p[32..36], [0, 0, 0, 0x30]);
        assert_eq!(&p[36..40], [0, 0, 0, 0x40]);
        assert_eq!(&p[40..44], [0, 0, 0, 0x50]);
        assert_eq!(&p[44..48], [0xff; 4]);
        assert_eq!(&p[48..52], [0, 0, 0, 0x60]);
        assert_eq!(&p[52..60], 0x70u64.to_be_bytes());
        assert_eq!(&p[60..68], 0x80u64.to_be_bytes());
        assert_eq!(FrameTimingExt::parse(&p), Some(timing));
        assert_eq!(
            FrameTimingExt::parse(&[&p[..], &[0; 12]].concat()),
            Some(timing)
        );
        assert_eq!(FrameTimingExt::parse(&p[..67]), None);
        // Not mistaken for the old 24-byte FRAME_TIMING, nor the reverse.
        assert_eq!(FrameTiming::parse(&p), None);
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
    fn client_hello_without_the_extension_asks_for_nothing() {
        let parsed = ClientHello::parse(&hello(120)).unwrap();
        assert_eq!(parsed.name, "Mac");
        assert_eq!(parsed.encoder_quality, None);
        assert_eq!(parsed.video_flags, None);
    }

    #[test]
    fn client_hello_reads_the_picture_options_extension() {
        let mut payload = hello(120);
        payload.extend_from_slice(&[
            encoder_quality::BALANCED,
            video_flags::FULL_COLOR | video_flags::TEN_BIT,
        ]);
        let parsed = ClientHello::parse(&payload).unwrap();
        assert_eq!(parsed.name, "Mac");
        assert_eq!(parsed.bitrate_mbps, 120);
        assert_eq!(parsed.encoder_quality, Some(2));
        assert_eq!(parsed.video_flags, Some(0x03));

        // A truncated extension keeps what is there; later bytes stay ignored.
        let mut short = hello(120);
        short.push(encoder_quality::BEST);
        let parsed = ClientHello::parse(&short).unwrap();
        assert_eq!(
            (parsed.encoder_quality, parsed.video_flags),
            (Some(3), None)
        );
        payload.extend_from_slice(&[0xff, 0xff]);
        let parsed = ClientHello::parse(&payload).unwrap();
        assert_eq!(
            (parsed.encoder_quality, parsed.video_flags),
            (Some(2), Some(3))
        );
    }

    #[test]
    fn client_hello_reads_the_display_scale_after_the_picture_options() {
        let mut payload = hello(120);
        payload.extend_from_slice(&[encoder_quality::DEFAULT, 0]);
        assert_eq!(ClientHello::parse(&payload).unwrap().display_scale, None);
        // One byte of a u16 is not a value.
        payload.push(0);
        assert_eq!(ClientHello::parse(&payload).unwrap().display_scale, None);
        payload.push(200);
        let parsed = ClientHello::parse(&payload).unwrap();
        assert_eq!(parsed.display_scale, Some(200));
        assert_eq!(
            (parsed.encoder_quality, parsed.video_flags),
            (Some(0), Some(0))
        );
        // Big-endian, and later bytes stay ignored.
        payload.truncate(payload.len() - 2);
        payload.extend_from_slice(&[0x01, 0x2c, 0xaa, 0xbb]);
        assert_eq!(
            ClientHello::parse(&payload).unwrap().display_scale,
            Some(300)
        );
    }

    #[test]
    fn client_hello_extension_follows_a_long_name() {
        let mut payload = hello(120);
        payload.truncate(12);
        payload.push(255);
        payload.extend_from_slice(&[b'n'; 255]);
        payload.extend_from_slice(&[encoder_quality::FASTEST, video_flags::FULL_COLOR]);
        let parsed = ClientHello::parse(&payload).unwrap();
        assert_eq!(parsed.name.len(), 255);
        assert_eq!(
            (parsed.encoder_quality, parsed.video_flags),
            (Some(1), Some(1))
        );
    }

    #[test]
    fn video_format_byte_layout() {
        assert_eq!(VideoFormat::default().byte(), 0);
        let all = VideoFormat {
            quality: encoder_quality::BEST,
            full_color: true,
            ten_bit: true,
        };
        assert_eq!(all.byte(), 0b1111);
        let cases = [
            (encoder_quality::FASTEST, false, false, 0x01),
            (encoder_quality::BALANCED, true, false, 0x06),
            (encoder_quality::BEST, false, true, 0x0b),
            (encoder_quality::DEFAULT, true, true, 0x0c),
        ];
        for (quality, full_color, ten_bit, byte) in cases {
            let format = VideoFormat {
                quality,
                full_color,
                ten_bit,
            };
            assert_eq!(format.byte(), byte);
            assert_eq!(VideoFormat::parse(byte), format);
        }
        // Bits above 3 are not ours to report.
        assert_eq!(VideoFormat::parse(0xf0 | 0x05).byte(), 0x05);
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
            stream_start(3024, 1964, 120, 500, Codec::Hevc, VideoFormat::default()),
            [0x0b, 0xd0, 0x07, 0xac, 0, 120, 0x01, 0xf4, 2, 0]
        );
    }

    #[test]
    fn stream_start_reports_the_video_format_in_its_last_byte() {
        let format = VideoFormat {
            quality: encoder_quality::BALANCED,
            full_color: true,
            ten_bit: true,
        };
        assert_eq!(
            stream_start(3024, 1964, 120, 120, Codec::Hevc, format),
            [0x0b, 0xd0, 0x07, 0xac, 0, 120, 0, 120, 2, 0x0e]
        );
    }
}
