//! A user process for WGC activation when the host is SYSTEM. One RGB10
//! texture crosses the process boundary via an explicitly duplicated NT
//! handle and keyed mutex; desktop pixels never pass through CPU/pipe data.
//! The local pipe accepts only the PID we just launched, before duplicating
//! the texture handle. No identity keys, input or driver privileges cross it.
use super::*;
use std::fs::File;
use std::io::{Read, Write};
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device1, D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX, D3D11_RESOURCE_MISC_SHARED_NTHANDLE,
};
use windows::Win32::Graphics::Dxgi::{IDXGIKeyedMutex, IDXGIResource1};
use windows::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
use windows::Win32::System::Pipes::*;

fn handle(file: &File) -> HANDLE {
    HANDLE(file.as_raw_handle())
}

fn acquire(mutex: &IDXGIKeyedMutex, key: u64) -> Result<bool> {
    // AcquireSync returns WAIT_TIMEOUT as a *successful HRESULT*. The
    // generated Result<()> wrapper loses that distinction, so inspect it.
    let status = unsafe { (Interface::vtable(mutex).AcquireSync)(mutex.as_raw(), key, 0) };
    acquired(status)
}

fn acquired(status: windows::core::HRESULT) -> Result<bool> {
    match status.0 {
        0 => Ok(true),
        258 => Ok(false),
        128 => bail!("shared capture texture abandoned"),
        _ => {
            status.ok()?;
            bail!("unexpected keyed-mutex result {status:?}")
        }
    }
}

const FRAME_TAG: &[u8; 8] = b"RLYSDR01";
const FRAME_LEN: usize = 24;

/// One metadata record per published GPU slot. Each broker has a new pipe,
/// texture and process, so a restart also resets the sequence/generation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FrameStamp {
    sequence: u64,
    present_qpc: i64,
}

impl FrameStamp {
    fn bytes(self) -> [u8; FRAME_LEN] {
        let mut bytes = [0; FRAME_LEN];
        bytes[..8].copy_from_slice(FRAME_TAG);
        bytes[8..16].copy_from_slice(&self.sequence.to_le_bytes());
        bytes[16..24].copy_from_slice(&self.present_qpc.to_le_bytes());
        bytes
    }

    fn parse(bytes: &[u8], previous: Option<Self>) -> Result<Option<Self>> {
        if bytes.first() == Some(&1) {
            bail!(
                "user SDR capture failed: {}",
                String::from_utf8_lossy(&bytes[1..])
            );
        }
        let prefix = bytes.len().min(FRAME_TAG.len());
        anyhow::ensure!(
            bytes[..prefix] == FRAME_TAG[..prefix],
            "invalid capture frame tag"
        );
        if bytes.len() < FRAME_LEN {
            return Ok(None);
        }
        let stamp = Self {
            sequence: u64::from_le_bytes(bytes[8..16].try_into()?),
            present_qpc: i64::from_le_bytes(bytes[16..24].try_into()?),
        };
        let expected = previous.map_or(Some(1), |p| p.sequence.checked_add(1));
        anyhow::ensure!(
            Some(stamp.sequence) == expected,
            "capture frame sequence mismatch"
        );
        anyhow::ensure!(stamp.present_qpc > 0, "invalid capture frame timestamp");
        anyhow::ensure!(
            previous.is_none_or(|p| stamp.present_qpc >= p.present_qpc),
            "capture frame timestamp went backwards"
        );
        Ok(Some(stamp))
    }
}

pub(super) struct Broker {
    pipe: File,
    process: crate::service::Process,
    texture: ID3D11Texture2D,
    mutex: IDXGIKeyedMutex,
    previous: Option<FrameStamp>,
    diagnostics: Option<Reporter>,
}

impl Broker {
    pub(super) fn new(
        device: &ID3D11Device,
        display: &str,
        width: u32,
        height: u32,
    ) -> Result<Self> {
        let pipe_name = format!(
            r"\\.\pipe\Relay.Sdr.{}.{:032x}",
            std::process::id(),
            rand::random::<u128>()
        );
        let name: Vec<u16> = pipe_name.encode_utf16().chain(Some(0)).collect();
        let sddl: Vec<u16> = "D:P(A;;GA;;;SY)(A;;GRGW;;;AU)"
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let mut sd = PSECURITY_DESCRIPTOR::default();
        // Authenticated users may connect, but the kernel-reported PID must
        // match our child. Remote clients are rejected by the kernel.
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                PCWSTR(sddl.as_ptr()),
                SDDL_REVISION_1,
                &mut sd,
                None,
            )
        }?;
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: BOOL(0),
        };
        let raw = unsafe {
            CreateNamedPipeW(
                PCWSTR(name.as_ptr()),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                4096,
                4096,
                0,
                Some(&attributes),
            )
        };
        unsafe {
            let _ = windows::Win32::Foundation::LocalFree(windows::Win32::Foundation::HLOCAL(sd.0));
        }
        if raw.is_invalid() {
            return Err(windows::core::Error::from_win32()).context("creating local capture pipe");
        }
        let pipe = unsafe { File::from_raw_handle(raw.0) };
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R10G10B10A2_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
            MiscFlags: (D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX)
                .0 as u32,
            ..Default::default()
        };
        let mut texture = None;
        unsafe { device.CreateTexture2D(&desc, None, Some(&mut texture)) }?;
        let texture = texture.context("shared RGB10 capture texture")?;
        let resource: IDXGIResource1 = texture.cast()?;
        let shared = unsafe { resource.CreateSharedHandle(None, 0x80000001, PCWSTR::null()) }?;
        // DXGI_SHARED_RESOURCE_READ | WRITE = 0x80000000 | 1.
        let mut args = vec![
            "capture-source".into(),
            "--pipe".into(),
            pipe_name,
            "--display".into(),
            display.into(),
            "--width".into(),
            width.to_string(),
            "--height".into(),
            height.to_string(),
        ];
        if crate::source_timing::enabled() {
            args.push("--source-timing-diagnostics".into());
        }
        let process = crate::service::spawn_capture_user(&args);
        let result = (|| -> Result<Self> {
            let process = process?;
            let mutex = texture.cast()?;
            let mut broker = Self {
                pipe,
                process,
                texture,
                mutex,
                previous: None,
                diagnostics: Reporter::new("broker"),
            };
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let connected = unsafe { ConnectNamedPipe(handle(&broker.pipe), None) };
                if connected.is_ok()
                    || connected.as_ref().is_err_and(|e| {
                        e.code() == windows::Win32::Foundation::ERROR_PIPE_CONNECTED.to_hresult()
                    })
                {
                    break;
                }
                anyhow::ensure!(
                    broker.process.exit_code().is_none(),
                    "capture user process exited before connection"
                );
                anyhow::ensure!(
                    Instant::now() < deadline,
                    "capture user process connection timed out"
                );
                thread::sleep(Duration::from_millis(10));
            }
            let mut pid = 0;
            unsafe { GetNamedPipeClientProcessId(handle(&broker.pipe), &mut pid) }?;
            anyhow::ensure!(
                pid == broker.process.pid,
                "capture pipe client PID did not match our user process"
            );
            let remote = broker.process.duplicate_handle_into(shared)?;
            broker.pipe.write_all(&(remote.0 as u64).to_le_bytes())?;
            loop {
                let mut available = 0;
                unsafe {
                    PeekNamedPipe(
                        handle(&broker.pipe),
                        None,
                        0,
                        None,
                        Some(&mut available),
                        None,
                    )
                }?;
                if available > 0 {
                    let mut status = [0];
                    broker.pipe.read_exact(&mut status)?;
                    if status[0] != 0 {
                        let mut bytes = [0; 1024];
                        let n = broker.pipe.read(&mut bytes).unwrap_or(0);
                        bail!(
                            "user SDR capture refused: {}",
                            String::from_utf8_lossy(&bytes[..n])
                        );
                    }
                    break;
                }
                anyhow::ensure!(
                    broker.process.exit_code().is_none(),
                    "capture user process exited during startup"
                );
                anyhow::ensure!(
                    Instant::now() < deadline,
                    "capture user process startup timed out"
                );
                thread::sleep(Duration::from_millis(10));
            }
            log::info!("SDR source: signed-in-user WGC FP16 desktop + cursor -> GPU RGB10 shared texture (PID {}); host retains NVENC/input/topology",broker.process.pid);
            Ok(broker)
        })();
        unsafe {
            let _ = CloseHandle(shared);
        }
        result
    }

    pub(super) fn copy_latest(
        &mut self,
        context: &ID3D11DeviceContext,
        target: &ID3D11Texture2D,
    ) -> Result<Option<i64>> {
        anyhow::ensure!(
            self.process.exit_code().is_none(),
            "user SDR capture source exited"
        );
        // Peek without consuming: metadata is written before key 1 is
        // published. Neither a partial pipe record nor an unfinished GPU
        // conversion may block this capture thread or advance the sequence.
        let mut bytes = [0; FRAME_LEN];
        let mut count = 0;
        unsafe {
            PeekNamedPipe(
                handle(&self.pipe),
                Some(bytes.as_mut_ptr().cast()),
                FRAME_LEN as u32,
                Some(&mut count),
                None,
                None,
            )
        }?;
        let parsed = FrameStamp::parse(&bytes[..count as usize], self.previous);
        if parsed.is_err() {
            let candidate =
                (count as usize >= FRAME_LEN && bytes[..8] == *FRAME_TAG).then(|| FrameStamp {
                    sequence: u64::from_le_bytes(bytes[8..16].try_into().expect("full record")),
                    present_qpc: i64::from_le_bytes(bytes[16..24].try_into().expect("full record")),
                });
            let reason = match candidate {
                Some(stamp) if stamp.present_qpc <= 0 => Reason::Invalid,
                Some(stamp)
                    if self
                        .previous
                        .is_some_and(|p| stamp.present_qpc < p.present_qpc) =>
                {
                    Reason::Backwards
                }
                _ => Reason::Rejected,
            };
            self.observe(reason, candidate);
        }
        let Some(stamp) = parsed? else {
            self.observe(
                if count == 0 {
                    Reason::Empty
                } else {
                    Reason::Partial
                },
                None,
            );
            return Ok(None);
        };
        if !acquire(&self.mutex, 1)? {
            self.observe(Reason::Busy, Some(stamp));
            return Ok(None);
        }
        // Only this thread reads the pipe; the full record was available
        // above. Hold ownership until both its metadata and pixels are taken.
        let copied = (|| -> Result<()> {
            self.pipe.read_exact(&mut bytes)?;
            unsafe { context.CopyResource(target, &self.texture) };
            Ok(())
        })();
        unsafe {
            self.mutex.ReleaseSync(0)?;
        }
        copied?;
        self.previous = Some(stamp);
        // Recording occurs only after releasing the shared GPU slot.
        self.observe(Reason::Published, Some(stamp));
        Ok(Some(stamp.present_qpc))
    }
    pub(super) fn last_sequence(&self) -> Option<u64> {
        self.previous.map(|stamp| stamp.sequence)
    }
    fn observe(&mut self, reason: Reason, stamp: Option<FrameStamp>) {
        if let Some(reporter) = &mut self.diagnostics {
            reporter.record(Sample::capture(
                reason,
                Trace {
                    helper_sequence: stamp.map(|s| s.sequence),
                    source_qpc: stamp.map(|s| s.present_qpc),
                    ..Trace::default()
                },
            ));
        }
    }
}
impl Drop for Broker {
    fn drop(&mut self) {
        self.process.kill();
        let _ = self.process.wait(Duration::from_millis(500));
    }
}

/// Hidden same-binary user helper. Its only inherited authority is its own
/// desktop and one RGB10 texture duplicated into it after PID authentication.
pub fn run(pipe_name: &str, display: &str, width: u32, height: u32) -> Result<()> {
    anyhow::ensure!(
        !sdr_capture::is_system()?,
        "capture-source must run as the signed-in user"
    );
    let _apartment = Apartment::new()?;
    let mut pipe = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe_name)?;
    let result = (|| -> Result<()> {
        let mut bytes = [0; 8];
        pipe.read_exact(&mut bytes)?;
        let shared = HANDLE(u64::from_le_bytes(bytes) as usize as *mut c_void);
        let location = crate::display::dxgi_output_for(display)?;
        let device = create_device_for(location.adapter_luid)?;
        let context = unsafe { device.GetImmediateContext() }?;
        unsafe {
            let _ = context
                .cast::<ID3D11Multithread>()?
                .SetMultithreadProtected(BOOL(1));
        }
        let device1: ID3D11Device1 = device.cast()?;
        let texture: ID3D11Texture2D = unsafe { device1.OpenSharedResource1(shared) }?;
        unsafe {
            let _ = CloseHandle(shared);
        }
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe {
            texture.GetDesc(&mut desc);
        }
        anyhow::ensure!(
            desc.Format == DXGI_FORMAT_R10G10B10A2_UNORM
                && desc.Width == width
                && desc.Height == height,
            "shared RGB10 descriptor mismatch"
        );
        let mutex: IDXGIKeyedMutex = texture.cast()?;
        let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }?;
        let monitor = unsafe {
            factory
                .EnumAdapters1(location.adapter_index)?
                .EnumOutputs(location.output_index)?
                .GetDesc()?
                .Monitor
        };
        let capture = SdrCapture::new(&device, monitor, width, height)?;
        let converter = SdrConverter::new(&device, &texture, width, height)?;
        pipe.write_all(&[0])?;
        let desktop = crate::desktop::input_desktop_name();
        raise_thread_priority("sdr-user-capture");
        let sleeper = HighResSleeper::new();
        let mut sequence = 0u64;
        let mut diagnostics = Reporter::new("wgc-helper");
        loop {
            if crate::desktop::input_desktop_name() != desktop {
                bail!("capture desktop changed");
            }
            unsafe { PeekNamedPipe(handle(&pipe), None, 0, None, None, None) }?;
            if let Some(frame) = capture.latest()? {
                let timing = frame.timing(crate::clock::qpc_frequency());
                if timing.is_err() {
                    if let Some(reporter) = &mut diagnostics {
                        reporter.record(Sample::capture(Reason::Invalid, Trace::default()));
                    }
                }
                let (raw_100ns, present_qpc) = timing?;
                let stamp = FrameStamp {
                    sequence: sequence
                        .checked_add(1)
                        .context("capture sequence exhausted")?,
                    present_qpc,
                };
                let trace = diagnostics.as_ref().map(|_| Trace {
                    helper_sequence: Some(stamp.sequence),
                    raw_100ns: Some(raw_100ns),
                    source_qpc: Some(present_qpc),
                    acquired_us: Some(crate::clock::now_us()),
                    fresh: true,
                    ..Trace::default()
                });
                if acquire(&mutex, 0)? {
                    let published = (|| -> Result<()> {
                        converter.convert(&context, &frame.texture()?)?;
                        pipe.write_all(&stamp.bytes())?;
                        // Metadata precedes publication; one slot limits the
                        // pipe to one in-flight frame record. Never publish
                        // pixels or a timestamp after a failed conversion.
                        unsafe { mutex.ReleaseSync(1) }?;
                        Ok(())
                    })();
                    if published.is_err() {
                        let _ = unsafe { mutex.ReleaseSync(0) };
                    }
                    published?;
                    sequence = stamp.sequence;
                    if let (Some(reporter), Some(trace)) = (&mut diagnostics, trace) {
                        reporter.record(Sample::capture(Reason::Published, trace));
                    }
                } else if let (Some(reporter), Some(trace)) = (&mut diagnostics, trace) {
                    reporter.record(Sample::capture(Reason::Busy, trace));
                }
            } else if let Some(reporter) = &mut diagnostics {
                reporter.record(Sample::capture(Reason::Empty, Trace::default()));
            }
            sleeper.sleep(Duration::from_micros(200));
        }
    })();
    if let Err(e) = &result {
        let _ = pipe.write_all(&[1]);
        let text = format!("{e:#}");
        let _ = pipe.write_all(&text.as_bytes()[..text.len().min(1024)]);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keyed_mutex_timeout_is_not_successful_ownership() {
        assert!(acquired(windows::core::HRESULT(0)).unwrap());
        assert!(!acquired(windows::core::HRESULT(258)).unwrap());
        assert!(acquired(windows::core::HRESULT(128)).is_err());
        assert!(acquired(windows::Win32::Foundation::E_FAIL).is_err());
    }

    #[test]
    fn frame_metadata_waits_for_the_whole_record_and_preserves_the_source_clock() {
        let stamp = FrameStamp {
            sequence: 1,
            present_qpc: 123_456_789,
        };
        let bytes = stamp.bytes();
        for length in 0..FRAME_LEN {
            assert_eq!(FrameStamp::parse(&bytes[..length], None).unwrap(), None);
        }
        assert_eq!(FrameStamp::parse(&bytes, None).unwrap(), Some(stamp));
        let next = FrameStamp {
            sequence: 2,
            present_qpc: stamp.present_qpc + 1,
        };
        assert_eq!(
            FrameStamp::parse(&next.bytes(), Some(stamp)).unwrap(),
            Some(next)
        );
        // A new helper cannot inherit records from a retired broker.
        assert!(FrameStamp::parse(&next.bytes(), None).is_err());
    }

    #[test]
    fn frame_metadata_rejects_mismatches_errors_and_invalid_clocks() {
        let previous = FrameStamp {
            sequence: 1,
            present_qpc: 100,
        };
        for stamp in [
            previous,
            FrameStamp {
                sequence: 3,
                present_qpc: 110,
            },
            FrameStamp {
                sequence: 2,
                present_qpc: 99,
            },
            FrameStamp {
                sequence: 2,
                present_qpc: 0,
            },
            FrameStamp {
                sequence: 2,
                present_qpc: -1,
            },
        ] {
            assert!(FrameStamp::parse(&stamp.bytes(), Some(previous)).is_err());
        }
        assert!(FrameStamp::parse(b"\x01conversion failed", Some(previous)).is_err());
        let mut corrupt = previous.bytes();
        corrupt[0] = b'X';
        assert!(FrameStamp::parse(&corrupt, None).is_err());
    }
}
