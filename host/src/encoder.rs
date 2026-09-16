//! Capture and hardware encode behind one `AccessUnit` interface. NVIDIA on a
//! single adapter uses the in-process D3D11/NVENC path; the ffmpeg path remains
//! for AMD, Intel, software, cross-adapter systems, and as a startup fallback.

use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::thread;

use anyhow::{Context, Result};
use clap::ValueEnum;

use crate::gpu::Vendor;
use crate::protocol::Codec;

/// Speed/quality trade-off, mapped to each vendor's own preset scale.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Quality {
    Speed,
    Balanced,
    Quality,
}

#[derive(Debug, Clone)]
pub struct EncoderConfig {
    pub ffmpeg: PathBuf,
    /// Vendor of the GPU that encodes (the selected GPU).
    pub vendor: Vendor,
    /// DXGI adapter that owns the captured output.
    pub capture_adapter_idx: u32,
    /// DXGI adapter of the selected (encoding) GPU. If it differs from
    /// `capture_adapter_idx` frames are copied through system memory.
    pub encode_adapter_idx: u32,
    pub output_idx: u32,
    pub fps: u32,
    pub bitrate_mbps: u32,
    pub codec: Codec,
    /// Keyframe interval in frames.
    pub gop: u32,
    pub quality: Quality,
    pub intra_refresh: bool,
    /// Skip the in-process NVIDIA path and always use the ffmpeg child. A
    /// diagnostic/escape hatch: the native path shares one D3D11 device for
    /// capture and encode, which can wedge harder during a fullscreen-exclusive
    /// game's modeset on the virtual display.
    pub prefer_ffmpeg: bool,
}

impl EncoderConfig {
    pub fn cross_adapter(&self) -> bool {
        self.capture_adapter_idx != self.encode_adapter_idx
    }
}

/// One coded picture, ready for the wire.
#[derive(Debug, Default)]
pub struct AccessUnit {
    /// Slice / SEI NAL units, without start codes. AUDs and parameter sets removed.
    pub nals: Vec<Vec<u8>>,
    /// Parameter sets (VPS/SPS/PPS or SPS/PPS) that preceded this AU, if any.
    pub param_sets: Vec<Vec<u8>>,
    pub keyframe: bool,
}

/// ffmpeg encoder name for a vendor/codec pair.
pub fn encoder_name(vendor: Vendor, codec: Codec, prefer_ffmpeg: bool) -> &'static str {
    if vendor == Vendor::Nvidia && !prefer_ffmpeg {
        return "NVENC (in process)";
    }
    ffmpeg_encoder_name(vendor, codec)
}

fn ffmpeg_encoder_name(vendor: Vendor, codec: Codec) -> &'static str {
    match (vendor, codec) {
        (Vendor::Nvidia, Codec::Hevc) => "hevc_nvenc",
        (Vendor::Nvidia, Codec::H264) => "h264_nvenc",
        (Vendor::Amd, Codec::Hevc) => "hevc_amf",
        (Vendor::Amd, Codec::H264) => "h264_amf",
        (Vendor::Intel, Codec::Hevc) => "hevc_qsv",
        (Vendor::Intel, Codec::H264) => "h264_qsv",
        (Vendor::Other, Codec::Hevc) => "libx265",
        (Vendor::Other, Codec::H264) => "libx264",
    }
}

/// Build the full ffmpeg command line for a configuration.
pub fn build_command(cfg: &EncoderConfig) -> Command {
    let hevc = cfg.codec == Codec::Hevc;
    let encoder = ffmpeg_encoder_name(cfg.vendor, cfg.codec);
    let bitrate = format!("{}M", cfg.bitrate_mbps);
    // One frame's worth of VBV: the ultra-low-latency CBR setup. Keeps every
    // frame (including IDRs) close to bitrate/fps bytes so nothing bunches up
    // on the wire.
    let bufsize = format!("{}k", (cfg.bitrate_mbps * 1000) / cfg.fps.max(1));
    let gop = cfg.gop.to_string();
    let software = cfg.vendor == Vendor::Other;
    let cross = cfg.cross_adapter();

    // --- capture graph -----------------------------------------------------
    let mut graph = format!(
        // Keep Windows' cursor in the captured display. This lets the same
        // streamed pointer reflect input from either the Mac or a mouse
        // connected directly to the PC.
        "ddagrab=output_idx={}:framerate={}:draw_mouse=1",
        cfg.output_idx, cfg.fps
    );
    if software || cross {
        // Frames leave the capture GPU through system memory. NVENC/AMF/QSV-HEVC
        // take BGRA directly; x264/x265 and h264_qsv want planar/NV12.
        graph.push_str(",hwdownload,format=bgra");
        if software {
            graph.push_str(",format=yuv420p");
        } else if cfg.vendor == Vendor::Intel && !hevc {
            graph.push_str(",format=nv12");
        }
    } else if cfg.vendor == Vendor::Intel {
        // Map the D3D11 texture into the QSV session on the same adapter.
        graph.push_str(if hevc {
            ",hwmap=derive_device=qsv,format=qsv"
        } else {
            ",hwmap=derive_device=qsv,vpp_qsv=format=nv12"
        });
    }

    let mut cmd = Command::new(&cfg.ffmpeg);
    cmd.args(["-hide_banner", "-loglevel", "warning", "-nostdin", "-nostats"])
        .args(["-init_hw_device", &format!("d3d11va=hw:{}", cfg.capture_adapter_idx)]);
    if cfg.vendor == Vendor::Intel && !cross {
        cmd.args(["-init_hw_device", "qsv=qs@hw"]);
    }
    cmd.args(["-filter_hw_device", "hw"])
        .args(["-filter_complex", &graph])
        .args(["-c:v", encoder]);

    // --- rate control shared by every encoder ------------------------------
    cmd.args(["-b:v", &bitrate, "-maxrate", &bitrate, "-bufsize", &bufsize, "-g", &gop]);

    // --- vendor specifics ----------------------------------------------------
    match cfg.vendor {
        Vendor::Nvidia => {
            let preset = match cfg.quality {
                Quality::Speed => "p1",
                Quality::Balanced => "p4",
                Quality::Quality => "p6",
            };
            cmd.args(["-preset", preset, "-tune", "ull", "-zerolatency", "1", "-delay", "0"])
                .args(["-bf", "0", "-rc", "cbr", "-forced-idr", "1", "-aud", "1"])
                .args(["-profile:v", if hevc { "main" } else { "high" }]);
            if cfg.intra_refresh {
                cmd.args(["-intra-refresh", "1"]);
            }
        }
        Vendor::Amd => {
            let quality = match cfg.quality {
                Quality::Speed => "speed",
                Quality::Balanced => "balanced",
                Quality::Quality => "quality",
            };
            cmd.args(["-usage", "ultralowlatency", "-quality", quality, "-latency", "1"])
                .args(["-async_depth", "1", "-rc", "cbr", "-forced_idr", "1", "-aud", "1"])
                .args(["-preanalysis", "0"])
                .args(["-profile:v", if hevc { "main" } else { "high" }]);
            if hevc {
                cmd.args(["-header_insertion_mode", "idr"]);
            } else {
                cmd.args(["-bf", "0"]);
            }
        }
        Vendor::Intel => {
            let preset = match cfg.quality {
                Quality::Speed => "veryfast",
                Quality::Balanced => "medium",
                Quality::Quality => "slower",
            };
            cmd.args(["-preset", preset, "-async_depth", "1", "-low_delay_brc", "1"])
                .args(["-scenario", "remotegaming", "-bf", "0", "-forced_idr", "1", "-aud", "1"])
                .args(["-profile:v", if hevc { "main" } else { "high" }]);
            if !hevc {
                cmd.args(["-look_ahead", "0", "-repeat_pps", "1"]);
            }
        }
        Vendor::Other => {
            let preset = match cfg.quality {
                Quality::Speed => "ultrafast",
                Quality::Balanced => "superfast",
                Quality::Quality => "veryfast",
            };
            cmd.args(["-preset", preset, "-tune", "zerolatency"]);
            if hevc {
                cmd.args([
                    "-x265-params",
                    &format!("aud=1:repeat-headers=1:bframes=0:keyint={gop}:min-keyint={gop}"),
                ]);
            } else {
                cmd.args(["-x264opts", "aud=1", "-bf", "0"]);
            }
        }
    }

    // ddagrab already paces frames. Do not duplicate them again at the output,
    // and deliver each encoded packet immediately, even on a static desktop.
    cmd.args(["-fps_mode", "passthrough", "-enc_time_base", "1:1000000", "-flush_packets", "1"])
        .args(["-f", if hevc { "hevc" } else { "h264" }, "pipe:1"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    cmd
}

struct FfmpegEncoder {
    child: Child,
    stdout: ChildStdout,
    parser: AnnexBParser,
    read_buf: Vec<u8>,
    ready: std::collections::VecDeque<AccessUnit>,
}

impl FfmpegEncoder {
    fn spawn(cfg: &EncoderConfig) -> Result<FfmpegEncoder> {
        if cfg.vendor == Vendor::Other {
            log::warn!(
                "no NVIDIA/AMD/Intel encoder on the selected GPU: falling back to software {} \
                 (expect high CPU use and low frame rates at large sizes)",
                ffmpeg_encoder_name(cfg.vendor, cfg.codec)
            );
        }
        if cfg.cross_adapter() {
            log::warn!(
                "display is rendered on DXGI adapter {} but the encoder is on adapter {}: \
                 frames will be copied through system memory",
                cfg.capture_adapter_idx, cfg.encode_adapter_idx
            );
        }
        let mut cmd = build_command(cfg);
        log::info!("starting encoder: {:?}", cmd);
        let mut child = cmd.spawn().with_context(|| {
            format!("failed to start ffmpeg at {}", cfg.ffmpeg.display())
        })?;
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        thread::Builder::new()
            .name("ffmpeg-stderr".into())
            .spawn(move || {
                for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                    log::warn!("ffmpeg: {line}");
                }
            })
            .expect("spawn ffmpeg stderr thread");

        Ok(FfmpegEncoder {
            child,
            stdout,
            parser: AnnexBParser::new(cfg.codec),
            read_buf: vec![0u8; 256 * 1024],
            ready: Default::default(),
        })
    }

    /// Block until the next complete access unit is available. `None` means the
    /// encoder exited (stdout closed).
    fn next_access_unit(&mut self) -> Result<Option<AccessUnit>> {
        loop {
            if let Some(au) = self.ready.pop_front() {
                return Ok(Some(au));
            }
            let n = self.stdout.read(&mut self.read_buf).context("reading ffmpeg stdout")?;
            if n == 0 {
                // Flush whatever the parser still holds (the final AU has no successor).
                self.parser.finish(&mut self.ready);
                return Ok(self.ready.pop_front());
            }
            self.parser.push(&self.read_buf[..n], &mut self.ready);
        }
    }
}

impl Drop for FfmpegEncoder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

enum EncoderInner {
    Native(Box<crate::native_nvenc::NativeNvenc>),
    Ffmpeg(FfmpegEncoder),
}

pub struct Encoder {
    // `None` is the short recovery state between dropping a failed Desktop
    // Duplication session and creating its replacement.
    inner: Option<EncoderInner>,
    fallback: Option<EncoderConfig>,
}

impl Encoder {
    /// NVENC and the display driver can stop returning from teardown calls
    /// during a fullscreen GPU reset. Never let that block the session thread:
    /// a detached cleanup thread owns every native handle until teardown does
    /// finish, while the session can restore the user's physical displays.
    fn retire(inner: EncoderInner) {
        match inner {
            EncoderInner::Native(native) => {
                // Pass the allocation as an address so a failure to create the
                // janitor thread leaks it instead of synchronously dropping it
                // on this display-restoration path. Once started, the janitor
                // is the sole owner and reconstructs the Box exactly once.
                let native_address = Box::into_raw(native) as usize;
                if let Err(error) = std::thread::Builder::new()
                    .name("nvenc-retire".into())
                    .spawn(move || unsafe {
                        drop(Box::from_raw(
                            native_address as *mut crate::native_nvenc::NativeNvenc,
                        ));
                    })
                {
                    log::warn!("could not start NVENC cleanup thread: {error}");
                }
            }
            EncoderInner::Ffmpeg(ffmpeg) => drop(ffmpeg),
        }
    }

    pub fn spawn(cfg: &EncoderConfig) -> Result<Self> {
        if cfg.vendor == Vendor::Nvidia && !cfg.cross_adapter() && !cfg.prefer_ffmpeg {
            match crate::native_nvenc::NativeNvenc::spawn(cfg) {
                Ok(native) => {
                    return Ok(Self {
                        inner: Some(EncoderInner::Native(Box::new(native))),
                        fallback: Some(cfg.clone()),
                    });
                }
                Err(e) => {
                    log::warn!(
                        "native NVENC startup failed ({e:#}); falling back to ffmpeg {}",
                        ffmpeg_encoder_name(cfg.vendor, cfg.codec)
                    );
                }
            }
        }
        Ok(Self {
            inner: Some(EncoderInner::Ffmpeg(FfmpegEncoder::spawn(cfg)?)),
            fallback: None,
        })
    }

    pub fn next_access_unit(&mut self) -> Result<Option<AccessUnit>> {
        let Some(inner) = &mut self.inner else {
            return Ok(None);
        };
        let native_error = match inner {
            EncoderInner::Native(native) => match native.next_access_unit() {
                Ok(au) => return Ok(au),
                Err(error) => error,
            },
            EncoderInner::Ffmpeg(ffmpeg) => return ffmpeg.next_access_unit(),
        };

        let cfg = self
            .fallback
            .take()
            .expect("native encoder always has an ffmpeg fallback configuration");
        log::warn!(
            "native NVENC capture failed ({native_error:#}); switching this capture attempt to ffmpeg {}",
            ffmpeg_encoder_name(cfg.vendor, cfg.codec)
        );
        if let Some(inner) = self.inner.take() {
            Self::retire(inner);
        }
        self.inner = Some(EncoderInner::Ffmpeg(FfmpegEncoder::spawn(&cfg)?));
        match self.inner.as_mut().expect("ffmpeg was just installed") {
            EncoderInner::Ffmpeg(ffmpeg) => ffmpeg.next_access_unit(),
            EncoderInner::Native(_) => unreachable!(),
        }
    }

    /// Drop the failed capture backend before constructing its replacement.
    /// Desktop Duplication recovery is unreliable if the old duplication
    /// object is still alive while `DuplicateOutput` creates the next one.
    pub fn restart(&mut self, cfg: &EncoderConfig) -> Result<()> {
        if let Some(inner) = self.inner.take() {
            Self::retire(inner);
        }
        match Self::spawn(cfg) {
            Ok(replacement) => {
                *self = replacement;
                Ok(())
            }
            Err(error) => Err(error),
        }
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            Self::retire(inner);
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
        assert_eq!(first.param_sets, vec![vps.to_vec(), sps.to_vec(), pps.to_vec()]);
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

    fn cfg(vendor: Vendor, codec: Codec, capture: u32, encode: u32) -> EncoderConfig {
        EncoderConfig {
            ffmpeg: PathBuf::from("ffmpeg"),
            vendor,
            capture_adapter_idx: capture,
            encode_adapter_idx: encode,
            output_idx: 1,
            fps: 120,
            bitrate_mbps: 120,
            codec,
            gop: 240,
            quality: Quality::Balanced,
            intra_refresh: false,
            prefer_ffmpeg: false,
        }
    }

    fn argv(cmd: &Command) -> Vec<String> {
        cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect()
    }

    #[test]
    fn nvidia_zero_copy_command() {
        let args = argv(&build_command(&cfg(Vendor::Nvidia, Codec::Hevc, 0, 0)));
        assert!(args.contains(&"hevc_nvenc".to_string()));
        assert!(args.contains(&"d3d11va=hw:0".to_string()));
        let graph = &args[args.iter().position(|a| a == "-filter_complex").unwrap() + 1];
        assert!(!graph.contains("hwdownload"), "same adapter must stay on the GPU");
        assert!(graph.contains("draw_mouse=1"), "Windows' cursor must be captured");
        assert!(args.contains(&"p4".to_string()));
        for (option, value) in [
            ("-fps_mode", "passthrough"),
            ("-enc_time_base", "1:1000000"),
            ("-flush_packets", "1"),
        ] {
            assert!(args.windows(2).any(|pair| pair[0] == option && pair[1] == value));
        }
    }

    #[test]
    fn amd_and_intel_use_their_encoders() {
        let amd = argv(&build_command(&cfg(Vendor::Amd, Codec::Hevc, 1, 1)));
        assert!(amd.contains(&"hevc_amf".to_string()));
        assert!(amd.contains(&"ultralowlatency".to_string()));
        assert!(amd.contains(&"-header_insertion_mode".to_string()));
        assert!(!amd.contains(&"-bf".to_string()), "hevc_amf has no B-frame option");

        let intel = argv(&build_command(&cfg(Vendor::Intel, Codec::H264, 0, 0)));
        assert!(intel.contains(&"h264_qsv".to_string()));
        assert!(intel.contains(&"qsv=qs@hw".to_string()));
        let graph = &intel[intel.iter().position(|a| a == "-filter_complex").unwrap() + 1];
        assert!(graph.contains("hwmap=derive_device=qsv,vpp_qsv=format=nv12"));
        assert!(intel.contains(&"-repeat_pps".to_string()));
    }

    #[test]
    fn cross_adapter_downloads_frames() {
        let args = argv(&build_command(&cfg(Vendor::Nvidia, Codec::Hevc, 1, 0)));
        let graph = &args[args.iter().position(|a| a == "-filter_complex").unwrap() + 1];
        assert!(graph.ends_with("hwdownload,format=bgra"));
        assert!(args.contains(&"d3d11va=hw:1".to_string()), "capture device is the display's adapter");
    }

    #[test]
    fn software_fallback_converts_to_planar() {
        let args = argv(&build_command(&cfg(Vendor::Other, Codec::H264, 0, 0)));
        assert!(args.contains(&"libx264".to_string()));
        let graph = &args[args.iter().position(|a| a == "-filter_complex").unwrap() + 1];
        assert!(graph.contains("hwdownload,format=bgra,format=yuv420p"));
    }
}
