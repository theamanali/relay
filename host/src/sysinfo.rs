//! Facts about this PC that the Mac shows when hovering a host in its list.
//! Published in the mDNS TXT record, so they are visible to anyone on the
//! link — nothing here is secret, and nothing here is trusted by the client.

use std::net::IpAddr;

use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
use winreg::enums::HKEY_LOCAL_MACHINE;
use winreg::RegKey;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostFacts {
    /// e.g. "AMD Ryzen 9 7950X 16-Core Processor"
    pub cpu: String,
    /// Installed physical memory, whole GB, rounded to the nominal size.
    pub ram_gb: u32,
    /// The render GPU's DXGI name.
    pub gpu: String,
    /// e.g. "Windows 11 Pro 24H2 (build 26100)"
    pub os: String,
    /// Unicast IPv4 addresses, most useful first (link-local last).
    pub ips: Vec<String>,
}

impl HostFacts {
    pub fn gather(gpu_name: &str) -> Self {
        HostFacts {
            cpu: cpu_name().unwrap_or_default(),
            ram_gb: ram_gb().unwrap_or(0),
            gpu: gpu_name.to_string(),
            os: os_edition().unwrap_or_default(),
            ips: ipv4_addresses(),
        }
    }

    /// TXT record entries (`cpu`, `ram`, `gpu`, `os`, `ip`); empty values are
    /// left out so an older client's parsing sees nothing unexpected.
    pub fn txt_entries(&self) -> Vec<(String, String)> {
        let mut out = Vec::new();
        if !self.cpu.is_empty() {
            out.push(("cpu".into(), self.cpu.clone()));
        }
        if self.ram_gb > 0 {
            out.push(("ram".into(), self.ram_gb.to_string()));
        }
        if !self.gpu.is_empty() {
            out.push(("gpu".into(), self.gpu.clone()));
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
    fn empty_facts_publish_nothing() {
        assert!(HostFacts::default().txt_entries().is_empty());
        let facts = HostFacts {
            ram_gb: 32,
            ips: vec!["192.168.1.5".into()],
            ..Default::default()
        };
        assert_eq!(
            facts.txt_entries(),
            vec![("ram".to_string(), "32".to_string()), ("ip".to_string(), "192.168.1.5".to_string())]
        );
    }
}
