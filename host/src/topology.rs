//! Display topology control through the CCD API (`QueryDisplayConfig` /
//! `SetDisplayConfig`): snapshot the user's display arrangement, make the
//! virtual display the only active one for the session, and put everything
//! back afterwards. The snapshot is also written to disk so a host that was
//! killed mid-session restores the physical displays the next time it starts.
//!
//! The virtual-only configuration is never saved to Windows' display database,
//! so a reboot or Windows' own fallback (when the only active display vanishes)
//! always lands on the physical layout.

use std::fs;
use std::mem::size_of;
use std::path::PathBuf;

use anyhow::{anyhow, bail, Context, Result};
use windows::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig, SetDisplayConfig,
    DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
    DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_PATH_INFO,
    DISPLAYCONFIG_SOURCE_DEVICE_NAME, DISPLAYCONFIG_TARGET_DEVICE_NAME,
    QDC_ONLY_ACTIVE_PATHS, QDC_VIRTUAL_MODE_AWARE, QUERY_DISPLAY_CONFIG_FLAGS, SDC_ALLOW_CHANGES,
    SDC_ALLOW_PATH_ORDER_CHANGES, SDC_APPLY, SDC_SAVE_TO_DATABASE, SDC_TOPOLOGY_EXTEND,
    SDC_USE_DATABASE_CURRENT, SDC_USE_SUPPLIED_DISPLAY_CONFIG, SDC_VIRTUAL_MODE_AWARE,
    SET_DISPLAY_CONFIG_FLAGS,
};
use windows::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, LUID, POINTL};
use windows::Win32::Graphics::Gdi::DISPLAYCONFIG_PATH_ACTIVE;

use crate::display::{self, wide_to_string, Mode, Monitor};

const SNAPSHOT_MAGIC: &[u8; 8] = b"TDSNAP01";

/// The active display configuration at one point in time.
#[derive(Clone)]
pub struct Snapshot {
    pub paths: Vec<DISPLAYCONFIG_PATH_INFO>,
    pub modes: Vec<DISPLAYCONFIG_MODE_INFO>,
}

fn query(flags: QUERY_DISPLAY_CONFIG_FLAGS) -> Result<(Vec<DISPLAYCONFIG_PATH_INFO>, Vec<DISPLAYCONFIG_MODE_INFO>)> {
    unsafe {
        loop {
            let (mut num_paths, mut num_modes) = (0u32, 0u32);
            GetDisplayConfigBufferSizes(flags, &mut num_paths, &mut num_modes)
                .ok()
                .context("GetDisplayConfigBufferSizes")?;
            let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); num_paths as usize];
            let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); num_modes as usize];
            let r = QueryDisplayConfig(
                flags,
                &mut num_paths,
                paths.as_mut_ptr(),
                &mut num_modes,
                modes.as_mut_ptr(),
                None,
            );
            if r == ERROR_INSUFFICIENT_BUFFER {
                continue; // a monitor came or went between the two calls
            }
            r.ok().context("QueryDisplayConfig")?;
            paths.truncate(num_paths as usize);
            modes.truncate(num_modes as usize);
            return Ok((paths, modes));
        }
    }
}

fn set(paths: &[DISPLAYCONFIG_PATH_INFO], modes: &[DISPLAYCONFIG_MODE_INFO], flags: SET_DISPLAY_CONFIG_FLAGS) -> Result<()> {
    let r = unsafe {
        SetDisplayConfig(
            if paths.is_empty() { None } else { Some(paths) },
            if modes.is_empty() { None } else { Some(modes) },
            flags,
        )
    };
    if r != 0 {
        bail!("SetDisplayConfig(flags 0x{:x}) failed with error {r}", flags.0);
    }
    Ok(())
}

/// `\\?\DISPLAY#MTT1337#...` for a target.
fn target_device_path(adapter: LUID, id: u32) -> Option<String> {
    let mut name = DISPLAYCONFIG_TARGET_DEVICE_NAME {
        header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
            r#type: DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
            size: size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32,
            adapterId: adapter,
            id,
        },
        ..Default::default()
    };
    (unsafe { DisplayConfigGetDeviceInfo(&mut name.header) } == 0)
        .then(|| wide_to_string(&name.monitorDevicePath))
}

/// `\\.\DISPLAYn` for a source.
fn source_gdi_name(adapter: LUID, id: u32) -> Option<String> {
    let mut name = DISPLAYCONFIG_SOURCE_DEVICE_NAME {
        header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
            r#type: DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
            size: size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32,
            adapterId: adapter,
            id,
        },
        ..Default::default()
    };
    (unsafe { DisplayConfigGetDeviceInfo(&mut name.header) } == 0)
        .then(|| wide_to_string(&name.viewGdiDeviceName))
}

fn snapshot_file() -> Result<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("LOCALAPPDATA is not set"))?;
    Ok(base.join("TravelDisplay").join("display-snapshot.bin"))
}

impl Snapshot {
    /// Capture the currently active paths and modes.
    pub fn take() -> Result<Self> {
        let (paths, modes) = query(QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE)?;
        if paths.is_empty() {
            bail!("no active display paths to snapshot");
        }
        Ok(Snapshot { paths, modes })
    }

    /// Human-readable list of the displays in the snapshot.
    pub fn describe(&self) -> String {
        self.paths
            .iter()
            .map(|p| {
                let src = source_gdi_name(p.sourceInfo.adapterId, p.sourceInfo.id).unwrap_or_default();
                let tgt = target_device_path(p.targetInfo.adapterId, p.targetInfo.id).unwrap_or_default();
                let pnp = tgt.split('#').nth(1).unwrap_or("?").to_string();
                format!("{src} ({pnp})")
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(SNAPSHOT_MAGIC);
        out.extend_from_slice(&(self.paths.len() as u32).to_le_bytes());
        out.extend_from_slice(&(self.modes.len() as u32).to_le_bytes());
        // Both structs are plain #[repr(C)] data; store them verbatim.
        out.extend_from_slice(unsafe {
            std::slice::from_raw_parts(self.paths.as_ptr() as *const u8, self.paths.len() * size_of::<DISPLAYCONFIG_PATH_INFO>())
        });
        out.extend_from_slice(unsafe {
            std::slice::from_raw_parts(self.modes.as_ptr() as *const u8, self.modes.len() * size_of::<DISPLAYCONFIG_MODE_INFO>())
        });
        out
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 16 || &bytes[..8] != SNAPSHOT_MAGIC {
            bail!("not a TravelDisplay snapshot");
        }
        let num_paths = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let num_modes = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let (ps, ms) = (size_of::<DISPLAYCONFIG_PATH_INFO>(), size_of::<DISPLAYCONFIG_MODE_INFO>());
        let expected = 16 + num_paths * ps + num_modes * ms;
        if bytes.len() != expected {
            bail!("snapshot is {} bytes, expected {expected}", bytes.len());
        }
        let mut offset = 16;
        let mut paths = Vec::with_capacity(num_paths);
        for _ in 0..num_paths {
            paths.push(unsafe { std::ptr::read_unaligned(bytes[offset..].as_ptr() as *const DISPLAYCONFIG_PATH_INFO) });
            offset += ps;
        }
        let mut modes = Vec::with_capacity(num_modes);
        for _ in 0..num_modes {
            modes.push(unsafe { std::ptr::read_unaligned(bytes[offset..].as_ptr() as *const DISPLAYCONFIG_MODE_INFO) });
            offset += ms;
        }
        Ok(Snapshot { paths, modes })
    }

    /// Persist so a restarted host can restore after a crash.
    pub fn save(&self) -> Result<()> {
        let file = snapshot_file()?;
        if let Some(dir) = file.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(&file, self.to_bytes()).with_context(|| format!("writing {}", file.display()))
    }

    pub fn load_saved() -> Result<Option<Self>> {
        let file = snapshot_file()?;
        if !file.exists() {
            return Ok(None);
        }
        let bytes = fs::read(&file).with_context(|| format!("reading {}", file.display()))?;
        Ok(Some(Self::from_bytes(&bytes)?))
    }

    pub fn clear_saved() {
        if let Ok(file) = snapshot_file() {
            let _ = fs::remove_file(file);
        }
    }

    /// Re-apply this configuration: the paths in it become active again with
    /// their exact modes and positions; anything else (the virtual display)
    /// goes inactive. Saved to the database so Windows keeps it as the layout
    /// for this set of monitors.
    pub fn restore(&self) -> Result<()> {
        let flags = SDC_APPLY
            | SDC_USE_SUPPLIED_DISPLAY_CONFIG
            | SDC_VIRTUAL_MODE_AWARE
            | SDC_ALLOW_CHANGES
            | SDC_SAVE_TO_DATABASE;
        match set(&self.paths, &self.modes, flags) {
            Ok(()) => {
                log::info!("display layout restored: {}", self.describe());
                Ok(())
            }
            Err(e) => {
                log::warn!("{e:#}; falling back to Windows' saved layout");
                restore_from_database()
            }
        }
    }
}

/// Let Windows apply whatever it has stored for the currently connected
/// monitors; if it has nothing, extend across all of them.
pub fn restore_from_database() -> Result<()> {
    if set(&[], &[], SDC_APPLY | SDC_USE_DATABASE_CURRENT).is_ok() {
        log::info!("display layout restored from Windows' database");
        return Ok(());
    }
    set(&[], &[], SDC_APPLY | SDC_TOPOLOGY_EXTEND).context("SDC_TOPOLOGY_EXTEND")?;
    log::warn!("display layout reset to 'extend' (no saved layout was usable)");
    Ok(())
}

/// Make the virtual display (identified by the PnP id in its device path) the
/// only active display at the requested mode. Returns it as the desktop now
/// sees it: attached and primary at (0, 0).
///
/// Windows refuses a topology-only request (`SDC_TOPOLOGY_SUPPLIED`) for a
/// layout it has never stored, so instead the monitor is first added to the
/// desktop the ordinary way, its real source/target modes are read back, and
/// a complete one-path configuration built from them is applied.
pub fn exclusive(pnp_id: &str, mode: Mode) -> Result<Monitor> {
    let is_virtual = |m: &Monitor| m.has_pnp_id(pnp_id);

    // 1. Get it onto the desktop (extended, anywhere) so it has real modes.
    let present = display::present_matching(&is_virtual);
    let monitor = present
        .iter()
        .max_by_key(|m| m.attached)
        .cloned()
        .ok_or_else(|| anyhow!("no {pnp_id} monitor is present"))?;
    if !monitor.attached {
        let (x, y) = display::next_free_position();
        log::info!("adding {} to the desktop as {}x{}@{}", monitor.device_name, mode.width, mode.height, mode.hz);
        display::attach_display(&monitor.device_name, mode, x, y)?;
        if !display::wait_for_attached_state(&is_virtual, true, std::time::Duration::from_secs(10)) {
            bail!("{} did not join the desktop", monitor.device_name);
        }
    }
    let current = display::current_placement(&monitor.device_name)?;
    if (current.width, current.height, current.hz) != (mode.width, mode.height, mode.hz) {
        if let Some(m) = display::choose_mode(&display::list_modes(&monitor.device_name), mode) {
            if m != mode {
                log::warn!(
                    "virtual display cannot do {}x{}@{}; using {}x{}@{}",
                    mode.width, mode.height, mode.hz, m.width, m.height, m.hz
                );
            }
            display::set_mode(&monitor.device_name, m, true)?;
        }
    }

    // 2. Read the active configuration back and keep only the virtual path,
    //    with its own modes, moved to the origin.
    let (paths, modes) = query(QDC_ONLY_ACTIVE_PATHS)?;
    let path = paths
        .iter()
        .find(|p| {
            target_device_path(p.targetInfo.adapterId, p.targetInfo.id)
                .is_some_and(|d| d.contains(pnp_id))
        })
        .copied()
        .ok_or_else(|| anyhow!("{pnp_id} monitor is not in the active configuration"))?;
    let (src_idx, tgt_idx) = unsafe {
        (
            path.sourceInfo.Anonymous.modeInfoIdx as usize,
            path.targetInfo.Anonymous.modeInfoIdx as usize,
        )
    };
    let (Some(mut source_mode), Some(target_mode)) = (modes.get(src_idx).copied(), modes.get(tgt_idx).copied()) else {
        bail!("active configuration has no modes for the virtual display");
    };
    source_mode.Anonymous.sourceMode.position = POINTL { x: 0, y: 0 };
    let mut only = path;
    only.flags = DISPLAYCONFIG_PATH_ACTIVE;
    only.sourceInfo.Anonymous.modeInfoIdx = 0;
    only.targetInfo.Anonymous.modeInfoIdx = 1;
    let only_modes = [source_mode, target_mode];

    // Complete config, deliberately NOT saved to the database.
    let flags = SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES;
    if let Err(e) = set(&[only], &only_modes, flags) {
        log::debug!("{e:#}; retrying with path order changes allowed");
        if let Err(e) = set(&[only], &only_modes, flags | SDC_ALLOW_PATH_ORDER_CHANGES) {
            log::warn!("{e:#}; using the legacy per-display route");
            exclusive_via_gdi(pnp_id, mode)?;
        }
    }

    // 3. Verify.
    if !display::wait_for_attached_state(&is_virtual, true, std::time::Duration::from_secs(10)) {
        bail!("the virtual display did not stay active");
    }
    let monitor = display::enumerate()
        .into_iter()
        .find(|m| m.attached && is_virtual(m))
        .ok_or_else(|| anyhow!("virtual display is not on the desktop"))?;
    let others: Vec<String> = display::enumerate()
        .into_iter()
        .filter(|m| m.attached && !is_virtual(m))
        .map(|m| m.device_name)
        .collect();
    if !others.is_empty() {
        bail!("other displays are still active: {others:?}");
    }
    if !monitor.primary {
        log::warn!("{} is the only display but not marked primary", monitor.device_name);
    }
    Ok(monitor)
}

/// Fallback for `exclusive`: stage every physical display as detached and the
/// virtual one as primary at (0, 0), then apply once. Drivers may refuse the
/// 0x0 "detach" for a physical output; report but keep going.
fn exclusive_via_gdi(pnp_id: &str, mode: Mode) -> Result<()> {
    let monitors = display::enumerate();
    let virtual_name = monitors
        .iter()
        .find(|m| m.has_pnp_id(pnp_id))
        .map(|m| m.device_name.clone())
        .ok_or_else(|| anyhow!("no {pnp_id} monitor present"))?;
    display::stage_attach(&virtual_name, mode, 0, 0, true)?;
    for m in monitors.iter().filter(|m| m.attached && m.device_name != virtual_name) {
        if let Err(e) = display::stage_detach(&m.device_name) {
            log::warn!("{e:#}");
        }
    }
    display::apply_display_changes()
}

/// Called at host start and on Ctrl-C: if a session left a snapshot behind, the
/// physical displays may still be off — put them back.
pub fn recover_saved() -> Result<bool> {
    match Snapshot::load_saved() {
        Ok(Some(snap)) => {
            log::info!("restoring the display layout saved by an earlier session");
            let r = snap.restore();
            Snapshot::clear_saved();
            r.map(|_| true)
        }
        Ok(None) => Ok(false),
        Err(e) => {
            log::warn!("ignoring unreadable display snapshot: {e:#}");
            Snapshot::clear_saved();
            Ok(false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_round_trips_through_bytes() {
        let mut path = DISPLAYCONFIG_PATH_INFO {
            flags: DISPLAYCONFIG_PATH_ACTIVE,
            ..Default::default()
        };
        path.sourceInfo.id = 3;
        path.targetInfo.id = 0x1234;
        path.targetInfo.adapterId = LUID { LowPart: 0xabcd, HighPart: 1 };
        let mode = DISPLAYCONFIG_MODE_INFO {
            id: 7,
            ..Default::default()
        };
        let snap = Snapshot {
            paths: vec![path, path],
            modes: vec![mode],
        };
        let back = Snapshot::from_bytes(&snap.to_bytes()).unwrap();
        assert_eq!(back.paths.len(), 2);
        assert_eq!(back.modes.len(), 1);
        assert_eq!(back.paths[1].targetInfo.id, 0x1234);
        assert_eq!(back.paths[1].targetInfo.adapterId.LowPart, 0xabcd);
        assert_eq!(back.paths[0].flags, DISPLAYCONFIG_PATH_ACTIVE);
        assert_eq!(back.modes[0].id, 7);
    }

    #[test]
    fn rejects_garbage() {
        assert!(Snapshot::from_bytes(b"nope").is_err());
        let mut bytes = Snapshot { paths: vec![], modes: vec![] }.to_bytes();
        bytes.push(0);
        assert!(Snapshot::from_bytes(&bytes).is_err(), "trailing bytes must be rejected");
    }
}
