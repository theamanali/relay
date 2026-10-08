//! Facts about this PC that the Mac shows when hovering a host in its list.
//! Published in the mDNS TXT record, so they are visible to anyone on the
//! link — nothing here is secret, and nothing here is trusted by the client.

use std::net::IpAddr;

use windows::Win32::System::SystemInformation::{
    GetSystemFirmwareTable, GlobalMemoryStatusEx, MEMORYSTATUSEX, RSMB,
};

use crate::gpu::GpuInfo;
use winreg::enums::HKEY_LOCAL_MACHINE;
use winreg::RegKey;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostFacts {
    /// e.g. "AMD Ryzen 9 7950X 16-Core Processor"
    pub cpu: String,
    /// Installed physical memory, whole GB, rounded to the nominal size.
    pub ram_gb: u32,
    /// e.g. "DDR4-3600" from SMBIOS; empty when the table says nothing usable.
    pub ram_type: String,
    /// The render GPU's DXGI name.
    pub gpu: String,
    /// The render GPU's dedicated memory, whole GB.
    pub vram_gb: u32,
    /// e.g. "Windows 11 Pro 24H2 (build 26100)"
    pub os: String,
    /// Unicast IPv4 addresses, most useful first (link-local last).
    pub ips: Vec<String>,
}

impl HostFacts {
    pub fn gather(gpu: &GpuInfo) -> Self {
        HostFacts {
            cpu: cpu_name().unwrap_or_default(),
            ram_gb: ram_gb().unwrap_or(0),
            ram_type: smbios_table().map(|t| ram_type(&t)).unwrap_or_default(),
            gpu: gpu.name.clone(),
            vram_gb: (gpu.dedicated_vram as f64 / (1u64 << 30) as f64).round() as u32,
            os: os_edition().unwrap_or_default(),
            ips: ipv4_addresses(),
        }
    }

    /// TXT record entries (`cpu`, `ram`, `ramtype`, `gpu`, `vram`, `os`,
    /// `ip`); empty values are left out so an older client's parsing sees
    /// nothing unexpected.
    pub fn txt_entries(&self) -> Vec<(String, String)> {
        let mut out = Vec::new();
        if !self.cpu.is_empty() {
            out.push(("cpu".into(), self.cpu.clone()));
        }
        if self.ram_gb > 0 {
            out.push(("ram".into(), self.ram_gb.to_string()));
        }
        if !self.ram_type.is_empty() {
            out.push(("ramtype".into(), self.ram_type.clone()));
        }
        if !self.gpu.is_empty() {
            out.push(("gpu".into(), self.gpu.clone()));
        }
        if self.vram_gb > 0 {
            out.push(("vram".into(), self.vram_gb.to_string()));
        }
        if !self.os.is_empty() {
            out.push(("os".into(), self.os.clone()));
        }
        if !self.ips.is_empty() {
            out.push(("ip".into(), self.ips.join(",")));
        }
        out
    }
}

fn cpu_name() -> Option<String> {
    let key = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")
        .ok()?;
    let name: String = key.get_value("ProcessorNameString").ok()?;
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    (!name.is_empty()).then_some(name)
}

fn ram_gb() -> Option<u32> {
    let mut status = MEMORYSTATUSEX {
        dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
        ..Default::default()
    };
    unsafe { GlobalMemoryStatusEx(&mut status).ok()? };
    // Windows reports a little under the installed amount (reserved memory);
    // round to the nearest GB so 31.9 reads as 32.
    let gb = (status.ullTotalPhys as f64 / (1u64 << 30) as f64).round() as u32;
    (gb > 0).then_some(gb)
}

/// The raw SMBIOS table (`RawSMBIOSData` header followed by structures).
fn smbios_table() -> Option<Vec<u8>> {
    let needed = unsafe { GetSystemFirmwareTable(RSMB, 0, None) };
    if needed == 0 {
        return None;
    }
    let mut buf = vec![0u8; needed as usize];
    let written = unsafe { GetSystemFirmwareTable(RSMB, 0, Some(&mut buf)) };
    if written == 0 || written as usize > buf.len() {
        return None;
    }
    buf.truncate(written as usize);
    // Skip the 8-byte RawSMBIOSData header; the rest is the DMI table.
    (buf.len() > 8).then(|| buf[8..].to_vec())
}

/// "DDR4-3600" from the populated Type 17 (Memory Device) structures: the
/// module type, and the fastest configured speed when the modules agree.
fn ram_type(table: &[u8]) -> String {
    let mut kind: Option<&str> = None;
    let mut speed: u16 = 0;
    let mut i = 0;
    while i + 4 <= table.len() {
        let ty = table[i];
        let len = table[i + 1] as usize;
        if len < 4 || i + len > table.len() {
            break;
        }
        let s = &table[i..i + len];
        if ty == 127 {
            break; // end-of-table
        }
        if ty == 17 && len > 0x15 {
            let size = u16::from_le_bytes([s[0x0C], s[0x0D]]);
            if size != 0 {
                let name = match s[0x12] {
                    0x18 => Some("DDR3"),
                    0x1A => Some("DDR4"),
                    0x1B => Some("LPDDR"),
                    0x1C => Some("LPDDR2"),
                    0x1D => Some("LPDDR3"),
                    0x1E => Some("LPDDR4"),
                    0x22 => Some("DDR5"),
                    0x23 => Some("LPDDR5"),
                    _ => None,
                };
                if kind.is_none() {
                    kind = name;
                }
                // Configured speed (SMBIOS 3.0+, offset 0x20) is what the
                // modules actually run at; fall back to the rated speed.
                let configured = if len > 0x21 {
                    u16::from_le_bytes([s[0x20], s[0x21]])
                } else {
                    0
                };
                let rated = u16::from_le_bytes([s[0x15], s[0x16]]);
                let this = if configured != 0 { configured } else { rated };
                speed = speed.max(this);
            }
        }
        // Formatted area, then strings ending in a double NUL.
        let mut j = i + len;
        while j + 1 < table.len() && !(table[j] == 0 && table[j + 1] == 0) {
            j += 1;
        }
        i = j + 2;
    }
    match (kind, speed) {
        (Some(k), 0) => k.to_string(),
        (Some(k), s) => format!("{k}-{s}"),
        (None, _) => String::new(),
    }
}

fn os_edition() -> Option<String> {
    let key = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion")
        .ok()?;
    let product: String = key.get_value("ProductName").ok()?;
    let build: String = key.get_value("CurrentBuildNumber").ok()?;
    let version: String = key
        .get_value("DisplayVersion")
        .or_else(|_| key.get_value("ReleaseId"))
        .unwrap_or_default();
    Some(format_os(&product, &version, &build))
}

/// `ProductName` still says "Windows 10" on Windows 11; the build number is
/// what tells them apart (22000 and up).
fn format_os(product: &str, version: &str, build: &str) -> String {
    let mut product = product.to_string();
    if build.parse::<u32>().is_ok_and(|b| b >= 22000) {
        product = product.replacen("Windows 10", "Windows 11", 1);
    }
    let mut s = product;
    if !version.is_empty() {
        s.push(' ');
        s.push_str(version);
    }
    if !build.is_empty() {
        s.push_str(&format!(" (build {build})"));
    }
    s
}

pub fn ipv4_addresses() -> Vec<String> {
    let mut addrs: Vec<std::net::Ipv4Addr> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() {
            IpAddr::V4(v4) => Some(v4),
            IpAddr::V6(_) => None,
        })
        .collect();
    // Routable first, the 169.254 cable address last.
    addrs.sort_by_key(|a| a.is_link_local());
    addrs.dedup();
    addrs.iter().map(|a| a.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_11_is_named_by_build() {
        assert_eq!(
            format_os("Windows 10 Pro", "24H2", "26100"),
            "Windows 11 Pro 24H2 (build 26100)"
        );
        assert_eq!(
            format_os("Windows 10 Home", "22H2", "19045"),
            "Windows 10 Home 22H2 (build 19045)"
        );
    }

    #[test]
    fn ram_type_from_smbios_memory_devices() {
        // Two Type 17 structures (one empty slot), then end-of-table.
        let mut dev = vec![0u8; 0x28];
        dev[0] = 17;
        dev[1] = 0x28;
        dev[0x0C] = 0x00; // size 0x4000 MB
        dev[0x0D] = 0x40;
        dev[0x12] = 0x1A; // DDR4
        dev[0x15] = 0x40; // rated 3200
        dev[0x16] = 0x0C;
        dev[0x20] = 0x10; // configured 3600
        dev[0x21] = 0x0E;
        let mut table = dev.clone();
        table.extend_from_slice(b"BANK 0\0\0"); // strings + terminator
        let mut empty = dev.clone();
        empty[0x0C] = 0;
        empty[0x0D] = 0;
        table.extend_from_slice(&empty);
        table.extend_from_slice(&[0, 0]);
        table.extend_from_slice(&[127, 4, 0, 0, 0, 0]);
        assert_eq!(ram_type(&table), "DDR4-3600");
        assert_eq!(ram_type(&[]), "");
    }

    #[test]
    fn empty_facts_publish_nothing() {
        assert!(HostFacts::default().txt_entries().is_empty());
        let facts = HostFacts {
            ram_gb: 32,
            ips: vec!["192.168.1.5".into()],
            ..Default::default()
        };
        assert_eq!(
            facts.txt_entries(),
            vec![
                ("ram".to_string(), "32".to_string()),
                ("ip".to_string(), "192.168.1.5".to_string())
            ]
        );
    }
}
