//! PnP device-node control (SetupAPI + CfgMgr32): find a device by hardware
//! id, read its status, enable and disable it. Used for the virtual display
//! driver's node (the switch that makes the virtual monitor exist) and for
//! taking the physical monitors off the desktop for a session.
//!
//! Enable/disable need administrator rights. The host has them when it runs
//! as the Relay service (SYSTEM) or from an elevated prompt; otherwise the
//! error says so instead of failing deep inside CfgMgr32.

use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use windows::core::PCWSTR;
use windows::Win32::Devices::DeviceAndDriverInstallation::{
    CM_Disable_DevNode, CM_Enable_DevNode, CM_Get_DevNode_Status, CM_Locate_DevNodeW,
    SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInfo, SetupDiGetClassDevsW,
    SetupDiGetDeviceInstanceIdW, SetupDiGetDeviceRegistryPropertyW, CM_DEVNODE_STATUS_FLAGS,
    CM_LOCATE_DEVNODE_NORMAL, CM_PROB, CM_PROB_DISABLED, CONFIGRET, CR_SUCCESS, DIGCF_ALLCLASSES,
    DIGCF_PRESENT, DN_HAS_PROBLEM, GUID_DEVCLASS_MONITOR, SPDRP_HARDWAREID, SP_DEVINFO_DATA,
};
use windows::Win32::Foundation::{ERROR_NO_MORE_ITEMS, HWND};
use windows::Win32::UI::Shell::IsUserAnAdmin;

/// One present device node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevNode {
    /// `ROOT\DISPLAY\0000`, `DISPLAY\PSCCDD0\4&...` — the CfgMgr32 instance id.
    pub instance_id: String,
    /// Every hardware id the node reports, e.g. `Root\MttVDD`, `MONITOR\MTT1337`.
    pub hardware_ids: Vec<String>,
}

/// What `CM_Get_DevNode_Status` says about a node.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Started, no problem code.
    Ok,
    /// Problem 22: disabled by the user (or by us).
    Disabled,
    /// Any other problem code (e.g. 43 after the driver crashed too often).
    Problem(u32),
}

/// Whether this process may enable/disable device nodes.
pub fn is_admin() -> bool {
    unsafe { IsUserAnAdmin().as_bool() }
}

fn require_admin() -> Result<()> {
    if is_admin() {
        return Ok(());
    }
    bail!(
        "changing device state needs administrator rights: run relay-host as the Relay \
         service (tools/install-host.ps1) or from an elevated prompt"
    )
}

/// All present nodes (any class) whose hardware ids include `hardware_id`
/// (case-insensitive, as Windows compares them).
pub fn find_by_hardware_id(hardware_id: &str) -> Result<Vec<DevNode>> {
    let all = enumerate(None)?;
    Ok(all
        .into_iter()
        .filter(|n| {
            n.hardware_ids
                .iter()
                .any(|h| h.eq_ignore_ascii_case(hardware_id))
        })
        .collect())
}

/// Present monitor-class nodes that are started (status Ok), excluding those
/// whose hardware id contains `except_pnp_id` (the virtual monitor).
pub fn physical_monitors(except_pnp_id: &str) -> Result<Vec<DevNode>> {
    let needle = format!("MONITOR\\{except_pnp_id}").to_ascii_uppercase();
    let mut out = Vec::new();
    for node in enumerate(Some(&GUID_DEVCLASS_MONITOR))? {
        let is_virtual = node
            .hardware_ids
            .iter()
            .any(|h| h.to_ascii_uppercase() == needle);
        if is_virtual {
            continue;
        }
        if status(&node.instance_id)? == Status::Ok {
            out.push(node);
        }
    }
    Ok(out)
}

pub fn status(instance_id: &str) -> Result<Status> {
    let devinst = locate(instance_id)?;
    let mut flags = CM_DEVNODE_STATUS_FLAGS(0);
    let mut problem = CM_PROB(0);
    let cr = unsafe { CM_Get_DevNode_Status(&mut flags, &mut problem, devinst, 0) };
    check(cr, "CM_Get_DevNode_Status")?;
    if flags.0 & DN_HAS_PROBLEM.0 == 0 {
        Ok(Status::Ok)
    } else if problem == CM_PROB_DISABLED {
        Ok(Status::Disabled)
    } else {
        Ok(Status::Problem(problem.0))
    }
}

/// Start a node. A node with a problem other than "disabled" (a crashed
/// driver at code 43, say) is cycled off and on, which is what clears it.
pub fn enable(instance_id: &str) -> Result<()> {
    require_admin()?;
    match status(instance_id)? {
        Status::Ok => return Ok(()),
        Status::Disabled => {}
        Status::Problem(code) => {
            log::info!("device {instance_id} has problem {code}; cycling it");
            let devinst = locate(instance_id)?;
            check(
                unsafe { CM_Disable_DevNode(devinst, 0) },
                "CM_Disable_DevNode",
            )?;
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }
    let devinst = locate(instance_id)?;
    check(
        unsafe { CM_Enable_DevNode(devinst, 0) },
        "CM_Enable_DevNode",
    )
    .with_context(|| format!("enabling {instance_id}"))
}

/// Stop a node (problem 22 afterwards). Already-disabled nodes are left alone.
pub fn disable(instance_id: &str) -> Result<()> {
    require_admin()?;
    if status(instance_id)? == Status::Disabled {
        return Ok(());
    }
    let devinst = locate(instance_id)?;
    check(
        unsafe { CM_Disable_DevNode(devinst, 0) },
        "CM_Disable_DevNode",
    )
    .with_context(|| format!("disabling {instance_id}"))
}

/// Persisted list of instance ids (one per line) — which physical monitors a
/// session disabled, so a later `restore` can bring them back after a crash.
pub fn read_id_list(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .map(|s| {
            s.lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

pub fn write_id_list(path: &Path, ids: &[String]) -> Result<()> {
    if ids.is_empty() {
        let _ = std::fs::remove_file(path);
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, ids.join("\n") + "\n")
        .with_context(|| format!("writing {}", path.display()))
}

// ---------------------------------------------------------------------------

fn locate(instance_id: &str) -> Result<u32> {
    let wide: Vec<u16> = instance_id.encode_utf16().chain(Some(0)).collect();
    let mut devinst = 0u32;
    let cr = unsafe {
        CM_Locate_DevNodeW(
            &mut devinst,
            PCWSTR(wide.as_ptr()),
            CM_LOCATE_DEVNODE_NORMAL,
        )
    };
    check(cr, "CM_Locate_DevNodeW").with_context(|| format!("locating {instance_id}"))?;
    Ok(devinst)
}

fn check(cr: CONFIGRET, what: &str) -> Result<()> {
    if cr == CR_SUCCESS {
        Ok(())
    } else {
        Err(anyhow!("{what} failed: CONFIGRET {:#x}", cr.0))
    }
}

/// Present device nodes, all classes or one class.
fn enumerate(class: Option<&windows::core::GUID>) -> Result<Vec<DevNode>> {
    let flags = match class {
        Some(_) => DIGCF_PRESENT,
        None => DIGCF_PRESENT | DIGCF_ALLCLASSES,
    };
    let devinfo =
        unsafe { SetupDiGetClassDevsW(class.map(|g| g as *const _), None, HWND::default(), flags) }
            .context("SetupDiGetClassDevsW")?;
    let mut out = Vec::new();
    let result = (|| -> Result<()> {
        let mut index = 0u32;
        loop {
            let mut data = SP_DEVINFO_DATA {
                cbSize: std::mem::size_of::<SP_DEVINFO_DATA>() as u32,
                ..Default::default()
            };
            if let Err(e) = unsafe { SetupDiEnumDeviceInfo(devinfo, index, &mut data) } {
                if e.code() == ERROR_NO_MORE_ITEMS.to_hresult() {
                    break;
                }
                return Err(e).context("SetupDiEnumDeviceInfo");
            }
            index += 1;
            let mut id = [0u16; 512];
            let mut needed = 0u32;
            unsafe {
                SetupDiGetDeviceInstanceIdW(devinfo, &data, Some(&mut id), Some(&mut needed))
            }
            .context("SetupDiGetDeviceInstanceIdW")?;
            let instance_id =
                String::from_utf16_lossy(&id[..id.iter().position(|&c| c == 0).unwrap_or(0)]);
            out.push(DevNode {
                instance_id,
                hardware_ids: hardware_ids(devinfo, &data),
            });
        }
        Ok(())
    })();
    unsafe {
        let _ = SetupDiDestroyDeviceInfoList(devinfo);
    }
    result?;
    Ok(out)
}

/// The node's REG_MULTI_SZ hardware ids; empty when it has none (root buses).
fn hardware_ids(
    devinfo: windows::Win32::Devices::DeviceAndDriverInstallation::HDEVINFO,
    data: &SP_DEVINFO_DATA,
) -> Vec<String> {
    let mut buf = vec![0u8; 4096];
    let mut needed = 0u32;
    let ok = unsafe {
        SetupDiGetDeviceRegistryPropertyW(
            devinfo,
            data,
            SPDRP_HARDWAREID,
            None,
            Some(&mut buf),
            Some(&mut needed),
        )
    };
    if ok.is_err() {
        return Vec::new();
    }
    let (pairs, _) = buf[..(needed as usize).min(buf.len())].as_chunks::<2>();
    let units: Vec<u16> = pairs.iter().map(|c| u16::from_le_bytes(*c)).collect();
    units
        .split(|&c| c == 0)
        .filter(|s| !s.is_empty())
        .map(String::from_utf16_lossy)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_list_round_trips_and_clears_when_empty() {
        let dir = std::env::temp_dir().join(format!("relay-devnode-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("physical-locked.txt");
        write_id_list(&file, &["A\\B\\1".into(), "C\\D\\2".into()]).unwrap();
        assert_eq!(
            read_id_list(&file),
            vec!["A\\B\\1".to_string(), "C\\D\\2".to_string()]
        );
        write_id_list(&file, &[]).unwrap();
        assert!(!file.exists());
        assert!(read_id_list(&file).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enumerates_present_devices() {
        // Any Windows box has at least the root enumerator and a monitor.
        let all = enumerate(None).unwrap();
        assert!(!all.is_empty());
        let monitors = enumerate(Some(&GUID_DEVCLASS_MONITOR)).unwrap();
        assert!(monitors
            .iter()
            .all(|m| m.instance_id.to_ascii_uppercase().starts_with("DISPLAY\\")));
    }
}
