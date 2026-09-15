//! Monitor enumeration, mode selection and the mapping from a GDI display name
//! (`\\.\DISPLAY3`) to the DXGI adapter/output indices the capture side needs.

use std::collections::HashSet;
use std::mem::size_of;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINTL};
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIFactory1};
use windows::Win32::Graphics::Gdi::{
    ChangeDisplaySettingsExW, EnumDisplayDevicesW, EnumDisplaySettingsW, CDS_NORESET, CDS_SET_PRIMARY,
    CDS_TYPE, CDS_UPDATEREGISTRY, DEVMODEW, DISPLAY_DEVICEW, DISPLAY_DEVICE_ATTACHED_TO_DESKTOP,
    DISPLAY_DEVICE_PRIMARY_DEVICE, DISP_CHANGE_SUCCESSFUL, DM_DISPLAYFREQUENCY, DM_PELSHEIGHT,
    DM_PELSWIDTH, DM_POSITION, ENUM_CURRENT_SETTINGS, ENUM_DISPLAY_SETTINGS_MODE,
};

use crate::gpu::Luid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Monitor {
    /// GDI adapter/output name, e.g. `\\.\DISPLAY3`. Used by ChangeDisplaySettingsEx
    /// and reported by DXGI_OUTPUT_DESC.DeviceName.
    pub device_name: String,
    /// Adapter description, e.g. "NVIDIA GeForce RTX 3080 Ti".
    pub adapter_string: String,
    /// Monitor PnP id, e.g. `MONITOR\PSCCDD0\{...}\0003`.
    pub monitor_id: String,
    /// Monitor friendly string, e.g. "Generic PnP Monitor".
    pub monitor_string: String,
    pub attached: bool,
    pub primary: bool,
}

impl Monitor {
    /// True if the monitor's PnP id (e.g. `MONITOR\MTT1337\...`) contains `pnp_id`.
    pub fn has_pnp_id(&self, pnp_id: &str) -> bool {
        self.monitor_id.contains(pnp_id)
    }
}

/// Where a display lives in DXGI terms: what ffmpeg's `d3d11va=hw:A` + `ddagrab=output_idx=O` need.
#[derive(Debug, Clone)]
pub struct OutputLocation {
    pub adapter_index: u32,
    pub output_index: u32,
    pub adapter_luid: Luid,
    pub adapter_name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mode {
    pub width: u32,
    pub height: u32,
    pub hz: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct Placement {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub hz: u32,
}

pub(crate) fn wide_to_string(w: &[u16]) -> String {
    let end = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..end])
}

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Enumerate every monitor attached to every display adapter.
pub fn enumerate() -> Vec<Monitor> {
    let mut out = Vec::new();
    unsafe {
        let mut i = 0u32;
        loop {
            let mut dd = DISPLAY_DEVICEW {
                cb: size_of::<DISPLAY_DEVICEW>() as u32,
                ..Default::default()
            };
            if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dd, 0).as_bool() {
                break;
            }
            i += 1;
            let device_name = wide_to_string(&dd.DeviceName);
            let adapter_string = wide_to_string(&dd.DeviceString);
            let attached = dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP != 0;
            let primary = dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE != 0;

            let name_w = to_wide(&device_name);
            let mut j = 0u32;
            loop {
                let mut md = DISPLAY_DEVICEW {
                    cb: size_of::<DISPLAY_DEVICEW>() as u32,
                    ..Default::default()
                };
                if !EnumDisplayDevicesW(PCWSTR::from_raw(name_w.as_ptr()), j, &mut md, 0).as_bool() {
                    break;
                }
                j += 1;
                out.push(Monitor {
                    device_name: device_name.clone(),
                    adapter_string: adapter_string.clone(),
                    monitor_id: wide_to_string(&md.DeviceID),
                    monitor_string: wide_to_string(&md.DeviceString),
                    attached,
                    primary,
                });
            }
        }
    }
    out
}

pub fn primary() -> Option<Monitor> {
    enumerate().into_iter().find(|m| m.primary && m.attached)
}

/// Wait for a monitor matching `is_virtual` that was not attached in `before`
/// to show up and become attached to the desktop.
pub fn wait_for_new_monitor(
    before: &[Monitor],
    is_virtual: &dyn Fn(&Monitor) -> bool,
    timeout: Duration,
) -> Result<Monitor> {
    let known: HashSet<String> = before
        .iter()
        .filter(|m| is_virtual(m) && m.attached)
        .map(|m| m.device_name.clone())
        .collect();
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(m) = enumerate()
            .into_iter()
            .find(|m| is_virtual(m) && m.attached && !known.contains(&m.device_name))
        {
            return Ok(m);
        }
        if Instant::now() >= deadline {
            bail!("virtual display did not appear within {:?}", timeout);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

pub fn attached_matching(is_virtual: &dyn Fn(&Monitor) -> bool) -> Vec<Monitor> {
    enumerate()
        .into_iter()
        .filter(|m| is_virtual(m) && m.attached)
        .collect()
}

fn devmode_for(device_name: &str, mode: ENUM_DISPLAY_SETTINGS_MODE) -> Option<DEVMODEW> {
    let name_w = to_wide(device_name);
    let mut dm = DEVMODEW {
        dmSize: size_of::<DEVMODEW>() as u16,
        ..Default::default()
    };
    let ok = unsafe { EnumDisplaySettingsW(PCWSTR::from_raw(name_w.as_ptr()), mode, &mut dm) };
    ok.as_bool().then_some(dm)
}

/// Current mode and desktop position of a display.
pub fn current_placement(device_name: &str) -> Result<Placement> {
    let dm = devmode_for(device_name, ENUM_CURRENT_SETTINGS)
        .ok_or_else(|| anyhow!("EnumDisplaySettingsW({device_name}) failed"))?;
    // dmPosition lives in the first anonymous union (the "display" variant).
    let pos: POINTL = unsafe { dm.Anonymous1.Anonymous2.dmPosition };
    Ok(Placement {
        x: pos.x,
        y: pos.y,
        width: dm.dmPelsWidth,
        height: dm.dmPelsHeight,
        hz: dm.dmDisplayFrequency,
    })
}

/// All modes the display driver offers.
pub fn list_modes(device_name: &str) -> Vec<Mode> {
    let mut modes = Vec::new();
    let mut i = 0u32;
    while let Some(dm) = devmode_for(device_name, ENUM_DISPLAY_SETTINGS_MODE(i)) {
        i += 1;
        let m = Mode {
            width: dm.dmPelsWidth,
            height: dm.dmPelsHeight,
            hz: dm.dmDisplayFrequency,
        };
        if !modes.contains(&m) {
            modes.push(m);
        }
    }
    modes
}

/// Pick the best available mode for what the client asked for: exact match if
/// possible, otherwise the largest mode that fits inside the request (same
/// aspect preferred), otherwise whatever is closest in pixel count.
pub fn choose_mode(available: &[Mode], want: Mode) -> Option<Mode> {
    if available.is_empty() {
        return None;
    }
    let hz_pref = |m: &Mode| if m.hz == want.hz { 0 } else if m.hz > want.hz { 1 } else { 2 };
    if let Some(m) = available
        .iter()
        .filter(|m| m.width == want.width && m.height == want.height)
        .min_by_key(|m| (hz_pref(m), (m.hz as i64 - want.hz as i64).abs()))
    {
        return Some(*m);
    }
    let want_aspect = want.width as f64 / want.height as f64;
    let fits: Vec<&Mode> = available
        .iter()
        .filter(|m| m.width <= want.width && m.height <= want.height)
        .collect();
    let candidates = if fits.is_empty() { available.iter().collect() } else { fits };
    candidates
        .into_iter()
        .min_by(|a, b| {
            let score = |m: &Mode| {
                let aspect = (m.width as f64 / m.height as f64 - want_aspect).abs();
                let pixels = (m.width * m.height) as f64;
                let want_pixels = (want.width * want.height) as f64;
                // aspect mismatch dominates, then pixel-count distance, then refresh
                aspect * 1e9 + (pixels - want_pixels).abs() + hz_pref(m) as f64 * 1e3
            };
            score(a).partial_cmp(&score(b)).unwrap()
        })
        .copied()
}

/// Apply a mode to a display. With `persist` the change is also written to the
/// registry (the layout Windows restores for this set of monitors); without it
/// the change lasts only until the configuration is next applied.
pub fn set_mode(device_name: &str, mode: Mode, persist: bool) -> Result<()> {
    let name_w = to_wide(device_name);
    let dm = DEVMODEW {
        dmSize: size_of::<DEVMODEW>() as u16,
        dmPelsWidth: mode.width,
        dmPelsHeight: mode.height,
        dmDisplayFrequency: mode.hz,
        dmFields: DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY,
        ..Default::default()
    };
    let flags = if persist { CDS_UPDATEREGISTRY } else { CDS_TYPE(0) };
    let r = unsafe {
        ChangeDisplaySettingsExW(PCWSTR::from_raw(name_w.as_ptr()), Some(&dm), HWND::default(), flags, None)
    };
    if r != DISP_CHANGE_SUCCESSFUL {
        bail!(
            "ChangeDisplaySettingsExW({device_name}, {}x{}@{}) failed: DISP_CHANGE {}",
            mode.width,
            mode.height,
            mode.hz,
            r.0
        );
    }
    Ok(())
}

/// Stage "add this display to the desktop at `mode`, placed at (`x`, `y`)"
/// (optionally as the primary) without applying yet. This is what Display
/// Settings does for "Extend desktop to this display": changes go to the
/// registry with CDS_NORESET and take effect on `apply_display_changes`.
pub fn stage_attach(device_name: &str, mode: Mode, x: i32, y: i32, primary: bool) -> Result<()> {
    let name_w = to_wide(device_name);
    let mut dm = DEVMODEW {
        dmSize: size_of::<DEVMODEW>() as u16,
        dmPelsWidth: mode.width,
        dmPelsHeight: mode.height,
        dmDisplayFrequency: mode.hz,
        dmFields: DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_POSITION,
        ..Default::default()
    };
    dm.Anonymous1.Anonymous2.dmPosition = POINTL { x, y };
    let mut flags = CDS_UPDATEREGISTRY | CDS_NORESET;
    if primary {
        flags |= CDS_SET_PRIMARY;
    }
    let r = unsafe {
        ChangeDisplaySettingsExW(PCWSTR::from_raw(name_w.as_ptr()), Some(&dm), HWND::default(), flags, None)
    };
    if r != DISP_CHANGE_SUCCESSFUL {
        bail!(
            "ChangeDisplaySettingsExW(attach {device_name}, {}x{}@{} at {x},{y}) failed: DISP_CHANGE {}",
            mode.width, mode.height, mode.hz, r.0
        );
    }
    Ok(())
}

/// Stage "remove this display from the desktop" ("Disconnect this display"):
/// a 0x0 mode with DM_POSITION deactivates its path on `apply_display_changes`.
pub fn stage_detach(device_name: &str) -> Result<()> {
    let name_w = to_wide(device_name);
    let mut dm = DEVMODEW {
        dmSize: size_of::<DEVMODEW>() as u16,
        dmFields: DM_PELSWIDTH | DM_PELSHEIGHT | DM_POSITION,
        ..Default::default()
    };
    dm.Anonymous1.Anonymous2.dmPosition = POINTL { x: 0, y: 0 };
    let r = unsafe {
        ChangeDisplaySettingsExW(
            PCWSTR::from_raw(name_w.as_ptr()),
            Some(&dm),
            HWND::default(),
            CDS_UPDATEREGISTRY | CDS_NORESET,
            None,
        )
    };
    if r != DISP_CHANGE_SUCCESSFUL {
        bail!("ChangeDisplaySettingsExW(detach {device_name}) failed: DISP_CHANGE {}", r.0);
    }
    Ok(())
}

/// Commit configuration changes staged with CDS_NORESET.
pub fn apply_display_changes() -> Result<()> {
    let r = unsafe { ChangeDisplaySettingsExW(PCWSTR::null(), None, HWND::default(), CDS_TYPE(0), None) };
    if r != DISP_CHANGE_SUCCESSFUL {
        bail!("applying display configuration failed: DISP_CHANGE {}", r.0);
    }
    Ok(())
}

/// Add a present-but-inactive display to the desktop right away.
pub fn attach_display(device_name: &str, mode: Mode, x: i32, y: i32) -> Result<()> {
    stage_attach(device_name, mode, x, y, false)?;
    apply_display_changes()
}

/// Remove a display from the desktop right away, without touching the device.
pub fn detach_display(device_name: &str) -> Result<()> {
    stage_detach(device_name)?;
    apply_display_changes()
}

/// Wait until a monitor matching `is_virtual` is attached (or, with
/// `attached == false`, until none is). Returns false on timeout.
pub fn wait_for_attached_state(
    is_virtual: &dyn Fn(&Monitor) -> bool,
    attached: bool,
    timeout: Duration,
) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        let any = enumerate().iter().any(|m| is_virtual(m) && m.attached);
        if any == attached {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Desktop coordinates just right of the rightmost attached display (top-aligned
/// with the primary), so a new display never overlaps an existing one.
pub fn next_free_position() -> (i32, i32) {
    let mut right = 0i32;
    let mut top = 0i32;
    for m in enumerate().into_iter().filter(|m| m.attached) {
        if let Ok(p) = current_placement(&m.device_name) {
            right = right.max(p.x + p.width as i32);
            if m.primary {
                top = p.y;
            }
        }
    }
    (right, top)
}

/// Monitors matching `is_virtual` whether or not they are on the desktop.
pub fn present_matching(is_virtual: &dyn Fn(&Monitor) -> bool) -> Vec<Monitor> {
    enumerate().into_iter().filter(|m| is_virtual(m)).collect()
}

/// Locate the DXGI (adapter index, output index) whose DeviceName matches a GDI
/// display name. ffmpeg's `ddagrab=output_idx=N` and `-init_hw_device d3d11va=hw:A`
/// use exactly these indices.
pub fn dxgi_output_for(device_name: &str) -> Result<OutputLocation> {
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().context("CreateDXGIFactory1")?;
        let mut ai = 0u32;
        while let Ok(adapter) = factory.EnumAdapters1(ai) {
            let mut oi = 0u32;
            while let Ok(output) = adapter.EnumOutputs(oi) {
                let desc = output.GetDesc().context("IDXGIOutput::GetDesc")?;
                if wide_to_string(&desc.DeviceName) == device_name {
                    let adesc = adapter.GetDesc1().context("IDXGIAdapter1::GetDesc1")?;
                    return Ok(OutputLocation {
                        adapter_index: ai,
                        output_index: oi,
                        adapter_luid: adesc.AdapterLuid.into(),
                        adapter_name: wide_to_string(&adesc.Description),
                    });
                }
                oi += 1;
            }
            ai += 1;
        }
    }
    bail!("no DXGI output is named {device_name} (is the display attached to the desktop?)")
}

/// Human-readable dump used by the `displays` subcommand.
pub fn describe_all() -> String {
    let mut s = String::new();
    for m in enumerate() {
        let place = current_placement(&m.device_name).ok();
        let dxgi = dxgi_output_for(&m.device_name).ok();
        s.push_str(&format!(
            "{}  {}{}\n    adapter: {}\n    monitor: {} [{}]\n    mode: {}\n    dxgi: {}\n",
            m.device_name,
            if m.attached { "attached" } else { "detached" },
            if m.primary { ", primary" } else { "" },
            m.adapter_string,
            m.monitor_string,
            m.monitor_id,
            place
                .map(|p| format!("{}x{}@{} at ({}, {})", p.width, p.height, p.hz, p.x, p.y))
                .unwrap_or_else(|| "-".into()),
            dxgi.map(|l| format!("adapter {} ({}), output {}", l.adapter_index, l.adapter_name, l.output_index))
                .unwrap_or_else(|| "-".into()),
        ));
    }
    s
}
