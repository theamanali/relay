//! GPU enumeration and selection. The chosen GPU is what the virtual display is
//! rendered on (through the driver's render-adapter setting) and what encodes
//! the stream. Only NVIDIA adapters are eligible; on a hybrid laptop that is
//! the discrete half, and the iGPU stays listed for diagnostics.

use std::ffi::c_void;
use std::mem::size_of;

use anyhow::{bail, Context, Result};
use windows::Wdk::Graphics::Direct3D::{
    D3DKMTCloseAdapter, D3DKMTOpenAdapterFromLuid, D3DKMTQueryAdapterInfo, D3DKMT_ADAPTERTYPE,
    D3DKMT_CLOSEADAPTER, D3DKMT_OPENADAPTERFROMLUID, D3DKMT_QUERYADAPTERINFO,
    KMTQAITYPE_ADAPTERTYPE,
};
use windows::Win32::Foundation::LUID;
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE,
};

use crate::display::wide_to_string;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vendor {
    Nvidia,
    Amd,
    Intel,
    Other,
}

impl Vendor {
    pub fn from_id(id: u32) -> Vendor {
        match id {
            0x10DE => Vendor::Nvidia,
            0x1002 | 0x1022 => Vendor::Amd,
            0x8086 => Vendor::Intel,
            _ => Vendor::Other,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Vendor::Nvidia => "NVIDIA",
            Vendor::Amd => "AMD",
            Vendor::Intel => "Intel",
            Vendor::Other => "other",
        }
    }
}

/// Adapter LUID: the stable identity DXGI, D3DKMT and the display driver all agree on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Luid {
    pub low: u32,
    pub high: i32,
}

impl From<LUID> for Luid {
    fn from(l: LUID) -> Self {
        Luid {
            low: l.LowPart,
            high: l.HighPart,
        }
    }
}

/// What the kernel-mode display stack knows about an adapter beyond DXGI's
/// description: whether it is one half of a hybrid (Optimus-style) pair, and
/// whether it is only the proxy adapter an indirect display driver registers —
/// that one mirrors the render GPU's name and VRAM, so DXGI alone can't tell
/// them apart.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AdapterKind {
    pub software: bool,
    pub hybrid_discrete: bool,
    pub hybrid_integrated: bool,
    pub indirect_display: bool,
}

fn adapter_kind(luid: LUID) -> Option<AdapterKind> {
    unsafe {
        let mut open = D3DKMT_OPENADAPTERFROMLUID {
            AdapterLuid: luid,
            hAdapter: 0,
        };
        if !D3DKMTOpenAdapterFromLuid(&mut open).is_ok() {
            return None;
        }
        let mut ty = D3DKMT_ADAPTERTYPE::default();
        let mut query = D3DKMT_QUERYADAPTERINFO {
            hAdapter: open.hAdapter,
            Type: KMTQAITYPE_ADAPTERTYPE,
            pPrivateDriverData: &mut ty as *mut _ as *mut c_void,
            PrivateDriverDataSize: size_of::<D3DKMT_ADAPTERTYPE>() as u32,
        };
        let status = D3DKMTQueryAdapterInfo(&mut query);
        let _ = D3DKMTCloseAdapter(&D3DKMT_CLOSEADAPTER {
            hAdapter: open.hAdapter,
        });
        if !status.is_ok() {
            return None;
        }
        // Bit layout of D3DKMT_ADAPTERTYPE (d3dkmthk.h): RenderSupported,
        // DisplaySupported, SoftwareDevice, PostDevice, HybridDiscrete,
        // HybridIntegrated, IndirectDisplayDevice, ...
        let v = ty.Anonymous.Value;
        Some(AdapterKind {
            software: v & (1 << 2) != 0,
            hybrid_discrete: v & (1 << 4) != 0,
            hybrid_integrated: v & (1 << 5) != 0,
            indirect_display: v & (1 << 6) != 0,
        })
    }
}

#[derive(Debug, Clone)]
pub struct GpuInfo {
    /// Index in DXGI adapter enumeration at the time it was read; it can move
    /// when the virtual display's proxy adapter comes and goes, so identity
    /// is the LUID.
    pub adapter_index: u32,
    /// DXGI description, e.g. "NVIDIA GeForce RTX 3080 Ti". This exact string is
    /// what the virtual display driver matches its render adapter against.
    pub name: String,
    pub vendor: Vendor,
    pub dedicated_vram: u64,
    pub luid: Luid,
    pub kind: AdapterKind,
}

impl GpuInfo {
    pub fn vram_gb(&self) -> f64 {
        self.dedicated_vram as f64 / (1024.0 * 1024.0 * 1024.0)
    }
}

/// All hardware adapters, in DXGI order (software/basic-render adapters skipped).
pub fn enumerate() -> Result<Vec<GpuInfo>> {
    let mut out = Vec::new();
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().context("CreateDXGIFactory1")?;
        let mut i = 0u32;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            let index = i;
            i += 1;
            let desc = adapter.GetDesc1().context("IDXGIAdapter1::GetDesc1")?;
            let software = desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0;
            if software || desc.VendorId == 0x1414 {
                continue; // Microsoft Basic Render Driver / WARP
            }
            let kind = adapter_kind(desc.AdapterLuid).unwrap_or_default();
            let name = wide_to_string(&desc.Description);
            if kind.software || kind.indirect_display {
                log::debug!("skipping DXGI adapter {index} '{name}' ({kind:?})");
                continue;
            }
            out.push(GpuInfo {
                adapter_index: index,
                name,
                vendor: Vendor::from_id(desc.VendorId),
                dedicated_vram: desc.DedicatedVideoMemory as u64,
                luid: desc.AdapterLuid.into(),
                kind,
            });
        }
    }
    Ok(out)
}

/// Relay encodes with NVENC only, so only a real NVIDIA adapter may render and
/// encode. Every other adapter stays in `enumerate` for diagnostics and for
/// telling which GPU a display is on. A NVIDIA vendor id does not prove NVENC
/// exists; `native_nvenc::query_caps` checks that.
pub fn eligible(gpu: &GpuInfo) -> bool {
    gpu.vendor == Vendor::Nvidia && !gpu.kind.software && !gpu.kind.indirect_display
}

/// Pick the GPU to render and encode on. An explicit `want` (case-insensitive
/// substring of the adapter name) must name an eligible NVIDIA adapter;
/// otherwise the eligible adapter with the most dedicated VRAM, the first in
/// DXGI order on a tie.
pub fn choose(gpus: &[GpuInfo], want: Option<&str>) -> Result<GpuInfo> {
    if gpus.is_empty() {
        bail!("no hardware display adapters found");
    }
    if let Some(want) = want {
        let needle = want.to_lowercase();
        let matched: Vec<&GpuInfo> = gpus
            .iter()
            .filter(|g| g.name.to_lowercase().contains(&needle))
            .collect();
        if matched.is_empty() {
            bail!("no GPU matches '{want}'; available: {}", names(gpus));
        }
        return matched
            .iter()
            .find(|g| eligible(g))
            .map(|g| (*g).clone())
            .with_context(|| {
                format!(
                    "--gpu '{want}' matches {}, but Relay encodes only on NVIDIA GPUs (NVENC)",
                    names(matched.iter().copied())
                )
            });
    }
    gpus.iter()
        .filter(|g| eligible(g))
        // Never the integrated half of a hybrid pair; then the most VRAM.
        .max_by_key(|g| {
            (
                !g.kind.hybrid_integrated,
                g.dedicated_vram,
                std::cmp::Reverse(g.adapter_index),
            )
        })
        .cloned()
        .with_context(|| {
            format!(
                "no NVIDIA GPU found; Relay encodes only with NVIDIA's NVENC. Adapters present: {}",
                names(gpus)
            )
        })
}

fn names<'a>(gpus: impl IntoIterator<Item = &'a GpuInfo>) -> String {
    gpus.into_iter()
        .map(|g| format!("{} ({})", g.name, g.vendor.label()))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The user-mode driver version DXGI reports, as Windows shows it.
pub fn umd_version(raw: i64) -> String {
    let part = |shift: u32| (raw >> shift) & 0xffff;
    format!("{}.{}.{}.{}", part(48), part(32), part(16), part(0))
}

/// NVIDIA's own numbering: the last digit of the third part and the fourth
/// part, 32.0.15.8180 → 581.80.
pub fn nvidia_driver_version(raw: i64) -> String {
    let digits = ((raw >> 16) & 0xffff) % 10 * 10_000 + (raw & 0xffff);
    format!("{}.{:02}", digits / 100, digits % 100)
}

/// The adapter's user-mode driver version, as DXGI reports it.
pub fn driver_version(luid: Luid) -> Option<i64> {
    use windows::core::Interface;
    use windows::Win32::Graphics::Dxgi::IDXGIDevice;
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let mut i = 0;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            i += 1;
            if adapter
                .GetDesc1()
                .is_ok_and(|d| Luid::from(d.AdapterLuid) == luid)
            {
                return adapter.CheckInterfaceSupport(&IDXGIDevice::IID).ok();
            }
        }
        None
    }
}

pub fn describe(gpus: &[GpuInfo], chosen: Option<&GpuInfo>) -> String {
    let mut s = String::new();
    for g in gpus {
        let mark = match chosen {
            Some(c) if c.luid == g.luid => " <- selected",
            _ if !eligible(g) => " (not NVIDIA: cannot encode)",
            _ => "",
        };
        let hybrid = if g.kind.hybrid_discrete {
            ", hybrid discrete"
        } else if g.kind.hybrid_integrated {
            ", hybrid integrated"
        } else {
            ""
        };
        s.push_str(&format!(
            "[{}] {}  ({}, {:.1} GB dedicated{}, LUID {:x}:{:x}){}\n",
            g.adapter_index,
            g.name,
            g.vendor.label(),
            g.vram_gb(),
            hybrid,
            g.luid.high,
            g.luid.low,
            mark
        ));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1024 * 1024 * 1024;

    fn gpu(index: u32, name: &str, vendor: Vendor, vram_gb: u64) -> GpuInfo {
        GpuInfo {
            adapter_index: index,
            name: name.into(),
            vendor,
            dedicated_vram: vram_gb * GB,
            luid: Luid {
                low: 0x1000 + index,
                high: 0,
            },
            kind: AdapterKind::default(),
        }
    }

    fn rtx() -> GpuInfo {
        gpu(0, "NVIDIA GeForce RTX 3080 Ti", Vendor::Nvidia, 12)
    }

    #[test]
    fn an_amd_card_with_more_vram_does_not_win() {
        let gpus = [rtx(), gpu(1, "AMD Radeon RX 7900 XTX", Vendor::Amd, 24)];
        assert_eq!(choose(&gpus, None).unwrap().luid, gpus[0].luid);
    }

    #[test]
    fn a_hybrid_laptop_uses_the_nvidia_half() {
        let mut igpu = gpu(0, "Intel(R) UHD Graphics", Vendor::Intel, 0);
        igpu.kind.hybrid_integrated = true;
        let mut dgpu = gpu(1, "NVIDIA GeForce RTX 4070 Laptop GPU", Vendor::Nvidia, 8);
        dgpu.kind.hybrid_discrete = true;
        let gpus = [igpu, dgpu];
        assert_eq!(choose(&gpus, None).unwrap().luid, gpus[1].luid);
    }

    #[test]
    fn no_nvidia_gpu_is_an_error_that_names_the_adapters() {
        let gpus = [
            gpu(0, "AMD Radeon RX 7900 XTX", Vendor::Amd, 24),
            gpu(1, "Intel(R) Arc(TM) A770", Vendor::Intel, 16),
        ];
        let error = format!("{:#}", choose(&gpus, None).unwrap_err());
        assert!(error.contains("NVIDIA"), "{error}");
        assert!(error.contains("AMD Radeon RX 7900 XTX"), "{error}");
        assert!(error.contains("Intel(R) Arc(TM) A770"), "{error}");
    }

    #[test]
    fn an_explicit_non_nvidia_gpu_is_refused() {
        let gpus = [rtx(), gpu(1, "AMD Radeon RX 7900 XTX", Vendor::Amd, 24)];
        let error = format!("{:#}", choose(&gpus, Some("radeon")).unwrap_err());
        assert!(error.contains("AMD Radeon RX 7900 XTX"), "{error}");
        assert!(error.contains("NVIDIA"), "{error}");
    }

    #[test]
    fn an_explicit_name_that_matches_nothing_is_refused() {
        let gpus = [rtx()];
        let error = format!("{:#}", choose(&gpus, Some("quadro")).unwrap_err());
        assert!(error.contains("quadro"), "{error}");
        assert!(error.contains("NVIDIA GeForce RTX 3080 Ti"), "{error}");
    }

    #[test]
    fn an_explicit_name_prefers_its_nvidia_match() {
        // "Graphics" matches both; only the NVIDIA one may encode.
        let gpus = [
            gpu(0, "Intel(R) UHD Graphics", Vendor::Intel, 0),
            gpu(1, "NVIDIA RTX A2000 Graphics", Vendor::Nvidia, 6),
        ];
        assert_eq!(choose(&gpus, Some("graphics")).unwrap().luid, gpus[1].luid);
    }

    #[test]
    fn several_nvidia_gpus_pick_the_most_vram_then_the_first() {
        let gpus = [
            gpu(0, "NVIDIA GeForce RTX 3060", Vendor::Nvidia, 12),
            gpu(1, "NVIDIA GeForce RTX 4090", Vendor::Nvidia, 24),
            gpu(2, "NVIDIA GeForce RTX 4090", Vendor::Nvidia, 24),
        ];
        assert_eq!(choose(&gpus, None).unwrap().luid, gpus[1].luid);
        assert_eq!(choose(&gpus, Some("3060")).unwrap().luid, gpus[0].luid);
    }

    #[test]
    fn the_indirect_display_proxy_is_never_chosen() {
        // The proxy copies the render GPU's name and VRAM; only the kernel
        // adapter type tells it apart.
        let mut proxy = rtx();
        proxy.adapter_index = 1;
        proxy.luid.low = 0x2000;
        proxy.kind.indirect_display = true;
        let gpus = [proxy, rtx()];
        assert_eq!(choose(&gpus, None).unwrap().luid, gpus[1].luid);
        assert_eq!(choose(&gpus, Some("3080")).unwrap().luid, gpus[1].luid);
    }

    #[test]
    fn driver_versions_read_like_the_vendors_own() {
        // 32.0.15.8180 is what Windows shows for NVIDIA 581.80.
        let raw = (32i64 << 48) | (15 << 16) | 8180;
        assert_eq!(umd_version(raw), "32.0.15.8180");
        assert_eq!(nvidia_driver_version(raw), "581.80");
        let raw = (31i64 << 48) | (15 << 16) | 3742;
        assert_eq!(nvidia_driver_version(raw), "537.42");
        let raw = (32i64 << 48) | (16 << 16) | 105;
        assert_eq!(nvidia_driver_version(raw), "601.05");
    }

    #[test]
    fn describe_lists_every_adapter_and_marks_the_ineligible() {
        let gpus = [rtx(), gpu(1, "Intel(R) UHD Graphics", Vendor::Intel, 0)];
        let text = describe(&gpus, Some(&gpus[0]));
        assert!(
            text.contains("RTX 3080 Ti") && text.contains("<- selected"),
            "{text}"
        );
        assert!(
            text.contains("UHD Graphics") && text.contains("not NVIDIA"),
            "{text}"
        );
    }
}
