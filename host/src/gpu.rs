//! GPU enumeration and selection. The chosen GPU is what the virtual display is
//! rendered on (through the driver's render-adapter setting) and what encodes
//! the stream, so on a PC with an iGPU we must reliably pick the discrete card.

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

    /// Tie-breaker between adapters with the same amount of VRAM: prefer the
    /// vendor whose hardware encoder we trust most.
    fn rank(self) -> u8 {
        match self {
            Vendor::Nvidia => 3,
            Vendor::Amd => 2,
            Vendor::Intel => 1,
            Vendor::Other => 0,
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
    /// Index in DXGI adapter enumeration (what ffmpeg's `d3d11va=hw:N` refers to).
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

/// Pick the GPU to render and encode on. An explicit `want` (case-insensitive
/// substring of the adapter name) wins; otherwise the most dedicated VRAM, with
/// vendor as the tie-breaker. On every PC with an iGPU + discrete card this is
/// the discrete card.
pub fn choose(gpus: &[GpuInfo], want: Option<&str>) -> Result<GpuInfo> {
    if gpus.is_empty() {
        bail!("no hardware display adapters found");
    }
    if let Some(want) = want {
        let needle = want.to_lowercase();
        return gpus
            .iter()
            .find(|g| g.name.to_lowercase().contains(&needle))
            .cloned()
            .with_context(|| {
                format!(
                    "no GPU matches '{want}'; available: {}",
                    gpus.iter()
                        .map(|g| g.name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            });
    }
    // Never the integrated half of a hybrid pair; then the most VRAM; then vendor.
    Ok(gpus
        .iter()
        .max_by_key(|g| (!g.kind.hybrid_integrated, g.dedicated_vram, g.vendor.rank()))
        .cloned()
        .expect("non-empty"))
}

pub fn describe(gpus: &[GpuInfo], chosen: Option<&GpuInfo>) -> String {
    let mut s = String::new();
    for g in gpus {
        let mark = match chosen {
            Some(c) if c.luid == g.luid => " <- selected",
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
