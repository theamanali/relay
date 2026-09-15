//! Virtual display driver backends. The host needs one thing from a driver:
//! "plug in a monitor of this size on this GPU, unplug it later".
//!
//! * [`mtt::MttVdd`] — MikeTheTech's Virtual Display Driver (default): render
//!   GPU is selectable, modes are whatever we write into its settings file.
//! * [`parsec::ParsecVdd`] — parsec-vdd (fallback): instant IOCTL add/remove,
//!   but no GPU choice and only the ≤5 modes pre-registered in the registry.

pub mod mtt;
pub mod parsec;

use std::sync::Arc;

use anyhow::{bail, Result};
use clap::ValueEnum;

use crate::display::{Mode, Monitor};
use crate::gpu::GpuInfo;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DriverKind {
    /// MTT VDD if installed, else parsec-vdd
    Auto,
    Mtt,
    Parsec,
}

/// Handle to a plugged-in virtual monitor, returned by `attach` and consumed by `detach`.
#[derive(Debug)]
pub enum Attachment {
    Mtt { device_name: String },
    Parsec { index: u32, device_name: String },
}

pub trait VirtualDisplay: Send + Sync {
    fn name(&self) -> &'static str;

    /// PnP id the driver's monitors carry (e.g. `MTT1337`), as found in a
    /// monitor's `MONITOR\<id>\...` GDI id and in its `\\?\DISPLAY#<id>#...`
    /// device path.
    fn pnp_id(&self) -> &'static str;

    /// Whether this monitor belongs to this driver.
    fn is_virtual(&self, m: &Monitor) -> bool {
        m.has_pnp_id(self.pnp_id())
    }

    /// True if `attach` can create exactly the requested mode; false if the
    /// driver can only offer a fixed list (the caller then picks the closest).
    fn dynamic_modes(&self) -> bool;

    /// Make one virtual monitor exist, offering `mode` and rendered on `gpu`.
    /// It need not be on the desktop yet: the session activates it exclusively
    /// through `topology::exclusive`.
    fn attach(&self, mode: Mode, gpu: &GpuInfo) -> Result<(Attachment, Monitor)>;

    fn detach(&self, attachment: Attachment) -> Result<()>;

    /// Remove any monitor a previous (crashed) host left behind.
    fn cleanup(&self) -> Result<()>;
}

/// Open the requested backend, or the first one that is installed.
pub fn open(kind: DriverKind) -> Result<Arc<dyn VirtualDisplay>> {
    match kind {
        DriverKind::Mtt => Ok(Arc::new(mtt::MttVdd::detect()?)),
        DriverKind::Parsec => Ok(Arc::new(parsec::ParsecVdd::open()?)),
        DriverKind::Auto => {
            match mtt::MttVdd::detect() {
                Ok(d) => return Ok(Arc::new(d)),
                Err(e) => log::debug!("MTT VDD not available: {e:#}"),
            }
            match parsec::ParsecVdd::open() {
                Ok(d) => {
                    log::warn!(
                        "using parsec-vdd: it cannot pin the render GPU and only offers the modes \
                         registered in HKLM\\SOFTWARE\\Parsec\\vdd"
                    );
                    Ok(Arc::new(d))
                }
                Err(e) => {
                    log::debug!("parsec-vdd not available: {e:#}");
                    bail!(
                        "no virtual display driver found. Run tools/install-host.ps1 from an \
                         elevated PowerShell (installs MikeTheTech's Virtual Display Driver)"
                    )
                }
            }
        }
    }
}
