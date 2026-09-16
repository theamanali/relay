//! parsec-vdd backend: control of the Parsec Virtual Display Driver over IOCTLs.
//!
//! The driver is a signed IddCx driver that exposes a device interface; we talk
//! to it with four IOCTLs. Displays exist only while somebody keeps pinging
//! `update()` (the driver unplugs everything after ~1 s of silence), which is
//! exactly the lifecycle we want: the monitor lives as long as this process and
//! the client connection do.
//!
//! Constants and call shapes mirror `core/parsec-vdd.h` from
//! <https://github.com/nomi-san/parsec-vdd>. Limits: the render GPU is whatever
//! Windows picks, and only the modes in `HKLM\SOFTWARE\Parsec\vdd` (5 max) exist.

use std::ffi::c_void;
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use windows::core::{GUID, PCWSTR};
use windows::Win32::Devices::DeviceAndDriverInstallation::{
    SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInterfaces, SetupDiGetClassDevsW,
    SetupDiGetDeviceInterfaceDetailW, DIGCF_DEVICEINTERFACE, DIGCF_PRESENT,
    SP_DEVICE_INTERFACE_DATA, SP_DEVICE_INTERFACE_DETAIL_DATA_W,
};
use windows::Win32::Foundation::{
    CloseHandle, BOOL, ERROR_IO_PENDING, GENERIC_READ, GENERIC_WRITE, HANDLE, HWND,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_NO_BUFFERING, FILE_FLAG_OVERLAPPED,
    FILE_FLAG_WRITE_THROUGH, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows::Win32::System::Threading::CreateEventW;
use windows::Win32::System::IO::{DeviceIoControl, GetOverlappedResultEx, OVERLAPPED};

/// Device interface GUID the driver registers (also the adapter GUID).
pub const ADAPTER_GUID: GUID = GUID::from_values(
    0x00b41627,
    0x04c4,
    0x429e,
    [0xa2, 0x6e, 0x02, 0x65, 0xcf, 0x50, 0xc8, 0xfa],
);
/// Setup class GUID for "Display" adapters (used by the driver installer).
#[allow(dead_code)]
pub const CLASS_GUID: GUID = GUID::from_values(
    0x4d36e968,
    0xe325,
    0x11ce,
    [0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18],
);
#[allow(dead_code)]
pub const HARDWARE_ID: &str = "Root\\Parsec\\VDA";
/// PnP monitor ID that shows up in `DISPLAY_DEVICE.DeviceID` for VDD monitors.
pub const MONITOR_PNP_ID: &str = "PSCCDD0";
#[allow(dead_code)]
pub const MAX_DISPLAYS: u32 = 8;

const IOCTL_ADD: u32 = 0x0022e004;
const IOCTL_REMOVE: u32 = 0x0022a008;
const IOCTL_UPDATE: u32 = 0x0022a00c;
const IOCTL_VERSION: u32 = 0x0022e010;

/// The driver drops displays after ~1000 ms without an UPDATE; parsec's own
/// tray app pings every 100 ms. We go a little faster to survive scheduling hiccups.
const KEEPALIVE_INTERVAL: Duration = Duration::from_millis(50);

pub struct Vdd {
    handle: HANDLE,
}

// HANDLE is a plain integer; the driver accepts concurrent overlapped IOCTLs on
// the same handle (each call brings its own OVERLAPPED + event).
unsafe impl Send for Vdd {}
unsafe impl Sync for Vdd {}

impl Vdd {
    /// Find the driver's device interface and open it.
    pub fn open() -> Result<Self> {
        unsafe {
            let devinfo = SetupDiGetClassDevsW(
                Some(&ADAPTER_GUID),
                PCWSTR::null(),
                HWND::default(),
                DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
            )
            .context("SetupDiGetClassDevsW")?;

            let mut result: Result<Self> = Err(anyhow!(
                "Parsec Virtual Display Driver not found (tools/install-host.ps1 -Driver parsec installs it)"
            ));
            let mut index = 0u32;
            loop {
                let mut ifdata = SP_DEVICE_INTERFACE_DATA {
                    cbSize: size_of::<SP_DEVICE_INTERFACE_DATA>() as u32,
                    ..Default::default()
                };
                if SetupDiEnumDeviceInterfaces(devinfo, None, &ADAPTER_GUID, index, &mut ifdata)
                    .is_err()
                {
                    break;
                }
                index += 1;

                let mut required = 0u32;
                let _ = SetupDiGetDeviceInterfaceDetailW(
                    devinfo,
                    &ifdata,
                    None,
                    0,
                    Some(&mut required),
                    None,
                );
                if required == 0 {
                    continue;
                }
                // Variable-length struct: allocate the requested size and set cbSize
                // to the fixed header size (that is what SetupAPI checks).
                let mut buf = vec![0u8; required as usize];
                let detail = buf.as_mut_ptr() as *mut SP_DEVICE_INTERFACE_DETAIL_DATA_W;
                (*detail).cbSize = size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
                if SetupDiGetDeviceInterfaceDetailW(
                    devinfo,
                    &ifdata,
                    Some(detail),
                    required,
                    None,
                    None,
                )
                .is_err()
                {
                    continue;
                }
                let path = PCWSTR::from_raw((*detail).DevicePath.as_ptr());

                match CreateFileW(
                    path,
                    (GENERIC_READ | GENERIC_WRITE).0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    None,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL
                        | FILE_FLAG_NO_BUFFERING
                        | FILE_FLAG_OVERLAPPED
                        | FILE_FLAG_WRITE_THROUGH,
                    HANDLE::default(),
                ) {
                    Ok(h) if !h.is_invalid() => {
                        result = Ok(Vdd { handle: h });
                        break;
                    }
                    Ok(_) => continue,
                    Err(e) => {
                        result = Err(anyhow!(e).context("CreateFileW on VDD device interface"));
                        continue;
                    }
                }
            }
            let _ = SetupDiDestroyDeviceInfoList(devinfo);
            result
        }
    }

    fn ioctl(&self, code: u32, input: &[u8]) -> Result<u32> {
        unsafe {
            let mut inbuf = [0u8; 32];
            let n = input.len().min(inbuf.len());
            inbuf[..n].copy_from_slice(&input[..n]);
            let mut outbuf = [0u8; 32];

            let mut overlapped = OVERLAPPED {
                hEvent: CreateEventW(None, BOOL::from(true), BOOL::from(false), PCWSTR::null())
                    .context("CreateEventW")?,
                ..Default::default()
            };

            let mut returned = 0u32;
            let issued = DeviceIoControl(
                self.handle,
                code,
                Some(inbuf.as_ptr() as *const c_void),
                inbuf.len() as u32,
                Some(outbuf.as_mut_ptr() as *mut c_void),
                outbuf.len() as u32,
                Some(&mut returned),
                Some(&mut overlapped),
            );
            if let Err(e) = issued {
                if e.code() != ERROR_IO_PENDING.to_hresult() {
                    let _ = CloseHandle(overlapped.hEvent);
                    return Err(anyhow!(e).context(format!("DeviceIoControl 0x{code:08x}")));
                }
            }

            let mut transferred = 0u32;
            let waited = GetOverlappedResultEx(
                self.handle,
                &overlapped,
                &mut transferred,
                5000,
                BOOL::from(false),
            );
            let _ = CloseHandle(overlapped.hEvent);
            waited.context(format!("VDD ioctl 0x{code:08x} did not complete"))?;

            Ok(u32::from_le_bytes([
                outbuf[0], outbuf[1], outbuf[2], outbuf[3],
            ]))
        }
    }

    /// Driver minor version (e.g. 45 for parsec-vdd 0.45).
    pub fn version(&self) -> Result<u32> {
        self.ioctl(IOCTL_VERSION, &[])
    }

    /// Keep-alive ping. Must be called at least every ~100 ms while displays exist.
    pub fn update(&self) -> Result<()> {
        self.ioctl(IOCTL_UPDATE, &[]).map(|_| ())
    }

    /// Plug in a new virtual monitor; returns its index (0..16).
    pub fn add_display(&self) -> Result<u32> {
        let index = self.ioctl(IOCTL_ADD, &[])?;
        self.update()?;
        Ok(index)
    }

    /// Unplug the monitor with the given index.
    pub fn remove_display(&self, index: u32) -> Result<()> {
        // The driver reads the index as a 16-bit big-endian value.
        let data = [((index >> 8) & 0xff) as u8, (index & 0xff) as u8];
        self.ioctl(IOCTL_REMOVE, &data)?;
        self.update()
    }

    /// Spawn the keep-alive thread. Drop the returned guard to stop it (which
    /// lets the driver unplug any remaining displays).
    pub fn start_keepalive(self: &Arc<Self>) -> KeepAlive {
        let stop = Arc::new(AtomicBool::new(false));
        let vdd = Arc::clone(self);
        let stop2 = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("vdd-keepalive".into())
            .spawn(move || {
                while !stop2.load(Ordering::Relaxed) {
                    if let Err(e) = vdd.update() {
                        log::warn!("VDD keep-alive failed: {e:#}");
                    }
                    thread::sleep(KEEPALIVE_INTERVAL);
                }
            })
            .expect("spawn vdd keep-alive thread");
        KeepAlive {
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for Vdd {
    fn drop(&mut self) {
        if !self.handle.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.handle);
            }
        }
    }
}

pub struct KeepAlive {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for KeepAlive {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ---------------------------------------------------------------------------
// VirtualDisplay backend
// ---------------------------------------------------------------------------

use crate::display::{self, Mode, Monitor};
use crate::driver::{Attachment, VirtualDisplay};
use crate::gpu::GpuInfo;

const APPEAR_TIMEOUT: Duration = Duration::from_secs(10);

pub struct ParsecVdd {
    vdd: Arc<Vdd>,
    _keepalive: KeepAlive,
}

impl ParsecVdd {
    pub fn open() -> Result<Self> {
        let vdd = Arc::new(Vdd::open()?);
        let version = vdd.version().context("querying parsec-vdd version")?;
        log::info!("parsec-vdd v0.{version} ready");
        let keepalive = vdd.start_keepalive();
        Ok(ParsecVdd {
            vdd,
            _keepalive: keepalive,
        })
    }
}

impl VirtualDisplay for ParsecVdd {
    fn name(&self) -> &'static str {
        "parsec-vdd"
    }

    fn pnp_id(&self) -> &'static str {
        MONITOR_PNP_ID
    }

    fn dynamic_modes(&self) -> bool {
        false
    }

    fn attach(&self, mode: Mode, gpu: &GpuInfo) -> Result<(Attachment, Monitor)> {
        log::warn!(
            "parsec-vdd cannot pin the render GPU; Windows will pick one (wanted {})",
            gpu.name
        );
        let before = display::enumerate();
        let index = self.vdd.add_display().context("parsec-vdd add display")?;
        log::info!(
            "parsec-vdd: added display #{index}, want {}x{}@{}",
            mode.width,
            mode.height,
            mode.hz
        );
        let is_virtual = |m: &Monitor| self.is_virtual(m);
        match display::wait_for_new_monitor(&before, &is_virtual, APPEAR_TIMEOUT) {
            Ok(monitor) => Ok((
                Attachment::Parsec {
                    index,
                    device_name: monitor.device_name.clone(),
                },
                monitor,
            )),
            Err(e) => {
                let _ = self.vdd.remove_display(index);
                Err(e)
            }
        }
    }

    fn detach(&self, attachment: Attachment) -> Result<()> {
        match attachment {
            Attachment::Parsec { index, device_name } => {
                self.vdd.remove_display(index)?;
                log::info!("parsec-vdd: removed display #{index} ({device_name})");
                Ok(())
            }
            other => anyhow::bail!("parsec-vdd cannot detach {other:?}"),
        }
    }

    fn cleanup(&self) -> Result<()> {
        // The driver unplugs everything by itself once a dead host stops pinging.
        Ok(())
    }
}
