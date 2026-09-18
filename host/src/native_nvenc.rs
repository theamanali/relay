//! In-process Desktop Duplication -> D3D11 -> NVENC path for NVIDIA GPUs.
//!
//! The captured desktop and the encoder input stay in video memory. Desktop
//! Duplication's pointer shape is blended with a four-vertex D3D11 overlay.

use std::collections::VecDeque;
use std::ffi::{c_void, CStr};
use std::mem::{size_of, zeroed, MaybeUninit};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, SyncSender, TrySendError};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::nvenc_bindings::nv_encode_api::*;
use crate::nvenc_bindings::NvApi;
use anyhow::{anyhow, bail, Context, Result};
use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, BOOL, HANDLE, HMODULE, WAIT_OBJECT_0};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Multithread, ID3D11Texture2D,
    D3D11_BIND_RENDER_TARGET, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIFactory1, IDXGIOutput1, IDXGIOutputDuplication, IDXGIResource,
    DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
};
use windows::Win32::Media::{timeBeginPeriod, timeEndPeriod, TIMERR_NOERROR};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::Threading::{
    CreateEventW, CreateWaitableTimerExW, GetCurrentThread, SetThreadPriority, SetWaitableTimerEx,
    WaitForSingleObject, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, THREAD_PRIORITY_HIGHEST,
    TIMER_ALL_ACCESS,
};

use crate::cursor_overlay::CursorOverlay;
use crate::encoder::{AccessUnit, AnnexBParser, EncoderConfig, EncoderTiming, Quality};
use crate::protocol::Codec;

/// Handle held by the server thread. Capture runs on its own thread so it can
/// block in `AcquireNextFrame` and submit the instant DWM presents a frame; a
/// second thread waits for NVENC output. Finished pictures arrive here through
/// a channel, so `next_access_unit` is a plain receive.
pub struct NativeNvenc {
    api: NvApi,
    encoder: *mut c_void,
    events_rx: Option<Receiver<OutputEvent>>,
    free_tx: Sender<usize>,
    capture: Option<JoinHandle<CaptureLoop>>,
    worker: Option<JoinHandle<()>>,
    stop: Arc<AtomicBool>,
    timer_period_raised: bool,
    // Rolling per-stage latency instrumentation, logged every `STAT_INTERVAL`
    // frames. `capture` is the on-GPU work of turning an acquired frame into a
    // submitted encode (copy + cursor + slot copy + the encode call); `encode`
    // is submit -> NVENC output ready, measured on the worker thread.
    stat_frames: u32,
    stat_capture: Duration,
    stat_encode: Duration,
    // How long the desktop frame had been sitting in DWM's output when we
    // submitted it (QPC now - LastPresentTime). `stat_reused` counts fallback
    // ticks where the desktop had nothing new and the previous frame was
    // re-encoded so the client keeps receiving pictures.
    stat_age: Duration,
    stat_age_max: Duration,
    stat_fresh: u32,
    stat_reused: u32,
}

/// How many frames between native per-stage latency log lines (~5 s at 120 fps).
const STAT_INTERVAL: u32 = 600;

const PIPELINE_DEPTH: usize = 2;
const ENCODE_WAIT_MS: u32 = 2_000;
/// How long the server thread waits for a picture before giving up. The
/// capture thread re-encodes the last frame every tick when the desktop is
/// static, so nothing arriving for this long means capture is dead (or the
/// captured display is asleep and Desktop Duplication delivers nothing).
const PICTURE_WAIT: Duration = Duration::from_secs(5);
/// Longest the capture thread waits for the output worker to free a slot.
const SLOT_WAIT: Duration = Duration::from_secs(2);
/// Gap between `AcquireNextFrame` polls while waiting for the next desktop
/// frame; the average latency it adds is half of this.
const ACQUIRE_POLL: Duration = Duration::from_micros(200);
/// Poll gap while no desktop frame has arrived yet.
const FIRST_FRAME_POLL: Duration = Duration::from_millis(20);
/// How long after DWM's present the tick should land. Margin against the
/// virtual display's vblank jitter; the content is about this old at submit.
const TARGET_LEAD: Duration = Duration::from_micros(800);
/// Phase servo: correct this fraction of the lead error per tick ...
const SERVO_DIVISOR: u32 = 4;
/// ... but never move a tick by more than this, so the cadence stays even.
const SERVO_MAX_STEP: Duration = Duration::from_micros(400);

struct EncodeSlot {
    texture: ID3D11Texture2D,
    registered: NV_ENC_REGISTERED_PTR,
    bitstream: NV_ENC_OUTPUT_PTR,
    event: HANDLE,
    mapped: NV_ENC_INPUT_PTR,
}

struct PendingOutput {
    slot_index: usize,
    mapped: NV_ENC_INPUT_PTR,
    bitstream: NV_ENC_OUTPUT_PTR,
    event: HANDLE,
    /// When the picture was handed to NVENC, for the submit->output latency.
    submitted_at: Instant,
}

// NVENC's Windows asynchronous API explicitly permits output processing on a
// second thread. These handles remain valid until that thread is joined.
unsafe impl Send for PendingOutput {}

/// Per-picture facts the capture thread knows and the stats need.
#[derive(Clone, Copy)]
struct CaptureInfo {
    /// GPU-side work (desktop copy + cursor + slot copy + encode call).
    work: Duration,
    /// Age of the desktop content at submit, when DWM reported a present time.
    age: Option<Duration>,
    /// The desktop had nothing new; the previous frame was re-encoded.
    reused: bool,
}

struct CompletedOutput {
    slot_index: usize,
    result: Result<AccessUnit>,
    capture: CaptureInfo,
    /// submit -> NVENC output ready, for latency instrumentation.
    encode_latency: Duration,
}

enum OutputEvent {
    Completed(CompletedOutput),
    /// Desktop Duplication lost access (mode change); the server recreates capture.
    CaptureLost,
    CaptureFailed(anyhow::Error),
}

struct OutputWorkerContext {
    functions: NV_ENCODE_API_FUNCTION_LIST,
    encoder: *mut c_void,
    codec: Codec,
}

unsafe impl Send for OutputWorkerContext {}

/// Everything the capture thread owns. Returned from the thread on exit so
/// `Drop` can release the slots after both threads are gone.
struct CaptureLoop {
    functions: NV_ENCODE_API_FUNCTION_LIST,
    encoder: *mut c_void,
    _device: ID3D11Device,
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    composition_texture: ID3D11Texture2D,
    cursor: CursorOverlay,
    width: u32,
    height: u32,
    frame_interval: Duration,
    frame_idx: u32,
    slots: Vec<EncodeSlot>,
    /// The composition texture holds a desktop frame.
    have_frame: bool,
    /// The composition texture changed since the last submit.
    dirty: bool,
    /// DWM's QPC present time for content acquired since the last submit, when
    /// DWM reported one (cursor-only updates do not carry a present time).
    pending_present_qpc: Option<i64>,
    /// GPU work done for the pending content since the last submit.
    pending_work: Duration,
    /// When the next picture goes to NVENC. Steady at `frame_interval`, with
    /// its phase nudged towards `TARGET_LEAD` after DWM's presents.
    next_tick: Option<Instant>,
    /// The previous tick submitted fresh content with a present time, so the
    /// desktop is updating at least as fast as the ticks and its lead is a
    /// meaningful phase error.
    last_tick_fresh: bool,
    qpc_frequency: i64,
    sleeper: HighResSleeper,
    worker_tx: Option<Sender<(PendingOutput, CaptureInfo)>>,
    free_rx: Receiver<usize>,
    events_tx: SyncSender<OutputEvent>,
    stop: Arc<AtomicBool>,
}

// The D3D11 device has multithread protection on and NVENC's asynchronous API
// is designed for submit/collect on different threads; the raw pointers are
// only used from this thread until it exits and hands them back for cleanup.
unsafe impl Send for CaptureLoop {}

/// Sub-millisecond sleeps via a high-resolution waitable timer, with
/// `thread::sleep` as the fallback on systems that lack it.
struct HighResSleeper {
    timer: Option<HANDLE>,
}

impl HighResSleeper {
    fn new() -> Self {
        let timer = unsafe {
            CreateWaitableTimerExW(
                None,
                PCWSTR::null(),
                CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                TIMER_ALL_ACCESS.0,
            )
        };
        match timer {
            Ok(timer) => Self { timer: Some(timer) },
            Err(error) => {
                log::warn!(
                    "high-resolution timer unavailable ({error}); capture polls with thread sleep"
                );
                Self { timer: None }
            }
        }
    }

    fn sleep(&self, duration: Duration) {
        if duration.is_zero() {
            return;
        }
        let Some(timer) = self.timer else {
            thread::sleep(duration);
            return;
        };
        // Negative 100 ns units request a relative due time.
        let ticks = duration.as_nanos().div_ceil(100).min(i64::MAX as u128) as i64;
        let due_time = -ticks.max(1);
        if unsafe { SetWaitableTimerEx(timer, &due_time, 0, None, None, None, 0) }.is_err()
            || unsafe { WaitForSingleObject(timer, 1_000) } != WAIT_OBJECT_0
        {
            thread::sleep(duration);
        }
    }
}

impl Drop for HighResSleeper {
    fn drop(&mut self) {
        if let Some(timer) = self.timer.take() {
            unsafe {
                let _ = CloseHandle(timer);
            }
        }
    }
}

/// Owns the NVENC session while it is being configured; becomes part of the
/// capture loop once the threads start.
struct EncoderSession {
    api: NvApi,
    device: ID3D11Device,
    encoder: *mut c_void,
    width: u32,
    height: u32,
    fps: u32,
    slots: Vec<EncodeSlot>,
}

impl NativeNvenc {
    pub fn spawn(cfg: &EncoderConfig) -> Result<Self> {
        if cfg.cross_adapter() {
            bail!("native NVENC requires capture and encode on the same DXGI adapter");
        }

        let api = NvApi::load()?;
        // Desktop Duplication only opens from a thread on the input desktop;
        // a SYSTEM worker may bind to Winlogon (lock/login screen), a user
        // process may not — that failure shows up as E_ACCESSDENIED below.
        match crate::desktop::bind_input_desktop() {
            Ok(name) => log::debug!("capture bound to the {name} desktop"),
            Err(e) => log::debug!("not bound to the input desktop: {e:#}"),
        }
        let (device, context, duplication, width, height) =
            create_capture(cfg.capture_adapter_idx, cfg.output_idx)?;
        let composition_texture = create_texture(&device, width, height)?;
        let cursor = CursorOverlay::new(&device, &composition_texture, width, height)?;

        let mut session = EncoderSession {
            api,
            device,
            encoder: ptr::null_mut(),
            width,
            height,
            fps: cfg.fps.max(1),
            slots: Vec::with_capacity(PIPELINE_DEPTH),
        };
        if let Err(error) = session.initialize_encoder(cfg) {
            session.destroy();
            return Err(error);
        }

        // Event waits and channel timeouts on this path otherwise quantise to
        // the default ~15.6 ms scheduler tick.
        let timer_period_raised = unsafe { timeBeginPeriod(1) } == TIMERR_NOERROR;
        if !timer_period_raised {
            log::warn!("could not raise the system timer resolution to 1 ms");
        }

        let (pending_tx, pending_rx) = mpsc::channel();
        let (free_tx, free_rx) = mpsc::channel();
        // Completed access units must not accumulate without bound when TCP is
        // slower than the encoder. Backpressure reaches the two NVENC slots
        // instead of retaining an ever-growing queue of encoded frames.
        let (events_tx, events_rx) = mpsc::sync_channel(PIPELINE_DEPTH);
        let stop = Arc::new(AtomicBool::new(false));

        let worker_context = OutputWorkerContext {
            functions: session.api.functions,
            encoder: session.encoder,
            codec: cfg.codec,
        };
        let worker_events = events_tx.clone();
        let worker_free = free_tx.clone();
        let worker = match thread::Builder::new()
            .name("nvenc-output".into())
            .spawn(move || output_worker(worker_context, pending_rx, worker_events, worker_free))
        {
            Ok(worker) => worker,
            Err(error) => {
                drop(pending_tx);
                if timer_period_raised {
                    unsafe {
                        let _ = timeEndPeriod(1);
                    }
                }
                session.destroy();
                return Err(error).context("starting NVENC output worker");
            }
        };

        // Start the thread before handing it GPU/NVENC resources. If thread
        // creation fails, every resource still belongs to `session` and can be
        // released synchronously here.
        let (capture_start_tx, capture_start_rx) = mpsc::sync_channel::<CaptureLoop>(0);
        let capture = match thread::Builder::new()
            .name("nvenc-capture".into())
            .spawn(move || match capture_start_rx.recv() {
                Ok(capture_loop) => capture_loop.run(),
                Err(_) => unreachable!("capture startup sender dropped"),
            }) {
            Ok(capture) => capture,
            Err(error) => {
                drop(pending_tx);
                let _ = worker.join();
                if timer_period_raised {
                    unsafe {
                        let _ = timeEndPeriod(1);
                    }
                }
                session.destroy();
                return Err(error).context("starting native capture thread");
            }
        };

        let capture_loop = CaptureLoop {
            functions: session.api.functions,
            encoder: session.encoder,
            _device: session.device.clone(),
            context,
            duplication,
            composition_texture,
            cursor,
            width,
            height,
            frame_interval: Duration::from_secs_f64(1.0 / f64::from(session.fps)),
            frame_idx: 0,
            slots: std::mem::take(&mut session.slots),
            have_frame: false,
            dirty: false,
            pending_present_qpc: None,
            pending_work: Duration::ZERO,
            next_tick: None,
            last_tick_fresh: false,
            qpc_frequency: qpc_frequency(),
            sleeper: HighResSleeper::new(),
            worker_tx: Some(pending_tx),
            free_rx,
            events_tx,
            stop: Arc::clone(&stop),
        };
        if let Err(error) = capture_start_tx.send(capture_loop) {
            let mut capture_loop = error.0;
            capture_loop.worker_tx.take();
            let _ = worker.join();
            release_slots(&session.api, session.encoder, &mut capture_loop.slots);
            drop(capture_loop);
            let _ = capture.join();
            if timer_period_raised {
                unsafe {
                    let _ = timeEndPeriod(1);
                }
            }
            session.destroy();
            bail!("native capture thread stopped during startup");
        }

        Ok(NativeNvenc {
            api: session.api,
            encoder: session.encoder,
            events_rx: Some(events_rx),
            free_tx,
            capture: Some(capture),
            worker: Some(worker),
            stop,
            timer_period_raised,
            stat_frames: 0,
            stat_capture: Duration::ZERO,
            stat_encode: Duration::ZERO,
            stat_age: Duration::ZERO,
            stat_age_max: Duration::ZERO,
            stat_fresh: 0,
            stat_reused: 0,
        })
    }

    /// Wait for the next finished picture. `None` asks the server to recreate
    /// capture after a fullscreen/mode change.
    pub fn next_access_unit(&mut self) -> Result<Option<AccessUnit>> {
        let events = self
            .events_rx
            .as_ref()
            .ok_or_else(|| anyhow!("native capture is not running"))?;
        match events.recv_timeout(PICTURE_WAIT) {
            Ok(OutputEvent::Completed(completed)) => self.record_and_return(completed),
            Ok(OutputEvent::CaptureLost) => Ok(None),
            Ok(OutputEvent::CaptureFailed(error)) => Err(error),
            Err(RecvTimeoutError::Timeout) => bail!(
                "no picture from native capture for {} s (is the captured display asleep?)",
                PICTURE_WAIT.as_secs()
            ),
            Err(RecvTimeoutError::Disconnected) => bail!("native capture stopped"),
        }
    }

    /// Fold a finished picture's timings into the rolling stats (logging a line
    /// every `STAT_INTERVAL` frames) and hand its access unit to the caller.
    fn record_and_return(&mut self, mut completed: CompletedOutput) -> Result<Option<AccessUnit>> {
        let slot_index = completed.slot_index;
        self.stat_capture += completed.capture.work;
        self.stat_encode += completed.encode_latency;
        self.stat_frames += 1;
        if completed.capture.reused {
            self.stat_reused += 1;
        } else {
            self.stat_fresh += 1;
        }
        if let Some(age) = completed.capture.age {
            self.stat_age += age;
            self.stat_age_max = self.stat_age_max.max(age);
        }
        if self.stat_frames >= STAT_INTERVAL {
            let n = f64::from(self.stat_frames.max(1));
            let fresh = f64::from(self.stat_fresh.max(1));
            log::info!(
                "native latency avg over {} frames: capture {:.2} ms, encode {:.2} ms; desktop frame age at submit avg {:.2} ms, max {:.2} ms ({} fresh, {} reused)",
                self.stat_frames,
                self.stat_capture.as_secs_f64() * 1000.0 / n,
                self.stat_encode.as_secs_f64() * 1000.0 / n,
                self.stat_age.as_secs_f64() * 1000.0 / fresh,
                self.stat_age_max.as_secs_f64() * 1000.0,
                self.stat_fresh,
                self.stat_reused,
            );
            self.stat_frames = 0;
            self.stat_capture = Duration::ZERO;
            self.stat_encode = Duration::ZERO;
            self.stat_age = Duration::ZERO;
            self.stat_age_max = Duration::ZERO;
            self.stat_fresh = 0;
            self.stat_reused = 0;
        }
        if let Ok(access_unit) = &mut completed.result {
            access_unit.timing = Some(EncoderTiming {
                capture: completed.capture.work,
                encode: completed.encode_latency,
            });
        }
        let result = completed.result.map(Some);
        // The completion has left the bounded queue and its copied bitstream
        // belongs to the server now, so this input slot may be reused.
        let _ = self.free_tx.send(slot_index);
        result
    }
}

impl EncoderSession {
    /// Release the NVENC session when configuration fails before the threads
    /// exist (the running case is handled by `NativeNvenc::drop`).
    fn destroy(mut self) {
        release_slots(&self.api, self.encoder, &mut self.slots);
        if !self.encoder.is_null() {
            if let Some(destroy) = self.api.functions.nvEncDestroyEncoder {
                unsafe {
                    let _ = destroy(self.encoder);
                }
            }
        }
    }

    fn initialize_encoder(&mut self, cfg: &EncoderConfig) -> Result<()> {
        let mut open: NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS = unsafe { zeroed() };
        open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        open.deviceType = NV_ENC_DEVICE_TYPE::NV_ENC_DEVICE_TYPE_DIRECTX;
        open.device = self.device.as_raw();
        open.apiVersion = NVENCAPI_VERSION;
        let open_session = self.api.required(
            self.api.functions.nvEncOpenEncodeSessionEx,
            "NvEncOpenEncodeSessionEx",
        )?;
        nv_check(
            &self.api,
            ptr::null_mut(),
            unsafe { open_session(&mut open, &mut self.encoder) },
            "NvEncOpenEncodeSessionEx",
        )?;

        let codec_guid = codec_guid(cfg.codec);
        let preset_guid = match cfg.quality {
            Quality::Speed => NV_ENC_PRESET_P1_GUID,
            Quality::Balanced => NV_ENC_PRESET_P4_GUID,
            Quality::Quality => NV_ENC_PRESET_P6_GUID,
        };
        let tuning = NV_ENC_TUNING_INFO::NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;

        // NV_ENC_PRESET_CONFIG contains enums whose first valid value is 1,
        // so it cannot exist as an all-zero Rust value. Keep zero-filled raw
        // storage until the driver has populated the output structure.
        let mut preset = MaybeUninit::<NV_ENC_PRESET_CONFIG>::uninit();
        unsafe {
            ptr::write_bytes(
                preset.as_mut_ptr().cast::<u8>(),
                0,
                size_of::<NV_ENC_PRESET_CONFIG>(),
            );
            ptr::addr_of_mut!((*preset.as_mut_ptr()).version).write(NV_ENC_PRESET_CONFIG_VER);
            ptr::addr_of_mut!((*preset.as_mut_ptr()).presetCfg.version).write(NV_ENC_CONFIG_VER);
        }
        let get_preset = self.api.required(
            self.api.functions.nvEncGetEncodePresetConfigEx,
            "NvEncGetEncodePresetConfigEx",
        )?;
        nv_check(
            &self.api,
            self.encoder,
            unsafe {
                get_preset(
                    self.encoder,
                    codec_guid,
                    preset_guid,
                    tuning,
                    preset.as_mut_ptr(),
                )
            },
            "NvEncGetEncodePresetConfigEx",
        )?;
        let mut preset = unsafe { preset.assume_init() };

        let config = &mut preset.presetCfg;
        config.version = NV_ENC_CONFIG_VER;
        config.profileGUID = profile_guid(cfg.codec);
        config.gopLength = cfg.gop.max(1);
        config.frameIntervalP = 1; // no B frames
        config.rcParams.version = NV_ENC_RC_PARAMS_VER;
        config.rcParams.rateControlMode = NV_ENC_PARAMS_RC_MODE::NV_ENC_PARAMS_RC_CBR;
        let bitrate = cfg.bitrate_mbps.saturating_mul(1_000_000);
        let one_frame = (bitrate / cfg.fps.max(1)).max(1);
        config.rcParams.averageBitRate = bitrate;
        config.rcParams.maxBitRate = bitrate;
        config.rcParams.vbvBufferSize = one_frame;
        config.rcParams.vbvInitialDelay = one_frame;
        config.rcParams.set_zeroReorderDelay(1);
        config.rcParams.set_enableLookahead(0);

        unsafe {
            match cfg.codec {
                Codec::Hevc => {
                    let hevc = &mut config.encodeCodecConfig.hevcConfig;
                    signal_colour(&mut hevc.hevcVUIParameters);
                    hevc.set_outputAUD(1);
                    hevc.set_repeatSPSPPS(1);
                    hevc.set_enableIntraRefresh(u32::from(cfg.intra_refresh));
                    if cfg.intra_refresh {
                        hevc.intraRefreshPeriod = cfg.gop.max(1);
                        hevc.intraRefreshCnt = cfg.fps.max(1);
                    }
                }
                Codec::H264 => {
                    let h264 = &mut config.encodeCodecConfig.h264Config;
                    signal_colour(&mut h264.h264VUIParameters);
                    h264.set_outputAUD(1);
                    h264.set_repeatSPSPPS(1);
                    h264.set_enableIntraRefresh(u32::from(cfg.intra_refresh));
                    if cfg.intra_refresh {
                        h264.intraRefreshPeriod = cfg.gop.max(1);
                        h264.intraRefreshCnt = cfg.fps.max(1);
                    }
                }
            }
        }

        let mut init: NV_ENC_INITIALIZE_PARAMS = unsafe { zeroed() };
        init.version = NV_ENC_INITIALIZE_PARAMS_VER;
        init.encodeGUID = codec_guid;
        init.presetGUID = preset_guid;
        init.encodeWidth = self.width;
        init.encodeHeight = self.height;
        init.darWidth = self.width;
        init.darHeight = self.height;
        init.frameRateNum = self.fps;
        init.frameRateDen = 1;
        // Windows NVENC can signal output completion through events. Two
        // buffers let frame N encode while frame N+1 is captured/composited.
        init.enableEncodeAsync = 1;
        init.enablePTD = 1;
        init.encodeConfig = config;
        init.maxEncodeWidth = self.width;
        init.maxEncodeHeight = self.height;
        init.tuningInfo = tuning;
        init.bufferFormat = NV_ENC_BUFFER_FORMAT::NV_ENC_BUFFER_FORMAT_ARGB;
        let initialize = self.api.required(
            self.api.functions.nvEncInitializeEncoder,
            "NvEncInitializeEncoder",
        )?;
        nv_check(
            &self.api,
            self.encoder,
            unsafe { initialize(self.encoder, &mut init) },
            "NvEncInitializeEncoder",
        )?;

        for _ in 0..PIPELINE_DEPTH {
            self.slots.push(self.create_slot()?);
        }

        log::info!(
            "native capture: Desktop Duplication -> D3D11 -> asynchronous NVENC, {}x{}@{} (GPU cursor overlay, {} buffers)",
            self.width,
            self.height,
            self.fps,
            PIPELINE_DEPTH
        );
        Ok(())
    }

    fn create_slot(&self) -> Result<EncodeSlot> {
        let texture = create_texture(&self.device, self.width, self.height)?;

        let mut register: NV_ENC_REGISTER_RESOURCE = unsafe { zeroed() };
        register.version = NV_ENC_REGISTER_RESOURCE_VER;
        register.resourceType = NV_ENC_INPUT_RESOURCE_TYPE::NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
        register.width = self.width;
        register.height = self.height;
        register.resourceToRegister = texture.as_raw();
        register.bufferFormat = NV_ENC_BUFFER_FORMAT::NV_ENC_BUFFER_FORMAT_ARGB;
        register.bufferUsage = NV_ENC_BUFFER_USAGE::NV_ENC_INPUT_IMAGE;
        let register_resource = self.api.required(
            self.api.functions.nvEncRegisterResource,
            "NvEncRegisterResource",
        )?;
        nv_check(
            &self.api,
            self.encoder,
            unsafe { register_resource(self.encoder, &mut register) },
            "NvEncRegisterResource",
        )?;

        let mut create: NV_ENC_CREATE_BITSTREAM_BUFFER = unsafe { zeroed() };
        create.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
        let create_bitstream = self.api.required(
            self.api.functions.nvEncCreateBitstreamBuffer,
            "NvEncCreateBitstreamBuffer",
        )?;
        if let Err(error) = nv_check(
            &self.api,
            self.encoder,
            unsafe { create_bitstream(self.encoder, &mut create) },
            "NvEncCreateBitstreamBuffer",
        ) {
            if let Some(unregister) = self.api.functions.nvEncUnregisterResource {
                unsafe { unregister(self.encoder, register.registeredResource) };
            }
            return Err(error);
        }

        let event = match unsafe { CreateEventW(None, BOOL(0), BOOL(0), None) } {
            Ok(event) => event,
            Err(error) => {
                if let Some(destroy) = self.api.functions.nvEncDestroyBitstreamBuffer {
                    unsafe { destroy(self.encoder, create.bitstreamBuffer) };
                }
                if let Some(unregister) = self.api.functions.nvEncUnregisterResource {
                    unsafe { unregister(self.encoder, register.registeredResource) };
                }
                return Err(error).context("CreateEventW for NVENC completion");
            }
        };
        let mut event_params: NV_ENC_EVENT_PARAMS = unsafe { zeroed() };
        event_params.version = NV_ENC_EVENT_PARAMS_VER;
        event_params.completionEvent = event.0;
        let Some(register_event) = self.api.functions.nvEncRegisterAsyncEvent else {
            unsafe {
                let _ = CloseHandle(event);
                if let Some(destroy) = self.api.functions.nvEncDestroyBitstreamBuffer {
                    destroy(self.encoder, create.bitstreamBuffer);
                }
                if let Some(unregister) = self.api.functions.nvEncUnregisterResource {
                    unregister(self.encoder, register.registeredResource);
                }
            }
            bail!("NVIDIA driver does not provide NvEncRegisterAsyncEvent");
        };
        if let Err(error) = nv_check(
            &self.api,
            self.encoder,
            unsafe { register_event(self.encoder, &mut event_params) },
            "NvEncRegisterAsyncEvent",
        ) {
            unsafe {
                let _ = CloseHandle(event);
                if let Some(destroy) = self.api.functions.nvEncDestroyBitstreamBuffer {
                    destroy(self.encoder, create.bitstreamBuffer);
                }
                if let Some(unregister) = self.api.functions.nvEncUnregisterResource {
                    unregister(self.encoder, register.registeredResource);
                }
            }
            return Err(error);
        }

        Ok(EncodeSlot {
            texture,
            registered: register.registeredResource,
            bitstream: create.bitstreamBuffer,
            event,
            mapped: ptr::null_mut(),
        })
    }
}

impl CaptureLoop {
    /// Thread body. Runs until stopped, until Desktop Duplication loses access
    /// (reported as `CaptureLost`) or until something fails (`CaptureFailed`).
    fn run(mut self) -> Self {
        raise_thread_priority("nvenc-capture");
        if let Ok(name) = crate::desktop::bind_input_desktop() {
            log::debug!("capture thread on the {name} desktop");
        }
        while !self.stop.load(Ordering::Relaxed) {
            match self.step() {
                Ok(true) => {}
                Ok(false) => {
                    log::warn!("Desktop Duplication access lost; recreating native capture");
                    let _ = self.events_tx.try_send(OutputEvent::CaptureLost);
                    break;
                }
                Err(error) => {
                    match self.events_tx.try_send(OutputEvent::CaptureFailed(error)) {
                        Ok(()) | Err(TrySendError::Disconnected(_)) => {}
                        Err(TrySendError::Full(_)) => {
                            // A full completion queue already guarantees the
                            // server will either drain it or hit congestion.
                        }
                    }
                    break;
                }
            }
        }
        // Closing the pending channel lets the output worker finish and exit.
        self.worker_tx.take();
        self
    }

    /// One tick: poll `AcquireNextFrame` and fold every new desktop frame into
    /// the composition texture until the tick is due, then submit whatever is
    /// newest. Ticks are steady at the frame interval so the client sees an
    /// even cadence whatever DWM does (the virtual display's vblank is a
    /// software timer and jitters by milliseconds); their phase is servoed so a
    /// tick lands `TARGET_LEAD` after DWM's present, which keeps the content
    /// about that fresh instead of the random 0-8 ms a free-running tick gets.
    /// `Ok(false)` means access was lost.
    ///
    /// The poll never blocks inside DXGI: with multithread protection on, a
    /// thread waiting in `AcquireNextFrame` holds the D3D11 device lock, and
    /// NVENC's DirectX input pass then cannot finish the previous picture until
    /// the wait returns (measured: encode time became one frame interval).
    fn step(&mut self) -> Result<bool> {
        let slot_index = self.wait_for_free_slot()?;

        let tick = loop {
            if self.stop.load(Ordering::Relaxed) {
                return Ok(true);
            }
            let mut info: DXGI_OUTDUPL_FRAME_INFO = unsafe { zeroed() };
            let mut resource: Option<IDXGIResource> = None;
            match unsafe {
                self.duplication
                    .AcquireNextFrame(0, &mut info, &mut resource)
            } {
                Ok(()) => self.composite(resource, &info)?,
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {}
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => return Ok(false),
                Err(e) => return Err(e).context("IDXGIOutputDuplication::AcquireNextFrame"),
            }
            let now = Instant::now();
            match self.next_tick {
                // The first desktop frame sets the initial phase.
                None if self.have_frame => break now,
                None => self.sleeper.sleep(FIRST_FRAME_POLL),
                Some(tick) if now >= tick => break tick,
                Some(tick) => self.sleeper.sleep(ACQUIRE_POLL.min(tick - now)),
            }
        };

        let fresh = self.dirty;
        let lead = self.submit(slot_index)?;

        // Phase servo. Only a fresh frame with a present time measures the
        // lead, and only when the previous tick had one too: at lower desktop
        // rates (video) the lead is just where the tick fell in the content's
        // cycle, not a phase error.
        let mut next = tick + self.frame_interval;
        if let (true, Some(lead)) = (self.last_tick_fresh, lead) {
            if lead > TARGET_LEAD {
                next -= ((lead - TARGET_LEAD) / SERVO_DIVISOR).min(SERVO_MAX_STEP);
            } else {
                next += ((TARGET_LEAD - lead) / SERVO_DIVISOR).min(SERVO_MAX_STEP);
            }
        }
        self.last_tick_fresh = fresh && lead.is_some();
        // Fell behind (slot wait, GPU stall): resume from now, never burst.
        self.next_tick = Some(next.max(Instant::now()));
        Ok(true)
    }

    /// Block until the output worker has returned a slot. Slots come back
    /// well within a frame interval (encode is a few ms), so this normally
    /// returns at once.
    fn wait_for_free_slot(&mut self) -> Result<usize> {
        loop {
            while let Ok(index) = self.free_rx.try_recv() {
                self.slots[index].mapped = ptr::null_mut();
            }
            if let Some(index) = self.slots.iter().position(|slot| slot.mapped.is_null()) {
                return Ok(index);
            }
            match self.free_rx.recv_timeout(SLOT_WAIT) {
                Ok(index) => self.slots[index].mapped = ptr::null_mut(),
                Err(RecvTimeoutError::Timeout) => {
                    bail!("timed out waiting for the NVENC output worker")
                }
                Err(RecvTimeoutError::Disconnected) => bail!("NVENC output worker stopped"),
            }
        }
    }

    /// Copy an acquired desktop frame into the composition texture and refresh
    /// the cursor overlay, then release the frame back to DWM.
    fn composite(
        &mut self,
        resource: Option<IDXGIResource>,
        info: &DXGI_OUTDUPL_FRAME_INFO,
    ) -> Result<()> {
        let work_start = Instant::now();
        let copied = (|| -> Result<()> {
            let resource =
                resource.ok_or_else(|| anyhow!("Desktop Duplication returned no resource"))?;
            let desktop: ID3D11Texture2D = resource
                .cast()
                .context("desktop frame is not a D3D11 texture")?;
            unsafe {
                self.context
                    .CopyResource(&self.composition_texture, &desktop);
            }
            self.cursor.update(&self.duplication, info)?;
            Ok(())
        })();
        if let Err(e) = unsafe { self.duplication.ReleaseFrame() } {
            log::warn!("Desktop Duplication ReleaseFrame failed: {e}");
        }
        copied?;
        self.cursor.draw(&self.context);

        // LastPresentTime is 0 when only the cursor changed.
        if info.LastPresentTime != 0 {
            self.pending_present_qpc = Some(info.LastPresentTime);
        }
        self.have_frame = true;
        self.dirty = true;
        self.pending_work += work_start.elapsed();
        Ok(())
    }

    /// Copy the composition texture into a slot and hand it to NVENC. Returns
    /// how long the desktop content waited since DWM presented it, when known.
    fn submit(&mut self, slot_index: usize) -> Result<Option<Duration>> {
        let work_start = Instant::now();
        unsafe {
            self.context
                .CopyResource(&self.slots[slot_index].texture, &self.composition_texture);
        }

        let registered = self.slots[slot_index].registered;
        let bitstream = self.slots[slot_index].bitstream;
        let completion_event = self.slots[slot_index].event.0;
        let mut map: NV_ENC_MAP_INPUT_RESOURCE = unsafe { zeroed() };
        map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        map.registeredResource = registered;
        let map_input = self
            .functions
            .nvEncMapInputResource
            .ok_or_else(|| anyhow!("NVIDIA driver does not provide NvEncMapInputResource"))?;
        self.nv_check(
            unsafe { map_input(self.encoder, &mut map) },
            "NvEncMapInputResource",
        )?;

        let result = (|| -> Result<()> {
            // NV_ENC_PIC_PARAMS also has a non-zero enum discriminant. NVENC
            // only reads it, so populate raw storage and pass its pointer.
            let mut pic = MaybeUninit::<NV_ENC_PIC_PARAMS>::uninit();
            unsafe {
                ptr::write_bytes(
                    pic.as_mut_ptr().cast::<u8>(),
                    0,
                    size_of::<NV_ENC_PIC_PARAMS>(),
                );
                let pic = pic.as_mut_ptr();
                ptr::addr_of_mut!((*pic).version).write(NV_ENC_PIC_PARAMS_VER);
                ptr::addr_of_mut!((*pic).inputWidth).write(self.width);
                ptr::addr_of_mut!((*pic).inputHeight).write(self.height);
                ptr::addr_of_mut!((*pic).frameIdx).write(self.frame_idx);
                ptr::addr_of_mut!((*pic).inputTimeStamp).write(u64::from(self.frame_idx));
                ptr::addr_of_mut!((*pic).inputDuration).write(1);
                ptr::addr_of_mut!((*pic).inputBuffer).write(map.mappedResource);
                ptr::addr_of_mut!((*pic).outputBitstream).write(bitstream);
                ptr::addr_of_mut!((*pic).completionEvent).write(completion_event);
                ptr::addr_of_mut!((*pic).bufferFmt).write(map.mappedBufferFmt);
                ptr::addr_of_mut!((*pic).pictureStruct)
                    .write(NV_ENC_PIC_STRUCT::NV_ENC_PIC_STRUCT_FRAME);
                ptr::addr_of_mut!((*pic).pictureType)
                    .write(NV_ENC_PIC_TYPE::NV_ENC_PIC_TYPE_UNKNOWN);
                if self.frame_idx == 0 {
                    ptr::addr_of_mut!((*pic).encodePicFlags)
                        .write(NV_ENC_PIC_FLAGS::NV_ENC_PIC_FLAG_FORCEIDR as u32);
                }
            }
            let encode_picture = self
                .functions
                .nvEncEncodePicture
                .ok_or_else(|| anyhow!("NVIDIA driver does not provide NvEncEncodePicture"))?;
            let status = unsafe { encode_picture(self.encoder, pic.as_mut_ptr()) };
            if status == NVENCSTATUS::NV_ENC_SUCCESS
                || status == NVENCSTATUS::NV_ENC_ERR_NEED_MORE_INPUT
            {
                Ok(())
            } else {
                self.nv_check(status, "NvEncEncodePicture")
            }
        })();

        if let Err(error) = result {
            self.unmap(map.mappedResource)?;
            return Err(error);
        }
        self.slots[slot_index].mapped = map.mappedResource;
        let submitted_at = Instant::now();
        let pending = PendingOutput {
            slot_index,
            mapped: map.mappedResource,
            bitstream,
            event: self.slots[slot_index].event,
            submitted_at,
        };
        let age = self.pending_present_qpc.map(|qpc| self.qpc_age(qpc));
        let info = CaptureInfo {
            work: self.pending_work + work_start.elapsed(),
            age,
            reused: !self.dirty,
        };
        if self
            .worker_tx
            .as_ref()
            .ok_or_else(|| anyhow!("NVENC output worker is not running"))?
            .send((pending, info))
            .is_err()
        {
            self.unmap(map.mappedResource)?;
            self.slots[slot_index].mapped = ptr::null_mut();
            bail!("NVENC output worker stopped");
        }
        self.frame_idx = self.frame_idx.wrapping_add(1);
        self.dirty = false;
        self.pending_present_qpc = None;
        self.pending_work = Duration::ZERO;
        Ok(age)
    }

    /// Elapsed time since a QPC timestamp (DXGI's `LastPresentTime`).
    fn qpc_age(&self, present_time: i64) -> Duration {
        let mut now = 0i64;
        unsafe {
            let _ = QueryPerformanceCounter(&mut now);
        }
        let ticks = now.saturating_sub(present_time).max(0) as u128;
        Duration::from_nanos((ticks * 1_000_000_000 / self.qpc_frequency as u128) as u64)
    }

    fn unmap(&self, mapped: NV_ENC_INPUT_PTR) -> Result<()> {
        let unmap_input = self
            .functions
            .nvEncUnmapInputResource
            .ok_or_else(|| anyhow!("NVIDIA driver does not provide NvEncUnmapInputResource"))?;
        self.nv_check(
            unsafe { unmap_input(self.encoder, mapped) },
            "NvEncUnmapInputResource",
        )
    }

    fn nv_check(&self, status: NVENCSTATUS, operation: &str) -> Result<()> {
        nv_check_raw(&self.functions, self.encoder, status, operation)
    }
}

fn qpc_frequency() -> i64 {
    let mut frequency = 0i64;
    unsafe {
        let _ = QueryPerformanceFrequency(&mut frequency);
    }
    frequency.max(1)
}

/// Waits for each submitted picture, reads its bitstream, returns the slot to
/// the capture thread and the access unit to the server thread.
/// Capture and output are a few hundred microseconds of work per frame that
/// must not queue behind a game's render threads; a late poll or a late
/// bitstream read shows straight up in the client's p95. `HIGHEST` (priority
/// 15 in the normal class) is deliberate: `TIME_CRITICAL` (the realtime band)
/// starves DWM and the GPU scheduler enough that the virtual display stops
/// presenting.
fn raise_thread_priority(name: &str) {
    if let Err(error) = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST) } {
        log::warn!("could not raise {name} thread priority: {error}");
    }
}

fn output_worker(
    context: OutputWorkerContext,
    pending_rx: Receiver<(PendingOutput, CaptureInfo)>,
    events_tx: SyncSender<OutputEvent>,
    cleanup_free_tx: Sender<usize>,
) {
    raise_thread_priority("nvenc-output");
    while let Ok((pending, capture)) = pending_rx.recv() {
        let slot_index = pending.slot_index;
        let submitted_at = pending.submitted_at;
        let result = read_worker_output(&context, pending);
        let encode_latency = submitted_at.elapsed();
        if events_tx
            .send(OutputEvent::Completed(CompletedOutput {
                slot_index,
                result,
                capture,
                encode_latency,
            }))
            .is_err()
        {
            // read_worker_output already unmapped it; let teardown clear the
            // capture loop's bookkeeping even though no event can be queued.
            let _ = cleanup_free_tx.send(slot_index);
            break;
        }
        // The server returns the slot after consuming this completion. Until
        // then a full queue applies bounded backpressure to capture.
    }
}

impl Drop for NativeNvenc {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let mut capture_loop = self.capture.take().and_then(|capture| capture.join().ok());

        // A bounded completion channel may have the output worker blocked in
        // send(). Drain it while the worker exits; joining first would deadlock.
        if let (Some(worker), Some(events), Some(capture_loop)) = (
            self.worker.as_ref(),
            self.events_rx.as_ref(),
            capture_loop.as_mut(),
        ) {
            while !worker.is_finished() {
                match events.recv_timeout(Duration::from_millis(10)) {
                    Ok(event) => mark_completed_unmapped(event, &mut capture_loop.slots),
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }

        if let Some(mut capture_loop) = capture_loop {
            // Both threads are gone; anything the worker finished is unmapped
            // already, so only pictures it never reached remain mapped.
            while let Ok(index) = capture_loop.free_rx.try_recv() {
                capture_loop.slots[index].mapped = ptr::null_mut();
            }
            if let Some(events) = self.events_rx.take() {
                while let Ok(event) = events.try_recv() {
                    mark_completed_unmapped(event, &mut capture_loop.slots);
                }
            }
            release_slots(&self.api, self.encoder, &mut capture_loop.slots);
        }

        if !self.encoder.is_null() {
            if let Some(f) = self.api.functions.nvEncDestroyEncoder {
                unsafe {
                    let _ = f(self.encoder);
                }
            }
        }
        if self.timer_period_raised {
            unsafe {
                let _ = timeEndPeriod(1);
            }
        }
    }
}

fn mark_completed_unmapped(event: OutputEvent, slots: &mut [EncodeSlot]) {
    if let OutputEvent::Completed(output) = event {
        slots[output.slot_index].mapped = ptr::null_mut();
    }
}

/// Unmap, unregister and free every slot. Pictures still mapped are waited
/// for first so NVENC is not torn down under an in-flight encode.
fn release_slots(api: &NvApi, encoder: *mut c_void, slots: &mut [EncodeSlot]) {
    unsafe {
        for slot in slots {
            if !slot.mapped.is_null() {
                let _ = WaitForSingleObject(slot.event, ENCODE_WAIT_MS);
                if let Some(unmap) = api.functions.nvEncUnmapInputResource {
                    let _ = unmap(encoder, slot.mapped);
                }
                slot.mapped = ptr::null_mut();
            }
            if !slot.event.is_invalid() {
                let mut event_params: NV_ENC_EVENT_PARAMS = zeroed();
                event_params.version = NV_ENC_EVENT_PARAMS_VER;
                event_params.completionEvent = slot.event.0;
                if let Some(unregister) = api.functions.nvEncUnregisterAsyncEvent {
                    let _ = unregister(encoder, &mut event_params);
                }
            }
            if !slot.bitstream.is_null() {
                if let Some(destroy) = api.functions.nvEncDestroyBitstreamBuffer {
                    let _ = destroy(encoder, slot.bitstream);
                }
            }
            if !slot.registered.is_null() {
                if let Some(unregister) = api.functions.nvEncUnregisterResource {
                    let _ = unregister(encoder, slot.registered);
                }
            }
            if !slot.event.is_invalid() {
                let _ = CloseHandle(slot.event);
            }
        }
    }
}

fn read_worker_output(context: &OutputWorkerContext, pending: PendingOutput) -> Result<AccessUnit> {
    let output = (|| -> Result<AccessUnit> {
        let wait = unsafe { WaitForSingleObject(pending.event, ENCODE_WAIT_MS) };
        if wait != WAIT_OBJECT_0 {
            bail!("timed out waiting for asynchronous NVENC output ({wait:?})");
        }

        let mut lock = MaybeUninit::<NV_ENC_LOCK_BITSTREAM>::uninit();
        unsafe {
            ptr::write_bytes(
                lock.as_mut_ptr().cast::<u8>(),
                0,
                size_of::<NV_ENC_LOCK_BITSTREAM>(),
            );
            ptr::addr_of_mut!((*lock.as_mut_ptr()).version).write(NV_ENC_LOCK_BITSTREAM_VER);
            ptr::addr_of_mut!((*lock.as_mut_ptr()).outputBitstream).write(pending.bitstream);
            (*lock.as_mut_ptr()).set_doNotWait(1);
        }
        let lock_bitstream = context
            .functions
            .nvEncLockBitstream
            .ok_or_else(|| anyhow!("NVIDIA driver does not provide NvEncLockBitstream"))?;
        worker_nv_check(
            context,
            unsafe { lock_bitstream(context.encoder, lock.as_mut_ptr()) },
            "NvEncLockBitstream",
        )?;
        let lock = unsafe { lock.assume_init() };
        let bytes = unsafe {
            std::slice::from_raw_parts(
                lock.bitstreamBufferPtr.cast::<u8>(),
                lock.bitstreamSizeInBytes as usize,
            )
            .to_vec()
        };
        let unlock_bitstream = context
            .functions
            .nvEncUnlockBitstream
            .ok_or_else(|| anyhow!("NVIDIA driver does not provide NvEncUnlockBitstream"))?;
        worker_nv_check(
            context,
            unsafe { unlock_bitstream(context.encoder, pending.bitstream) },
            "NvEncUnlockBitstream",
        )?;

        let mut parser = AnnexBParser::new(context.codec);
        let mut ready = VecDeque::new();
        parser.push(&bytes, &mut ready);
        parser.finish(&mut ready);
        ready
            .pop_front()
            .ok_or_else(|| anyhow!("NVENC returned an empty access unit"))
    })();

    let unmap = context
        .functions
        .nvEncUnmapInputResource
        .ok_or_else(|| anyhow!("NVIDIA driver does not provide NvEncUnmapInputResource"))
        .and_then(|unmap| {
            worker_nv_check(
                context,
                unsafe { unmap(context.encoder, pending.mapped) },
                "NvEncUnmapInputResource",
            )
        });
    match (output, unmap) {
        (Ok(output), Ok(())) => Ok(output),
        (Err(error), _) | (Ok(_), Err(error)) => Err(error),
    }
}

fn worker_nv_check(
    context: &OutputWorkerContext,
    status: NVENCSTATUS,
    operation: &str,
) -> Result<()> {
    nv_check_raw(&context.functions, context.encoder, status, operation)
}

fn nv_check_raw(
    functions: &NV_ENCODE_API_FUNCTION_LIST,
    encoder: *mut c_void,
    status: NVENCSTATUS,
    operation: &str,
) -> Result<()> {
    if status == NVENCSTATUS::NV_ENC_SUCCESS {
        return Ok(());
    }
    let detail = functions
        .nvEncGetLastErrorString
        .and_then(|get_error| {
            let pointer = unsafe { get_error(encoder) };
            (!pointer.is_null()).then(|| unsafe { CStr::from_ptr(pointer) }.to_string_lossy())
        })
        .unwrap_or_default();
    if detail.is_empty() {
        bail!("{operation} failed with {status:?}")
    } else {
        bail!("{operation} failed with {status:?}: {detail}")
    }
}

fn create_capture(
    adapter_idx: u32,
    output_idx: u32,
) -> Result<(
    ID3D11Device,
    ID3D11DeviceContext,
    IDXGIOutputDuplication,
    u32,
    u32,
)> {
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().context("CreateDXGIFactory1")?;
        let adapter = factory
            .EnumAdapters1(adapter_idx)
            .with_context(|| format!("DXGI adapter {adapter_idx}"))?;
        let output = adapter
            .EnumOutputs(output_idx)
            .with_context(|| format!("DXGI adapter {adapter_idx} output {output_idx}"))?;
        let mut device = None;
        let mut context = None;
        D3D11CreateDevice(
            &adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&[D3D_FEATURE_LEVEL_11_0]),
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
        .context("D3D11CreateDevice")?;
        let device = device.ok_or_else(|| anyhow!("D3D11CreateDevice returned no device"))?;
        let context = context.ok_or_else(|| anyhow!("D3D11CreateDevice returned no context"))?;
        // This one device is driven from two threads: the capture loop (frame
        // copy, cursor draw, resource map) and the async NVENC output worker,
        // whose bitstream lock/unlock reaches back into it. The D3D11 immediate
        // context is not thread-safe unless multithread protection is on, and
        // NVIDIA's asynchronous DirectX encode path requires it. Without this,
        // concurrent access can hard-deadlock the GPU scheduler under the load
        // of a fullscreen game's mode switch (no TDR, whole machine wedged).
        if let Ok(mt) = context.cast::<ID3D11Multithread>() {
            let _ = mt.SetMultithreadProtected(BOOL(1));
        } else {
            log::warn!("could not enable D3D11 multithread protection for the capture device");
        }
        // Deliberately leave the capture device at the default GPU queue
        // priority. Raising it to the realtime band (7) starves a fullscreen
        // game's own submissions and could wedge the GPU scheduler hard enough
        // to freeze the whole machine when a game engaged the GPU; the latency
        // it saved was negligible next to that risk.
        let output1: IDXGIOutput1 = output.cast().context("IDXGIOutput1")?;
        let duplication = output1
            .DuplicateOutput(&device)
            .context("IDXGIOutput1::DuplicateOutput")?;
        let dupe_desc = duplication.GetDesc();
        let width = dupe_desc.ModeDesc.Width;
        let height = dupe_desc.ModeDesc.Height;
        if width == 0 || height == 0 {
            bail!("Desktop Duplication reported a zero-sized output");
        }
        Ok((device, context, duplication, width, height))
    }
}

fn create_texture(device: &ID3D11Device, width: u32, height: u32) -> Result<ID3D11Texture2D> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    };
    let mut texture = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut texture)) }
        .context("ID3D11Device::CreateTexture2D")?;
    texture.ok_or_else(|| anyhow!("CreateTexture2D returned no texture"))
}

fn codec_guid(codec: Codec) -> GUID {
    match codec {
        Codec::Hevc => NV_ENC_CODEC_HEVC_GUID,
        Codec::H264 => NV_ENC_CODEC_H264_GUID,
    }
}

fn profile_guid(codec: Codec) -> GUID {
    match codec {
        Codec::Hevc => NV_ENC_HEVC_PROFILE_MAIN_GUID,
        Codec::H264 => NV_ENC_H264_PROFILE_HIGH_GUID,
    }
}

fn nv_check(api: &NvApi, encoder: *mut c_void, status: NVENCSTATUS, operation: &str) -> Result<()> {
    if status == NVENCSTATUS::NV_ENC_SUCCESS {
        return Ok(());
    }
    let detail = if encoder.is_null() {
        String::new()
    } else {
        let Some(get_error) = api.functions.nvEncGetLastErrorString else {
            bail!("{operation} failed with {status:?}");
        };
        let ptr = unsafe { get_error(encoder) };
        if ptr.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned()
        }
    };
    if detail.is_empty() {
        bail!("{operation} failed with {status:?}")
    } else {
        bail!("{operation} failed with {status:?}: {detail}")
    }
}

/// Describe the pixels honestly in the VUI. The input is ARGB and NVENC does
/// the RGB->YUV conversion itself with BT.601 (SMPTE 170M) limited-range
/// coefficients; there is no option to use 709. Without this the stream
/// carries no colour description and every decoder assumes 709, which shows
/// as slightly off saturation. The primaries and transfer are sRGB's, which
/// are BT.709's.
fn signal_colour(vui: &mut NV_ENC_CONFIG_H264_VUI_PARAMETERS) {
    vui.videoSignalTypePresentFlag = 1;
    vui.videoFormat = NV_ENC_VUI_VIDEO_FORMAT::NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
    vui.videoFullRangeFlag = 0;
    vui.colourDescriptionPresentFlag = 1;
    vui.colourPrimaries = NV_ENC_VUI_COLOR_PRIMARIES::NV_ENC_VUI_COLOR_PRIMARIES_BT709;
    vui.transferCharacteristics =
        NV_ENC_VUI_TRANSFER_CHARACTERISTIC::NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
    vui.colourMatrix = NV_ENC_VUI_MATRIX_COEFFS::NV_ENC_VUI_MATRIX_COEFFS_SMPTE170M;
}
