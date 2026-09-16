//! In-process Desktop Duplication -> D3D11 -> NVENC path for NVIDIA GPUs.
//!
//! The captured desktop and the encoder input stay in video memory. Desktop
//! Duplication's pointer shape is blended with a four-vertex D3D11 overlay.

use std::collections::VecDeque;
use std::ffi::{c_void, CStr};
use std::mem::{size_of, zeroed, MaybeUninit};
use std::ptr;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::nvenc_bindings::nv_encode_api::*;
use crate::nvenc_bindings::NvApi;
use anyhow::{anyhow, bail, Context, Result};
use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, BOOL, HANDLE, HMODULE, WAIT_OBJECT_0};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
    D3D11_BIND_RENDER_TARGET, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIFactory1, IDXGIOutput1, IDXGIOutputDuplication,
    IDXGIResource, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
};
use windows::Win32::System::Threading::{
    CreateEventW, CreateWaitableTimerExW, SetWaitableTimerEx, WaitForSingleObject,
    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS,
};

use crate::cursor_overlay::CursorOverlay;
use crate::encoder::{AccessUnit, AnnexBParser, EncoderConfig, Quality};
use crate::protocol::Codec;

pub struct NativeNvenc {
    api: NvApi,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    duplication: IDXGIOutputDuplication,
    composition_texture: ID3D11Texture2D,
    cursor: CursorOverlay,
    width: u32,
    height: u32,
    fps: u32,
    codec: Codec,
    encoder: *mut c_void,
    slots: Vec<EncodeSlot>,
    worker_tx: Option<Sender<PendingOutput>>,
    worker_rx: Option<Receiver<CompletedOutput>>,
    worker: Option<JoinHandle<()>>,
    frame_idx: u32,
    have_frame: bool,
    frame_interval: Duration,
    next_frame_at: Instant,
    pacer: FramePacer,
}

const PIPELINE_DEPTH: usize = 2;
const ENCODE_WAIT_MS: u32 = 2_000;

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
}

// NVENC's Windows asynchronous API explicitly permits output processing on a
// second thread. These handles remain valid until that thread is joined.
unsafe impl Send for PendingOutput {}

struct CompletedOutput {
    slot_index: usize,
    result: Result<AccessUnit>,
}

struct OutputWorkerContext {
    functions: NV_ENCODE_API_FUNCTION_LIST,
    encoder: *mut c_void,
    codec: Codec,
}

unsafe impl Send for OutputWorkerContext {}

struct FramePacer {
    timer: Option<HANDLE>,
}

impl FramePacer {
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
            Ok(timer) => {
                log::info!("120 Hz pacer using a high-resolution Windows timer");
                Self { timer: Some(timer) }
            }
            Err(error) => {
                log::warn!("high-resolution frame timer unavailable ({error}); using thread sleep");
                Self { timer: None }
            }
        }
    }

    fn sleep_until(&self, deadline: Instant) {
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return;
            }
            let Some(timer) = self.timer else {
                std::thread::sleep(remaining);
                return;
            };
            // Negative 100 ns units request a relative due time. Round up so
            // the wait never intentionally fires before the frame deadline.
            let ticks = remaining.as_nanos().div_ceil(100).min(i64::MAX as u128) as i64;
            let due_time = -ticks.max(1);
            if unsafe { SetWaitableTimerEx(timer, &due_time, 0, None, None, None, 0) }.is_err()
                || unsafe { WaitForSingleObject(timer, 1_000) } != WAIT_OBJECT_0
            {
                std::thread::sleep(remaining);
                return;
            }
        }
    }
}

impl Drop for FramePacer {
    fn drop(&mut self) {
        if let Some(timer) = self.timer.take() {
            unsafe {
                let _ = CloseHandle(timer);
            }
        }
    }
}

impl NativeNvenc {
    pub fn spawn(cfg: &EncoderConfig) -> Result<Self> {
        if cfg.cross_adapter() {
            bail!("native NVENC requires capture and encode on the same DXGI adapter");
        }

        let api = NvApi::load()?;
        let (device, context, duplication, width, height) =
            create_capture(cfg.capture_adapter_idx, cfg.output_idx)?;
        let composition_texture = create_texture(&device, width, height)?;
        let cursor = CursorOverlay::new(&device, &composition_texture, width, height)?;

        let mut native = NativeNvenc {
            api,
            device,
            context,
            duplication,
            composition_texture,
            cursor,
            width,
            height,
            fps: cfg.fps.max(1),
            codec: cfg.codec,
            encoder: ptr::null_mut(),
            slots: Vec::with_capacity(PIPELINE_DEPTH),
            worker_tx: None,
            worker_rx: None,
            worker: None,
            frame_idx: 0,
            have_frame: false,
            frame_interval: Duration::from_secs_f64(1.0 / f64::from(cfg.fps.max(1))),
            next_frame_at: Instant::now(),
            pacer: FramePacer::new(),
        };
        native.initialize_encoder(cfg)?;
        native.start_output_worker()?;
        Ok(native)
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

    fn start_output_worker(&mut self) -> Result<()> {
        let (pending_tx, pending_rx) = mpsc::channel();
        let (completed_tx, completed_rx) = mpsc::channel();
        let context = OutputWorkerContext {
            functions: self.api.functions,
            encoder: self.encoder,
            codec: self.codec,
        };
        let worker = thread::Builder::new()
            .name("nvenc-output".into())
            .spawn(move || output_worker(context, pending_rx, completed_tx))
            .context("starting NVENC output worker")?;
        self.worker_tx = Some(pending_tx);
        self.worker_rx = Some(completed_rx);
        self.worker = Some(worker);
        Ok(())
    }

    /// Submit on the display cadence while a second thread waits for NVENC.
    /// Completed pictures are returned immediately; a second picture is queued
    /// only when the previous encode genuinely takes longer than one tick.
    /// `None` asks the server to recreate capture after a fullscreen/mode change.
    pub fn next_access_unit(&mut self) -> Result<Option<AccessUnit>> {
        loop {
            if let Some(completed) = self.try_completed()? {
                return completed.result.map(Some);
            }

            let now = Instant::now();
            let free_slot = self.slots.iter().position(|slot| slot.mapped.is_null());
            if let Some(slot_index) = free_slot {
                if !self.have_frame || now >= self.next_frame_at {
                    if !self.capture_and_submit(slot_index)? {
                        return Ok(None);
                    }
                    continue;
                }
            }

            if self.slots.iter().all(|slot| slot.mapped.is_null()) {
                self.pacer.sleep_until(self.next_frame_at);
                continue;
            }

            let pipeline_full = free_slot.is_none();
            let timeout = if !pipeline_full {
                self.next_frame_at.saturating_duration_since(now)
            } else {
                Duration::from_secs(2)
            };
            if let Some(completed) = self.wait_completed(timeout)? {
                return completed.result.map(Some);
            }
            if pipeline_full {
                bail!("timed out waiting for the NVENC output worker");
            }
            // The next capture deadline won the race; loop and submit it.
        }
    }

    fn try_completed(&mut self) -> Result<Option<CompletedOutput>> {
        let result = self
            .worker_rx
            .as_ref()
            .ok_or_else(|| anyhow!("NVENC output worker is not running"))?
            .try_recv();
        match result {
            Ok(completed) => {
                self.slots[completed.slot_index].mapped = ptr::null_mut();
                Ok(Some(completed))
            }
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => bail!("NVENC output worker stopped"),
        }
    }

    fn wait_completed(&mut self, timeout: Duration) -> Result<Option<CompletedOutput>> {
        if timeout.is_zero() {
            return Ok(None);
        }
        let result = self
            .worker_rx
            .as_ref()
            .ok_or_else(|| anyhow!("NVENC output worker is not running"))?
            .recv_timeout(timeout);
        match result {
            Ok(completed) => {
                self.slots[completed.slot_index].mapped = ptr::null_mut();
                Ok(Some(completed))
            }
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => bail!("NVENC output worker stopped"),
        }
    }

    fn capture_and_submit(&mut self, slot_index: usize) -> Result<bool> {
        let timeout_ms = if self.have_frame { 0 } else { 100 };
        let captured = loop {
            let mut info: DXGI_OUTDUPL_FRAME_INFO = unsafe { zeroed() };
            let mut resource: Option<IDXGIResource> = None;
            match unsafe {
                self.duplication
                    .AcquireNextFrame(timeout_ms, &mut info, &mut resource)
            } {
                Ok(()) => break Some((resource, info)),
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {
                    if self.have_frame {
                        break None;
                    }
                }
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                    log::warn!("Desktop Duplication access lost; recreating native capture");
                    return Ok(false);
                }
                Err(e) => return Err(e).context("IDXGIOutputDuplication::AcquireNextFrame"),
            }
        };

        if let Some((resource, frame_info)) = captured {
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
                self.cursor.update(&self.duplication, &frame_info)?;
                Ok(())
            })();

            let release = unsafe { self.duplication.ReleaseFrame() };
            if let Err(e) = release {
                log::warn!("Desktop Duplication ReleaseFrame failed: {e}");
            }
            copied?;

            self.cursor.draw(&self.context);
            self.have_frame = true;
        }

        unsafe {
            self.context
                .CopyResource(&self.slots[slot_index].texture, &self.composition_texture);
        }
        let first = self.frame_idx == 0;
        self.submit(slot_index)?;

        let now = Instant::now();
        if first {
            self.next_frame_at = now + self.frame_interval;
        } else {
            self.next_frame_at += self.frame_interval;
            if self.next_frame_at <= now {
                self.next_frame_at = now;
            }
        }
        Ok(true)
    }

    fn submit(&mut self, slot_index: usize) -> Result<()> {
        let registered = self.slots[slot_index].registered;
        let bitstream = self.slots[slot_index].bitstream;
        let completion_event = self.slots[slot_index].event.0;
        let mut map: NV_ENC_MAP_INPUT_RESOURCE = unsafe { zeroed() };
        map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        map.registeredResource = registered;
        let map_input = self.api.required(
            self.api.functions.nvEncMapInputResource,
            "NvEncMapInputResource",
        )?;
        nv_check(
            &self.api,
            self.encoder,
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
                .api
                .required(self.api.functions.nvEncEncodePicture, "NvEncEncodePicture")?;
            let status = unsafe { encode_picture(self.encoder, pic.as_mut_ptr()) };
            if status == NVENCSTATUS::NV_ENC_SUCCESS
                || status == NVENCSTATUS::NV_ENC_ERR_NEED_MORE_INPUT
            {
                Ok(())
            } else {
                nv_check(&self.api, self.encoder, status, "NvEncEncodePicture")
            }
        })();

        if let Err(error) = result {
            self.unmap(map.mappedResource)?;
            return Err(error);
        }
        self.slots[slot_index].mapped = map.mappedResource;
        let pending = PendingOutput {
            slot_index,
            mapped: map.mappedResource,
            bitstream,
            event: self.slots[slot_index].event,
        };
        if self
            .worker_tx
            .as_ref()
            .ok_or_else(|| anyhow!("NVENC output worker is not running"))?
            .send(pending)
            .is_err()
        {
            self.unmap(map.mappedResource)?;
            self.slots[slot_index].mapped = ptr::null_mut();
            bail!("NVENC output worker stopped");
        }
        self.frame_idx = self.frame_idx.wrapping_add(1);
        Ok(())
    }

    fn unmap(&self, mapped: NV_ENC_INPUT_PTR) -> Result<()> {
        let unmap_input = self.api.required(
            self.api.functions.nvEncUnmapInputResource,
            "NvEncUnmapInputResource",
        )?;
        nv_check(
            &self.api,
            self.encoder,
            unsafe { unmap_input(self.encoder, mapped) },
            "NvEncUnmapInputResource",
        )
    }
}

fn output_worker(
    context: OutputWorkerContext,
    pending_rx: Receiver<PendingOutput>,
    completed_tx: Sender<CompletedOutput>,
) {
    while let Ok(pending) = pending_rx.recv() {
        let slot_index = pending.slot_index;
        let result = read_worker_output(&context, pending);
        if completed_tx
            .send(CompletedOutput { slot_index, result })
            .is_err()
        {
            break;
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
    if status == NVENCSTATUS::NV_ENC_SUCCESS {
        return Ok(());
    }
    let detail = context
        .functions
        .nvEncGetLastErrorString
        .and_then(|get_error| {
            let pointer = unsafe { get_error(context.encoder) };
            (!pointer.is_null()).then(|| unsafe { CStr::from_ptr(pointer) }.to_string_lossy())
        })
        .unwrap_or_default();
    if detail.is_empty() {
        bail!("{operation} failed with {status:?}")
    } else {
        bail!("{operation} failed with {status:?}: {detail}")
    }
}

impl Drop for NativeNvenc {
    fn drop(&mut self) {
        self.worker_tx.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        if let Some(completed) = self.worker_rx.take() {
            while let Ok(output) = completed.try_recv() {
                self.slots[output.slot_index].mapped = ptr::null_mut();
            }
        }

        unsafe {
            for slot in &mut self.slots {
                if !slot.mapped.is_null() {
                    let _ = WaitForSingleObject(slot.event, ENCODE_WAIT_MS);
                    if let Some(unmap) = self.api.functions.nvEncUnmapInputResource {
                        let _ = unmap(self.encoder, slot.mapped);
                    }
                    slot.mapped = ptr::null_mut();
                }
                if !slot.event.is_invalid() {
                    let mut event_params: NV_ENC_EVENT_PARAMS = zeroed();
                    event_params.version = NV_ENC_EVENT_PARAMS_VER;
                    event_params.completionEvent = slot.event.0;
                    if let Some(unregister) = self.api.functions.nvEncUnregisterAsyncEvent {
                        let _ = unregister(self.encoder, &mut event_params);
                    }
                }
                if !slot.bitstream.is_null() {
                    if let Some(destroy) = self.api.functions.nvEncDestroyBitstreamBuffer {
                        let _ = destroy(self.encoder, slot.bitstream);
                    }
                }
                if !slot.registered.is_null() {
                    if let Some(unregister) = self.api.functions.nvEncUnregisterResource {
                        let _ = unregister(self.encoder, slot.registered);
                    }
                }
                if !slot.event.is_invalid() {
                    let _ = CloseHandle(slot.event);
                }
            }
            if !self.encoder.is_null() {
                if let Some(f) = self.api.functions.nvEncDestroyEncoder {
                    let _ = f(self.encoder);
                }
            }
        }
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
