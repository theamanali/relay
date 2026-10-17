//! What the selected GPU's NVENC can do, as plain data. `query` fills it on
//! the hardware (a short encode session on a D3D11 device for the adapter,
//! no Desktop Duplication, no display change); everything here checks it
//! without the hardware, so sessions can be refused before the displays are
//! touched.
//!
//! These are capabilities, not measured rates: a mode that passes may still
//! not sustain its frame rate on a given GPU. The stream's own stats show
//! what it sustains.

use anyhow::Result;

use crate::encoder::{Quality, VideoCaps};
use crate::gpu::Luid;
pub use crate::native_nvenc::{query_caps as query, trial_initialize};
pub use crate::nvenc_bindings::ApiVersion;
use crate::protocol::Codec;

/// The profiles Relay's sessions encode with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Profile {
    HevcMain,
    HevcMain10,
    /// Range extensions: 4:4:4 at 8 or 10 bits.
    HevcRext,
    H264High,
}

impl Profile {
    /// Rext carries 4:4:4 at either depth; Main10 is 10-bit 4:2:0. H.264
    /// sessions never take the flags.
    pub fn for_session(codec: Codec, full_color: bool, ten_bit: bool) -> Self {
        match codec {
            Codec::Hevc if full_color => Profile::HevcRext,
            Codec::Hevc if ten_bit => Profile::HevcMain10,
            Codec::Hevc => Profile::HevcMain,
            Codec::H264 => Profile::H264High,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Profile::HevcMain => "HEVC Main",
            Profile::HevcMain10 => "HEVC Main10",
            Profile::HevcRext => "HEVC Rext",
            Profile::H264High => "H.264 High",
        }
    }
}

pub fn codec_label(codec: Codec) -> &'static str {
    match codec {
        Codec::Hevc => "HEVC",
        Codec::H264 => "H.264",
    }
}

/// One codec's NVENC support on the selected GPU.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodecCaps {
    pub codec: Codec,
    /// Everything the driver lists, by name, for diagnostics.
    pub listed_profiles: Vec<String>,
    pub listed_presets: Vec<String>,
    pub listed_input_formats: Vec<String>,
    /// Relay's profiles among the listed ones.
    pub profiles: Vec<Profile>,
    /// `NV_ENC_BUFFER_FORMAT_ARGB`: what Desktop Duplication's BGRA texture
    /// is registered as.
    pub argb_input: bool,
    /// P1/P4/P6 that are listed and whose ultra-low-latency configuration the
    /// driver returns.
    pub ull_presets: Vec<Quality>,
    pub async_encode: bool,
    pub cbr: bool,
    /// Relay's VBV is one frame long.
    pub custom_vbv: bool,
    pub intra_refresh: bool,
    pub yuv444: bool,
    pub ten_bit: bool,
    pub min_width: u32,
    pub min_height: u32,
    pub max_width: u32,
    pub max_height: u32,
    /// The encoder's rated 16×16 macroblocks per second; 0 when not reported.
    pub mb_per_sec_max: u32,
}

/// What one session needs from its codec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Requirement {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub quality: Quality,
    pub full_color: bool,
    pub ten_bit: bool,
    pub intra_refresh: bool,
}

impl CodecCaps {
    /// What keeps this codec from running any Relay session.
    pub fn base_problems(&self, intra_refresh: bool) -> Vec<String> {
        let base = Profile::for_session(self.codec, false, false);
        [
            (!self.profiles.contains(&base)).then(|| format!("no {} profile", base.label())),
            (!self.argb_input).then(|| "no ARGB input format".to_string()),
            (!self.async_encode).then(|| "no asynchronous encoding".to_string()),
            (!self.cbr).then(|| "no CBR rate control".to_string()),
            (!self.custom_vbv).then(|| "no custom VBV buffer size".to_string()),
            (intra_refresh && !self.intra_refresh).then(|| "no intra refresh".to_string()),
        ]
        .into_iter()
        .flatten()
        .collect()
    }

    pub fn usable(&self, intra_refresh: bool) -> bool {
        self.base_problems(intra_refresh).is_empty()
    }

    /// Everything one session needs: the base, the profile its flags select,
    /// its preset's ultra-low-latency configuration and its size.
    pub fn check(&self, requirement: &Requirement) -> Result<()> {
        let r = requirement;
        let mut problems = self.base_problems(r.intra_refresh);
        let hevc = self.codec == Codec::Hevc;
        // The base profile is already among the base problems.
        let profile = Profile::for_session(self.codec, r.full_color, r.ten_bit);
        if profile != Profile::for_session(self.codec, false, false)
            && !self.profiles.contains(&profile)
        {
            problems.push(format!("no {} profile", profile.label()));
        }
        if hevc && r.full_color && !self.yuv444 {
            problems.push("no 4:4:4 encoding".into());
        }
        if hevc && r.ten_bit && !self.ten_bit {
            problems.push("no 10-bit encoding".into());
        }
        if !self.ull_presets.contains(&r.quality) {
            problems.push(format!(
                "no ultra-low-latency {} ({}) configuration",
                r.quality.preset_name(),
                r.quality.label()
            ));
        }
        let fits = (self.min_width..=self.max_width).contains(&r.width)
            && (self.min_height..=self.max_height).contains(&r.height);
        if !fits {
            problems.push(format!(
                "{}x{} is outside {}x{} to {}x{}",
                r.width, r.height, self.min_width, self.min_height, self.max_width, self.max_height
            ));
        }
        if r.fps == 0 {
            problems.push("a frame rate of 0".into());
        }
        if problems.is_empty() {
            return Ok(());
        }
        anyhow::bail!(
            "{} cannot encode {}x{}@{}: {}",
            codec_label(self.codec),
            r.width,
            r.height,
            r.fps,
            problems.join("; ")
        )
    }

    /// NVIDIA's rated macroblock rate as frames per second at this size;
    /// `None` when not reported. A rating, not a limit or a measurement: an
    /// RTX 3080 Ti rated near 4K30 measured 102–118 fps at 3024×1964.
    pub fn rated_fps(&self, width: u32, height: u32) -> Option<f64> {
        let per_frame = u64::from(width.div_ceil(16)) * u64::from(height.div_ceil(16));
        if self.mb_per_sec_max == 0 || per_frame == 0 {
            return None;
        }
        Some(f64::from(self.mb_per_sec_max) / per_frame as f64)
    }
}

/// The selected adapter's encoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncoderCaps {
    pub adapter: String,
    pub luid: Luid,
    pub driver_api: ApiVersion,
    pub codecs: Vec<CodecCaps>,
}

impl EncoderCaps {
    pub fn codec(&self, codec: Codec) -> Option<&CodecCaps> {
        self.codecs.iter().find(|c| c.codec == codec)
    }

    /// CLIENT_HELLO-style mask of the codecs a session could use.
    pub fn codec_mask(&self, intra_refresh: bool) -> u8 {
        self.codecs
            .iter()
            .filter(|c| c.usable(intra_refresh))
            .fold(0, |mask, c| mask | c.codec.bit())
    }

    /// The picture options a session may apply (TXT `enc`).
    pub fn video_caps(&self, intra_refresh: bool) -> VideoCaps {
        let hevc = self.codec(Codec::Hevc).filter(|c| c.usable(intra_refresh));
        VideoCaps {
            quality: self.codec_mask(intra_refresh) != 0,
            hevc: hevc.is_some(),
            full_color: hevc.is_some_and(|c| c.yuv444 && c.profiles.contains(&Profile::HevcRext)),
            ten_bit: hevc.is_some_and(|c| c.ten_bit && c.profiles.contains(&Profile::HevcMain10)),
        }
    }

    /// Several lines for `relay-host encoder-caps` and the startup log.
    pub fn describe(&self, intra_refresh: bool) -> String {
        let yes = |b: bool| if b { "yes" } else { "no" };
        let mut s = format!(
            "NVENC on {} (LUID {:x}:{:x}): driver supports NVENC API {} (Relay needs {})\n",
            self.adapter,
            self.luid.high,
            self.luid.low,
            self.driver_api,
            ApiVersion::from_driver(crate::nvenc_bindings::REQUIRED_DRIVER_API)
        );
        if self.codecs.is_empty() {
            s.push_str("no HEVC or H.264 encoder\n");
        }
        for c in &self.codecs {
            let problems = c.base_problems(intra_refresh);
            if problems.is_empty() {
                s.push_str(&format!("{}: usable\n", codec_label(c.codec)));
            } else {
                s.push_str(&format!(
                    "{}: not usable ({})\n",
                    codec_label(c.codec),
                    problems.join(", ")
                ));
            }
            let ull: Vec<&str> = c.ull_presets.iter().map(|q| q.preset_name()).collect();
            s.push_str(&format!(
                "  profiles: {}\n  presets: {} (ultra-low-latency: {})\n  input formats: {}\n",
                c.listed_profiles.join(", "),
                c.listed_presets.join(", "),
                if ull.is_empty() {
                    "none".into()
                } else {
                    ull.join(", ")
                },
                c.listed_input_formats.join(", "),
            ));
            s.push_str(&format!(
                "  async {}, CBR {}, custom VBV {}, intra refresh {}, 4:4:4 {}, 10-bit {}\n",
                yes(c.async_encode),
                yes(c.cbr),
                yes(c.custom_vbv),
                yes(c.intra_refresh),
                yes(c.yuv444),
                yes(c.ten_bit),
            ));
            s.push_str(&format!(
                "  size {}x{} to {}x{}, rated {}\n",
                c.min_width,
                c.min_height,
                c.max_width,
                c.max_height,
                if c.mb_per_sec_max == 0 {
                    "macroblock rate not reported".to_string()
                } else {
                    format!("{} macroblocks/s", c.mb_per_sec_max)
                }
            ));
        }
        s
    }

    /// An error naming every problem unless some codec can run a session.
    pub fn ensure_usable(&self, intra_refresh: bool) -> Result<()> {
        if self.codec_mask(intra_refresh) != 0 {
            return Ok(());
        }
        if self.codecs.is_empty() {
            anyhow::bail!("{}'s NVENC offers neither HEVC nor H.264", self.adapter);
        }
        anyhow::bail!(
            "{}'s NVENC cannot run a Relay session: {}",
            self.adapter,
            self.codecs
                .iter()
                .map(|c| format!(
                    "{}: {}",
                    codec_label(c.codec),
                    c.base_problems(intra_refresh).join(", ")
                ))
                .collect::<Vec<_>>()
                .join("; ")
        )
    }
}

/// An RTX 30-series-like record for tests elsewhere in the crate.
#[cfg(test)]
pub(crate) mod fixture {
    use super::*;

    pub fn hevc() -> CodecCaps {
        CodecCaps {
            codec: Codec::Hevc,
            listed_profiles: vec!["Main".into(), "Main10".into(), "Rext".into()],
            listed_presets: (1..=7).map(|p| format!("P{p}")).collect(),
            listed_input_formats: vec!["NV12".into(), "ARGB".into()],
            profiles: vec![Profile::HevcMain, Profile::HevcMain10, Profile::HevcRext],
            argb_input: true,
            ull_presets: vec![Quality::Speed, Quality::Balanced, Quality::Quality],
            async_encode: true,
            cbr: true,
            custom_vbv: true,
            intra_refresh: true,
            yuv444: true,
            ten_bit: true,
            min_width: 129,
            min_height: 33,
            max_width: 8192,
            max_height: 8192,
            mb_per_sec_max: 0,
        }
    }

    pub fn h264() -> CodecCaps {
        CodecCaps {
            codec: Codec::H264,
            listed_profiles: vec!["Baseline".into(), "Main".into(), "High".into()],
            profiles: vec![Profile::H264High],
            yuv444: false,
            ten_bit: false,
            min_width: 145,
            min_height: 49,
            max_width: 4096,
            max_height: 4096,
            ..hevc()
        }
    }

    pub fn caps(codecs: Vec<CodecCaps>) -> EncoderCaps {
        EncoderCaps {
            adapter: "NVIDIA GeForce RTX 3080 Ti".into(),
            luid: Luid {
                low: 0x122e1,
                high: 0,
            },
            driver_api: ApiVersion {
                major: 13,
                minor: 0,
            },
            codecs,
        }
    }

    pub fn rtx() -> EncoderCaps {
        caps(vec![hevc(), h264()])
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::*;
    use super::*;

    fn session(width: u32, height: u32) -> Requirement {
        Requirement {
            width,
            height,
            fps: 120,
            quality: Quality::Balanced,
            full_color: false,
            ten_bit: false,
            intra_refresh: false,
        }
    }

    fn problem(caps: &CodecCaps, requirement: &Requirement) -> String {
        format!("{:#}", caps.check(requirement).unwrap_err())
    }

    #[test]
    fn profiles_follow_chroma_and_depth() {
        assert_eq!(
            Profile::for_session(Codec::Hevc, false, false),
            Profile::HevcMain
        );
        assert_eq!(
            Profile::for_session(Codec::Hevc, false, true),
            Profile::HevcMain10
        );
        assert_eq!(
            Profile::for_session(Codec::Hevc, true, false),
            Profile::HevcRext
        );
        assert_eq!(
            Profile::for_session(Codec::Hevc, true, true),
            Profile::HevcRext
        );
        assert_eq!(
            Profile::for_session(Codec::H264, true, true),
            Profile::H264High
        );
    }

    #[test]
    fn a_full_rtx_record_passes_relays_session() {
        let caps = rtx();
        caps.ensure_usable(false).unwrap();
        caps.codec(Codec::Hevc)
            .unwrap()
            .check(&session(3024, 1964))
            .unwrap();
        caps.codec(Codec::H264)
            .unwrap()
            .check(&session(1920, 1080))
            .unwrap();
        assert_eq!(
            caps.codec_mask(false),
            Codec::Hevc.bit() | Codec::H264.bit()
        );
    }

    #[test]
    fn each_missing_base_feature_is_named() {
        for (field, expected) in [
            ("argb", "ARGB"),
            ("async", "asynchronous"),
            ("cbr", "CBR"),
            ("vbv", "VBV"),
            ("profile", "Main"),
        ] {
            let mut hevc = hevc();
            match field {
                "argb" => hevc.argb_input = false,
                "async" => hevc.async_encode = false,
                "cbr" => hevc.cbr = false,
                "vbv" => hevc.custom_vbv = false,
                _ => hevc.profiles.retain(|p| *p != Profile::HevcMain),
            }
            let problems = hevc.base_problems(false).join("; ");
            assert!(problems.contains(expected), "{field}: {problems}");
            assert!(!hevc.usable(false));
            assert!(problem(&hevc, &session(1920, 1080)).contains(expected));
        }
    }

    #[test]
    fn intra_refresh_matters_only_when_the_host_asks_for_it() {
        let mut hevc = hevc();
        hevc.intra_refresh = false;
        assert!(hevc.usable(false));
        assert!(hevc.base_problems(true).join(";").contains("intra refresh"));
        let mut requirement = session(1920, 1080);
        requirement.intra_refresh = true;
        assert!(problem(&hevc, &requirement).contains("intra refresh"));
    }

    #[test]
    fn the_size_must_be_inside_the_encoders_limits() {
        let h264 = h264();
        let too_wide = problem(&h264, &session(5120, 1440));
        assert!(
            too_wide.contains("5120x1440") && too_wide.contains("4096x4096"),
            "{too_wide}"
        );
        let too_small = problem(&h264, &session(100, 1080));
        assert!(
            too_small.contains("100x1080") && too_small.contains("145x49"),
            "{too_small}"
        );
        assert!(problem(&h264, &session(0, 0)).contains("0x0"));
        h264.check(&session(4096, 2160)).unwrap();
    }

    #[test]
    fn a_preset_without_an_ultra_low_latency_config_is_refused() {
        let mut hevc = hevc();
        hevc.ull_presets.retain(|q| *q != Quality::Quality);
        let mut requirement = session(1920, 1080);
        requirement.quality = Quality::Quality;
        let error = problem(&hevc, &requirement);
        assert!(
            error.contains("P6") && error.contains("ultra-low-latency"),
            "{error}"
        );
        requirement.quality = Quality::Speed;
        hevc.check(&requirement).unwrap();
    }

    #[test]
    fn picture_flags_need_their_profile_and_cap() {
        let mut requirement = session(1920, 1080);
        requirement.full_color = true;
        let mut no_444 = hevc();
        no_444.yuv444 = false;
        assert!(problem(&no_444, &requirement).contains("4:4:4"));
        let mut no_rext = hevc();
        no_rext.profiles.retain(|p| *p != Profile::HevcRext);
        assert!(problem(&no_rext, &requirement).contains("Rext"));

        let mut requirement = session(1920, 1080);
        requirement.ten_bit = true;
        let mut no_10 = hevc();
        no_10.ten_bit = false;
        assert!(problem(&no_10, &requirement).contains("10-bit"));
        let mut no_main10 = hevc();
        no_main10.profiles.retain(|p| *p != Profile::HevcMain10);
        assert!(problem(&no_main10, &requirement).contains("Main10"));
    }

    #[test]
    fn video_caps_advertise_only_what_the_hevc_encoder_supports() {
        assert_eq!(
            rtx().video_caps(false),
            VideoCaps {
                quality: true,
                hevc: true,
                full_color: true,
                ten_bit: true,
            }
        );
        let mut plain = hevc();
        plain.yuv444 = false;
        plain.profiles.retain(|p| *p != Profile::HevcMain10);
        let video = caps(vec![plain, h264()]).video_caps(false);
        assert!(
            video.hevc && !video.full_color && !video.ten_bit,
            "{video:?}"
        );

        // A GTX 750 Ti: H.264 only.
        let video = caps(vec![h264()]).video_caps(false);
        assert!(
            !video.hevc && !video.full_color && !video.ten_bit,
            "{video:?}"
        );
        assert_eq!(caps(vec![h264()]).codec_mask(false), Codec::H264.bit());
    }

    #[test]
    fn an_unusable_hevc_encoder_is_not_advertised() {
        let mut broken = hevc();
        broken.async_encode = false;
        let record = caps(vec![broken, h264()]);
        assert_eq!(record.codec_mask(false), Codec::H264.bit());
        assert!(!record.video_caps(false).hevc);
        record.ensure_usable(false).unwrap();
    }

    #[test]
    fn no_usable_codec_is_an_error_that_explains_each() {
        let mut hevc = hevc();
        hevc.argb_input = false;
        let mut h264 = h264();
        h264.cbr = false;
        let error = format!(
            "{:#}",
            caps(vec![hevc, h264]).ensure_usable(false).unwrap_err()
        );
        assert!(error.contains("HEVC") && error.contains("ARGB"), "{error}");
        assert!(error.contains("H.264") && error.contains("CBR"), "{error}");
        let error = format!("{:#}", caps(vec![]).ensure_usable(false).unwrap_err());
        assert!(error.contains("neither HEVC nor H.264"), "{error}");
    }

    #[test]
    fn describe_reports_identity_lists_and_verdicts() {
        let mut broken = h264();
        broken.argb_input = false;
        let text = caps(vec![hevc(), broken]).describe(false);
        for expected in [
            "NVIDIA GeForce RTX 3080 Ti",
            "LUID 0:122e1",
            "NVENC API 13.0",
            "needs 12.1",
            "HEVC: usable",
            "profiles: Main, Main10, Rext",
            "ultra-low-latency: P1, P4, P6",
            "input formats: NV12, ARGB",
            "129x33 to 8192x8192",
            "H.264: not usable (no ARGB input format)",
        ] {
            assert!(text.contains(expected), "missing {expected:?} in\n{text}");
        }
    }

    #[test]
    fn the_rated_rate_converts_to_frames_per_second() {
        let mut hevc = hevc();
        assert_eq!(hevc.rated_fps(3024, 1964), None);
        // 3024x1964 is 189x123 macroblocks: 23,247 per frame.
        hevc.mb_per_sec_max = 23_247 * 120;
        assert_eq!(hevc.rated_fps(3024, 1964), Some(120.0));
        // Partial macroblocks round up: 190x123.
        let fps = hevc.rated_fps(3025, 1964).unwrap();
        assert!((fps - 23_247.0 * 120.0 / 23_370.0).abs() < 1e-9, "{fps}");
        assert_eq!(hevc.rated_fps(0, 1964), None);
    }
}
