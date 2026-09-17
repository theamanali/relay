//! Relay host library: virtual display control, capture/encode, wire protocol.

pub mod crypto;
mod cursor_overlay;
pub mod discovery;
pub mod display;
pub mod driver;
pub mod encoder;
pub mod gpu;
pub mod input;
mod native_nvenc;
mod nvenc_bindings;
pub mod protocol;
pub mod server;
pub mod sysinfo;
pub mod topology;

/// `%LOCALAPPDATA%\Relay`: identity, PIN, paired clients, display snapshot.
/// The host was called TravelDisplay; its directory is moved over once so
/// existing pairings survive the rename.
pub fn state_dir() -> anyhow::Result<std::path::PathBuf> {
    use anyhow::Context;
    let base = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .context("LOCALAPPDATA is not set")?;
    let dir = base.join("Relay");
    let old = base.join("TravelDisplay");
    if !dir.exists() && old.exists() {
        if let Err(error) = std::fs::rename(&old, &dir) {
            log::warn!("could not move {} to {}: {error}", old.display(), dir.display());
        }
    }
    Ok(dir)
}
