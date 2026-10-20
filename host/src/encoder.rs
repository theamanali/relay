//! Capture and encode behind one `AccessUnit` interface: in-process Desktop
//! Duplication → D3D11 → NVENC on the selected NVIDIA GPU, which must also
//! own the captured output. A failed start or a lost capture goes back to the
//! session's recovery loop; there is no other encoder to fall back to.

use std::sync::{Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Result;
use clap::ValueEnum;

use crate::gpu::Luid;
use crate::protocol::{encoder_quality, Codec};

/// Speed/quality trade-off: NVENC's P1 / P4 / P6.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Quality {
    Speed,
    Balanced,
    Quality,
}

impl Quality {
    /// CLIENT_HELLO's `encoder_quality`; 0 (the host's default) and values
    /// from a newer client are `None`.
    pub fn from_wire(value: u8) -> Option<Self> {
        match value {
            encoder_quality::FASTEST => Some(Quality::Speed),
            encoder_quality::BALANCED => Some(Quality::Balanced),
            encoder_quality::BEST => Some(Quality::Quality),
            _ => None,
        }
    }

    pub fn wire(self) -> u8 {
        match self {
            Quality::Speed => encoder_quality::FASTEST,
            Quality::Balanced => encoder_quality::BALANCED,
            Quality::Quality => encoder_quality::BEST,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Quality::Speed => "speed",
            Quality::Balanced => "balanced",
            Quality::Quality => "quality",
        }
    }

    pub const ALL: [Quality; 3] = [Quality::Speed, Quality::Balanced, Quality::Quality];

    /// The NVENC preset it selects.
    pub fn preset_name(self) -> &'static str {
        match self {
            Quality::Speed => "P1",
            Quality::Balanced => "P4",
            Quality::Quality => "P6",
        }
    }
}

/// What this host's encoder can do beyond 8-bit 4:2:0 at its default preset.
/// Found once at startup and advertised in TXT `enc`; sessions only apply a
/// client's flag when the matching cap is set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoCaps {
    /// Honours CLIENT_HELLO's `encoder_quality` (NVENC presets).
    pub quality: bool,
    /// False when the GPU has no usable HEVC encoder (a GTX 750 Ti, say):
    /// sessions then use H.264 even when the client offers HEVC.
    pub hevc: bool,
    /// HEVC 4:4:4.
    pub full_color: bool,
    /// HEVC 10-bit.
    pub ten_bit: bool,
}

impl VideoCaps {
    /// TXT `enc`: "q,444,10", or empty (key omitted) when nothing is supported.
    pub fn txt_value(self) -> String {
        [
            self.quality.then_some("q"),
            self.full_color.then_some("444"),
            self.ten_bit.then_some("10"),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(",")
    }
}

#[derive(Debug, Clone)]
pub struct EncoderConfig {
    /// DXGI adapter index that owns the captured output, as found for this
    /// capture attempt (it moves when the proxy adapter comes and goes).
    pub capture_adapter_idx: u32,
    /// The adapters by identity. They must be the same: capture and encode
    /// share one D3D11 device.
    pub capture_luid: Luid,
    pub encode_luid: Luid,
    pub output_idx: u32,
    /// The session's picture size: what STREAM_START announced.
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate_mbps: u32,
    pub codec: Codec,
    /// Keyframe interval in frames.
    pub gop: u32,
    pub quality: Quality,
    /// HEVC 4:4:4 / 10-bit, already negotiated against `VideoCaps`.
    pub full_color: bool,
    pub ten_bit: bool,
    pub intra_refresh: bool,
}

impl EncoderConfig {
    pub fn cross_adapter(&self) -> bool {
        self.capture_luid != self.encode_luid
    }
}

/// Native capture opened an output that is not the session's: on another
/// adapter (the index moved) or at another size than STREAM_START said.
/// Retrying at once would open the same output; the session's recovery loop retries until
/// the topology settles, then ends the session and restores the layout.
#[derive(Debug)]
pub struct CaptureMismatch;

impl std::fmt::Display for CaptureMismatch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the captured output does not match the session")
    }
}

impl std::error::Error for CaptureMismatch {}

/// Revalidate what Desktop Duplication opened against the session.
pub fn check_capture(cfg: &EncoderConfig, luid: Luid, width: u32, height: u32) -> Result<()> {
    if luid != cfg.encode_luid {
        return Err(anyhow::Error::new(CaptureMismatch).context(format!(
            "captured output is on adapter LUID {:x}:{:x}, not the encoding GPU's {:x}:{:x}",
            luid.high, luid.low, cfg.encode_luid.high, cfg.encode_luid.low
        )));
    }
    if (width, height) != (cfg.width, cfg.height) {
        return Err(anyhow::Error::new(CaptureMismatch).context(format!(
            "captured output is {width}x{height}, the session is {}x{}",
            cfg.width, cfg.height
        )));
    }
    Ok(())
}

/// Marker in an error chain: Desktop Duplication would not duplicate the
/// output because this process still duplicates it (E_INVALIDARG; the
/// previous capture is still being retired) or too many processes do
/// (DXGI_ERROR_NOT_CURRENTLY_AVAILABLE). Worth a short retry.
#[derive(Debug)]
pub struct OutputBusy;

impl std::fmt::Display for OutputBusy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the output is still being duplicated")
    }
}

impl std::error::Error for OutputBusy {}

/// Whether `error` carries the `OutputBusy` marker (a context layer).
pub fn is_output_busy(error: &anyhow::Error) -> bool {
    error.downcast_ref::<OutputBusy>().is_some()
}

/// Why native capture did not start or restart. Every kind is retried by the
/// session's recovery loop; only a refused desktop waits without its 15 s
/// limit (the PC is locked and comes back when it is unlocked).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartFailure {
    /// Desktop Duplication refused the current desktop (`DesktopNotCapturable`).
    DesktopRefused,
    /// The output opened was another adapter's or another size (`CaptureMismatch`).
    Mismatch,
    /// This process still duplicates the output (`OutputBusy`), past the retry.
    OutputBusy,
    /// Another DXGI/D3D11 failure: access lost, device removed or reset.
    Capture,
    /// NVENC itself, or anything else.
    Encoder,
}

impl StartFailure {
    pub fn label(self) -> &'static str {
        match self {
            StartFailure::DesktopRefused => "desktop refused",
            StartFailure::Mismatch => "output mismatch",
            StartFailure::OutputBusy => "output busy",
            StartFailure::Capture => "capture",
            StartFailure::Encoder => "encoder",
        }
    }
}

pub fn classify_start_failure(error: &anyhow::Error) -> StartFailure {
    if is_desktop_not_capturable(error) {
        StartFailure::DesktopRefused
    } else if is_capture_mismatch(error) {
        StartFailure::Mismatch
    } else if is_output_busy(error) {
        StartFailure::OutputBusy
    } else if error
        .chain()
        .any(|e| e.downcast_ref::<windows::core::Error>().is_some())
    {
        StartFailure::Capture
    } else {
        StartFailure::Encoder
    }
}

/// How long a new capture waits for earlier ones to finish retiring. Teardown
/// is normally tens of milliseconds; a slot still encoding can take 2 s.
const RETIRE_WAIT: Duration = Duration::from_secs(3);
/// How long, and how often, a busy output is retried.
const OUTPUT_BUSY_BUDGET: Duration = Duration::from_secs(2);
const OUTPUT_BUSY_DELAY: Duration = Duration::from_millis(100);

/// Run `attempt` again while it fails with `OutputBusy` and another try
/// still fits in `budget`; any other result is returned as it is.
pub(crate) fn retry_output_busy<T>(
    budget: Duration,
    delay: Duration,
    mut attempt: impl FnMut() -> Result<T>,
) -> Result<T> {
    let deadline = Instant::now() + budget;
    let mut tries = 1u32;
    loop {
        match attempt() {
            Err(error) if is_output_busy(&error) && Instant::now() + delay <= deadline => {
                log::info!("{error:#}; retrying (attempt {tries})");
                thread::sleep(delay);
                tries += 1;
            }
            result => return result,
        }
    }
}

/// Native encoders still being torn down on their cleanup threads. A new
/// Desktop Duplication of an output this process still duplicates fails, so
/// a new capture waits for these first, for a bounded time.
struct Retirements {
    in_flight: Mutex<usize>,
    idle: Condvar,
}

static RETIREMENTS: Retirements = Retirements::new();

impl Retirements {
    const fn new() -> Self {
        Retirements {
            in_flight: Mutex::new(0),
            idle: Condvar::new(),
        }
    }

    fn begin(&self) {
        *self.in_flight.lock().unwrap_or_else(|e| e.into_inner()) += 1;
    }

    fn end(&self) {
        let mut in_flight = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        *in_flight = in_flight.saturating_sub(1);
        if *in_flight == 0 {
            self.idle.notify_all();
        }
    }

    /// True once none are in flight; false if `timeout` passed first.
    fn wait_idle(&self, timeout: Duration) -> bool {
        let in_flight = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        let (in_flight, _) = self
            .idle
            .wait_timeout_while(in_flight, timeout, |n| *n > 0)
            .unwrap_or_else(|e| e.into_inner());
        *in_flight == 0
    }
}

/// Whether `error` (anywhere in its chain) is a `CaptureMismatch`.
pub fn is_capture_mismatch(error: &anyhow::Error) -> bool {
    error
        .chain()
        .any(|e| e.downcast_ref::<CaptureMismatch>().is_some())
}

/// One coded picture, ready for the wire.
#[derive(Debug, Default)]
pub struct AccessUnit {
    /// Slice / SEI NAL units, without start codes. AUDs and parameter sets removed.
    pub nals: Vec<Vec<u8>>,
    /// Parameter sets (VPS/SPS/PPS or SPS/PPS) that preceded this AU, if any.
    pub param_sets: Vec<Vec<u8>>,
    pub keyframe: bool,
    /// Capture/encode timings of this picture (FRAME_TIMING).
    pub timing: Option<EncoderTiming>,
}

#[derive(Debug, Clone, Copy)]
pub struct EncoderTiming {
    pub capture: Duration,
    pub encode: Duration,
    /// Source desktop frame time (DDA present or WGC compositor), host clock
    /// (`crate::clock`); `protocol::UNKNOWN_TIME` for a re-encoded picture.
    pub present_us: u64,
    /// Host clock when the picture was submitted to the encoder.
    pub submit_us: u64,
    /// Opt-in local association for diagnostics; not part of any wire record.
    pub(crate) source_trace: Option<crate::source_timing::TraceTag>,
}

type Native = crate::native_nvenc::NativeNvenc;

pub struct Encoder {
    // `None` is the short recovery state between dropping a failed Desktop
    // Duplication session and creating its replacement.
    inner: Option<Box<Native>>,
}

impl Encoder {
    /// No capture yet: the session starts in its recovery loop, which keeps
    /// trying to create one. Used when native capture did not start at
    /// connect time (a locked desktop, a mode change still settling).
    pub fn waiting() -> Self {
        Encoder { inner: None }
    }

    /// NVENC and the display driver can stop returning from teardown calls
    /// during a fullscreen GPU reset. Never let that block the session thread:
    /// a detached cleanup thread owns every native handle until teardown does
    /// finish, while the session can restore the user's physical displays.
    fn retire(native: Box<Native>) {
        // Pass the allocation as an address so a failure to create the
        // janitor thread leaks it instead of synchronously dropping it
        // on this display-restoration path. Once started, the janitor
        // is the sole owner and reconstructs the Box exactly once.
        let native_address = Box::into_raw(native) as usize;
        // The next capture waits for this one to be gone (bounded):
        // the same process cannot duplicate an output twice.
        RETIREMENTS.begin();
        if let Err(error) = std::thread::Builder::new()
            .name("nvenc-retire".into())
            .spawn(move || {
                unsafe {
                    drop(Box::from_raw(native_address as *mut Native));
                }
                RETIREMENTS.end();
            })
        {
            // Leaked: nothing will ever end it, so do not make the
            // next capture wait for it.
            RETIREMENTS.end();
            log::warn!("could not start NVENC cleanup thread: {error}");
        }
    }

    /// Start native capture and encode. An output this process still
    /// duplicates is waited for and retried; a refused desktop is marked
    /// `DesktopNotCapturable`; anything else is returned for the session's
    /// recovery loop (`classify_start_failure` says what it was).
    pub fn spawn(cfg: &EncoderConfig) -> Result<Self> {
        if cfg.cross_adapter() {
            return Err(anyhow::Error::new(CaptureMismatch).context(
                "the display is on another adapter than the encoding GPU; capture and encode must share one",
            ));
        }
        if !RETIREMENTS.wait_idle(RETIRE_WAIT) {
            log::warn!(
                "an earlier capture is still being torn down after {RETIRE_WAIT:?}; starting anyway"
            );
        }
        match retry_output_busy(OUTPUT_BUSY_BUDGET, OUTPUT_BUSY_DELAY, || Native::spawn(cfg)) {
            Ok(native) => Ok(Self {
                inner: Some(Box::new(native)),
            }),
            // Locked, or the secure desktop is up and this is not a SYSTEM
            // worker: the session waits for the desktop to come back.
            Err(e) if is_access_denied(&e) => Err(e.context(DesktopNotCapturable)),
            Err(e) => Err(e),
        }
    }

    /// The next picture. `Ok(None)` and errors both send the session into
    /// its recovery loop, which restarts capture.
    pub fn next_access_unit(&mut self) -> Result<Option<AccessUnit>> {
        match &mut self.inner {
            Some(native) => native.next_access_unit(),
            None => Ok(None),
        }
    }

    /// Drop the failed capture before constructing its replacement: the old
    /// duplication must be gone before `DuplicateOutput` creates the next one
    /// (`spawn` waits for its retirement).
    pub fn restart(&mut self, cfg: &EncoderConfig) -> Result<()> {
        if let Some(native) = self.inner.take() {
            Self::retire(native);
        }
        *self = Self::spawn(cfg)?;
        Ok(())
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        if let Some(native) = self.inner.take() {
            Self::retire(native);
        }
    }
}

/// Incremental Annex-B splitter that groups NAL units into access units.
///
/// AU boundaries follow the spec's first-NAL-of-picture rule: an AUD, a
/// parameter set, a prefix SEI, or a VCL NAL with first_slice_segment_in_pic_flag
/// set starts a new AU once the current one already holds slice data. With
/// `-aud 1` every AU starts with an AUD anyway; the other rules are a safety net.
pub struct AnnexBParser {
    codec: Codec,
    buf: Vec<u8>,
    pending: Vec<Vec<u8>>,
    pending_param_sets: Vec<Vec<u8>>,
    pending_has_vcl: bool,
    pending_key: bool,
}

impl AnnexBParser {
    pub fn new(codec: Codec) -> Self {
        AnnexBParser {
            codec,
            buf: Vec::with_capacity(1 << 20),
            pending: Vec::new(),
            pending_param_sets: Vec::new(),
            pending_has_vcl: false,
            pending_key: false,
        }
    }

    pub fn push(&mut self, data: &[u8], out: &mut std::collections::VecDeque<AccessUnit>) {
        self.buf.extend_from_slice(data);

        let Some(mut sc) = find_start_code(&self.buf, 0) else {
            // No start code yet: keep at most the last 3 bytes (a start code could
            // straddle the chunk boundary) and drop the garbage before it.
            let keep = self.buf.len().min(3);
            let start = self.buf.len() - keep;
            self.buf.drain(..start);
            return;
        };

        loop {
            let nal_start = sc.1;
            match find_start_code(&self.buf, nal_start) {
                Some(next) => {
                    let nal = self.buf[nal_start..next.0].to_vec();
                    self.on_nal(nal, out);
                    sc = next;
                }
                None => {
                    // The NAL beginning at `sc` is still incomplete; keep it.
                    self.buf.drain(..sc.0);
                    return;
                }
            }
        }
    }

    /// Called at end-of-stream: emit the trailing AU.
    pub fn finish(&mut self, out: &mut std::collections::VecDeque<AccessUnit>) {
        if let Some(sc) = find_start_code(&self.buf, 0) {
            let nal = self.buf[sc.1..].to_vec();
            self.on_nal(nal, out);
        }
        self.buf.clear();
        self.flush(out);
    }

    fn on_nal(&mut self, nal: Vec<u8>, out: &mut std::collections::VecDeque<AccessUnit>) {
        if nal.is_empty() {
            return;
        }
        let kind = classify(self.codec, &nal);

        let starts_new_au = kind.is_aud
            || (self.pending_has_vcl
                && (kind.is_param_set || kind.is_prefix_sei || (kind.is_vcl && kind.first_slice)));
        if starts_new_au {
            self.flush(out);
        }

        if kind.is_aud {
            return;
        }
        if kind.is_param_set {
            self.pending_param_sets.push(nal);
            return;
        }
        if kind.is_vcl {
            self.pending_has_vcl = true;
            self.pending_key |= kind.is_irap;
        }
        self.pending.push(nal);
    }

    fn flush(&mut self, out: &mut std::collections::VecDeque<AccessUnit>) {
        if self.pending.is_empty() {
            // Parameter sets without slices (stream just started): keep them for
            // the AU that follows.
            return;
        }
        out.push_back(AccessUnit {
            nals: std::mem::take(&mut self.pending),
            param_sets: std::mem::take(&mut self.pending_param_sets),
            keyframe: self.pending_key,
            timing: None,
        });
        self.pending_has_vcl = false;
        self.pending_key = false;
    }
}

struct NalKind {
    is_vcl: bool,
    is_irap: bool,
    first_slice: bool,
    is_aud: bool,
    is_param_set: bool,
    is_prefix_sei: bool,
}

fn classify(codec: Codec, nal: &[u8]) -> NalKind {
    match codec {
        Codec::Hevc => {
            let t = (nal[0] >> 1) & 0x3f;
            NalKind {
                is_vcl: t < 32,
                is_irap: (16..=21).contains(&t),
                // first_slice_segment_in_pic_flag is the first bit after the 2-byte header
                first_slice: t < 32 && nal.len() > 2 && nal[2] & 0x80 != 0,
                is_aud: t == 35,
                is_param_set: (32..=34).contains(&t),
                is_prefix_sei: t == 39,
            }
        }
        Codec::H264 => {
            let t = nal[0] & 0x1f;
            NalKind {
                is_vcl: t == 1 || t == 5,
                is_irap: t == 5,
                // first_mb_in_slice is ue(v); value 0 is coded as a single '1' bit
                first_slice: (t == 1 || t == 5) && nal.len() > 1 && nal[1] & 0x80 != 0,
                is_aud: t == 9,
                is_param_set: t == 7 || t == 8,
                is_prefix_sei: t == 6,
            }
        }
    }
}

/// Find the next `00 00 01` start code at or after `from`. Returns
/// (start of the start code including any leading zero bytes, first byte of the NAL).
fn find_start_code(buf: &[u8], from: usize) -> Option<(usize, usize)> {
    if buf.len() < 3 {
        return None;
    }
    let mut i = from;
    while i + 2 < buf.len() {
        if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
            let mut start = i;
            // NAL payloads never end in 0x00, so leading zeros belong to the start code.
            while start > from && buf[start - 1] == 0 {
                start -= 1;
            }
            return Some((start, i + 3));
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn au(bytes: &[&[u8]]) -> Vec<u8> {
        let mut v = Vec::new();
        for b in bytes {
            v.extend_from_slice(&[0, 0, 0, 1]);
            v.extend_from_slice(b);
        }
        v
    }

    #[test]
    fn splits_hevc_stream_into_access_units() {
        // AUD, VPS, SPS, PPS, SEI, IDR | AUD, SEI, TRAIL_R | AUD, TRAIL_R
        let aud = [0x46, 0x01, 0x50];
        let vps = [0x40, 0x01, 0x0c];
        let sps = [0x42, 0x01, 0x01];
        let pps = [0x44, 0x01, 0xc1];
        let sei = [0x4e, 0x01, 0x05];
        let idr = [0x26, 0x01, 0xaf, 0x10];
        let p = [0x02, 0x01, 0xd0, 0x22];
        let stream = [
            au(&[&aud, &vps, &sps, &pps, &sei, &idr]),
            au(&[&aud, &sei, &p]),
            au(&[&aud, &p]),
        ]
        .concat();

        let mut parser = AnnexBParser::new(Codec::Hevc);
        let mut out = std::collections::VecDeque::new();
        // Feed in awkward chunk sizes to exercise the boundary handling.
        for chunk in stream.chunks(5) {
            parser.push(chunk, &mut out);
        }
        parser.finish(&mut out);

        assert_eq!(out.len(), 3);
        let first = &out[0];
        assert!(first.keyframe);
        assert_eq!(
            first.param_sets,
            vec![vps.to_vec(), sps.to_vec(), pps.to_vec()]
        );
        assert_eq!(first.nals, vec![sei.to_vec(), idr.to_vec()]);
        assert!(!out[1].keyframe);
        assert_eq!(out[1].nals, vec![sei.to_vec(), p.to_vec()]);
        assert!(out[2].param_sets.is_empty());
        assert_eq!(out[2].nals, vec![p.to_vec()]);
    }

    #[test]
    fn splits_without_aud_using_first_slice_flag() {
        let sps = [0x42, 0x01, 0x01];
        let pps = [0x44, 0x01, 0xc1];
        let idr = [0x26, 0x01, 0xaf];
        let p1 = [0x02, 0x01, 0xd0];
        let stream = au(&[&sps, &pps, &idr, &p1, &p1]);
        let mut parser = AnnexBParser::new(Codec::Hevc);
        let mut out = std::collections::VecDeque::new();
        parser.push(&stream, &mut out);
        parser.finish(&mut out);
        assert_eq!(out.len(), 3);
        assert!(out[0].keyframe && out[0].param_sets.len() == 2);
    }

    fn cfg(codec: Codec, capture: u32, encode: u32) -> EncoderConfig {
        EncoderConfig {
            capture_adapter_idx: capture,
            capture_luid: Luid {
                low: 0x1000 + capture,
                high: 0,
            },
            encode_luid: Luid {
                low: 0x1000 + encode,
                high: 0,
            },
            output_idx: 1,
            width: 3024,
            height: 1964,
            fps: 120,
            bitrate_mbps: 120,
            codec,
            gop: 240,
            quality: Quality::Balanced,
            full_color: false,
            ten_bit: false,
            intra_refresh: false,
        }
    }

    #[test]
    fn capture_must_match_the_sessions_adapter_and_size() {
        let session = cfg(Codec::Hevc, 0, 0);
        check_capture(&session, session.encode_luid, 3024, 1964).unwrap();

        let other = Luid {
            low: 0x7777,
            high: 0,
        };
        let moved = check_capture(&session, other, 3024, 1964).unwrap_err();
        assert!(is_capture_mismatch(&moved), "{moved:#}");
        assert!(format!("{moved:#}").contains("7777"), "{moved:#}");

        let resized = check_capture(&session, session.encode_luid, 1920, 1080).unwrap_err();
        assert!(is_capture_mismatch(&resized));
        let text = format!("{resized:#}");
        assert!(
            text.contains("1920x1080") && text.contains("3024x1964"),
            "{text}"
        );

        assert!(!is_capture_mismatch(&anyhow::anyhow!(
            "NvEncInitializeEncoder failed"
        )));
    }

    #[test]
    fn start_failures_are_classified() {
        use windows::Win32::Foundation::{E_ACCESSDENIED, E_FAIL};
        use windows::Win32::Graphics::Dxgi::{DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_DEVICE_REMOVED};
        let windows = |code| anyhow::Error::new(windows::core::Error::from(code));
        assert_eq!(
            classify_start_failure(&windows(E_ACCESSDENIED).context(DesktopNotCapturable)),
            StartFailure::DesktopRefused
        );
        assert_eq!(
            classify_start_failure(&anyhow::Error::new(CaptureMismatch).context("size")),
            StartFailure::Mismatch
        );
        assert_eq!(
            classify_start_failure(&windows(E_FAIL).context(OutputBusy)),
            StartFailure::OutputBusy
        );
        for code in [DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_DEVICE_REMOVED] {
            assert_eq!(
                classify_start_failure(&windows(code).context("IDXGIOutputDuplication")),
                StartFailure::Capture
            );
        }
        assert_eq!(
            classify_start_failure(&anyhow::anyhow!(
                "NvEncInitializeEncoder failed with NV_ENC_ERR_OUT_OF_MEMORY"
            )),
            StartFailure::Encoder
        );
        assert_eq!(StartFailure::Encoder.label(), "encoder");
        assert_eq!(StartFailure::Capture.label(), "capture");
    }

    #[test]
    fn waiting_for_retirements_returns_once_none_are_in_flight() {
        let retirements = std::sync::Arc::new(Retirements::new());
        assert!(retirements.wait_idle(Duration::ZERO));
        retirements.begin();
        let started = std::time::Instant::now();
        assert!(!retirements.wait_idle(Duration::from_millis(30)));
        assert!(started.elapsed() >= Duration::from_millis(30));

        let ending = std::sync::Arc::clone(&retirements);
        let janitor = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            ending.end();
        });
        assert!(retirements.wait_idle(Duration::from_secs(5)));
        janitor.join().unwrap();
    }

    fn busy() -> anyhow::Error {
        anyhow::anyhow!("IDXGIOutput1::DuplicateOutput: The parameter is incorrect.")
            .context(OutputBusy)
    }

    #[test]
    fn a_busy_output_is_retried_until_it_frees() {
        let mut attempts = 0;
        let result = retry_output_busy(Duration::from_secs(5), Duration::from_millis(1), || {
            attempts += 1;
            if attempts < 3 {
                Err(busy())
            } else {
                Ok(attempts)
            }
        });
        assert_eq!(result.unwrap(), 3);
    }

    #[test]
    fn a_busy_output_gives_up_at_the_budget() {
        let started = std::time::Instant::now();
        let mut attempts = 0;
        let result: Result<()> =
            retry_output_busy(Duration::from_millis(50), Duration::from_millis(10), || {
                attempts += 1;
                Err(busy())
            });
        assert!(is_output_busy(&result.unwrap_err()));
        assert!(attempts >= 2, "{attempts}");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn other_start_errors_are_not_retried() {
        let mut attempts = 0;
        let result: Result<()> =
            retry_output_busy(Duration::from_secs(5), Duration::from_millis(1), || {
                attempts += 1;
                Err(anyhow::anyhow!("NvEncInitializeEncoder failed"))
            });
        assert!(result.is_err());
        assert_eq!(attempts, 1);
        // Found through further context layers too.
        assert!(is_output_busy(&busy().context("restarting capture")));
    }

    #[test]
    fn a_refused_desktop_is_recognised_through_its_context() {
        // How Encoder::spawn marks it: the marker is a context layer, not
        // the root error, so it is not a chain item of its own type.
        let refused = anyhow::anyhow!("IDXGIOutput1::DuplicateOutput: Access is denied.")
            .context(DesktopNotCapturable);
        assert!(is_desktop_not_capturable(&refused));
        assert!(is_desktop_not_capturable(
            &refused.context("restarting capture")
        ));
        assert!(!is_desktop_not_capturable(&anyhow::anyhow!(
            "NvEncInitializeEncoder failed"
        )));
    }

    #[test]
    fn cross_adapter_compares_luids_not_indices() {
        // The IDD proxy can shift DXGI indices; the LUID is the identity.
        let mut session = cfg(Codec::Hevc, 0, 0);
        session.capture_adapter_idx = 1;
        assert!(!session.cross_adapter());
        session.capture_luid = Luid {
            low: 0x7777,
            high: 0,
        };
        assert!(session.cross_adapter());
    }

    #[test]
    fn quality_wire_values_round_trip() {
        for quality in [Quality::Speed, Quality::Balanced, Quality::Quality] {
            assert_eq!(Quality::from_wire(quality.wire()), Some(quality));
        }
        assert_eq!(Quality::Speed.wire(), 1);
        assert_eq!(Quality::Balanced.wire(), 2);
        assert_eq!(Quality::Quality.wire(), 3);
        assert_eq!(Quality::from_wire(0), None);
        assert_eq!(Quality::from_wire(4), None);
    }

    #[test]
    fn enc_txt_lists_only_what_is_supported() {
        let presets_only = VideoCaps {
            quality: true,
            hevc: true,
            full_color: false,
            ten_bit: false,
        };
        assert_eq!(presets_only.txt_value(), "q");
        let all = VideoCaps {
            quality: true,
            hevc: true,
            full_color: true,
            ten_bit: true,
        };
        assert_eq!(all.txt_value(), "q,444,10");
        let none = VideoCaps {
            quality: false,
            hevc: true,
            full_color: false,
            ten_bit: false,
        };
        assert_eq!(none.txt_value(), "");
    }
}

/// Marker in an error chain: Desktop Duplication refused the current desktop
/// (`E_ACCESSDENIED`). Not a fault of the pipeline — retry when the desktop
/// changes (unlock, sign-in, UAC prompt dismissed).
#[derive(Debug)]
pub struct DesktopNotCapturable;

impl std::fmt::Display for DesktopNotCapturable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the desktop cannot be captured from this process right now")
    }
}

impl std::error::Error for DesktopNotCapturable {}

/// Whether `error` says the desktop is not capturable. The marker is attached
/// with `.context()`, so it is not a chain item of its own type; anyhow's own
/// downcast looks through context layers.
pub fn is_desktop_not_capturable(error: &anyhow::Error) -> bool {
    error.downcast_ref::<DesktopNotCapturable>().is_some()
}

pub(crate) fn is_access_denied(error: &anyhow::Error) -> bool {
    use windows::Win32::Foundation::E_ACCESSDENIED;
    error.chain().any(|e| {
        e.downcast_ref::<windows::core::Error>()
            .is_some_and(|w| w.code() == E_ACCESSDENIED)
    })
}
