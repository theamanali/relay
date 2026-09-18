//! Relay host library: virtual display control, capture/encode, wire protocol.

pub mod crypto;
mod cursor_overlay;
pub mod desktop;
pub mod devnode;
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
pub mod service;
pub mod status;
pub mod sysinfo;
pub mod topology;
pub mod tray;

/// `%ProgramData%\Relay`: identity, PIN, paired clients, display snapshot,
/// host.log. Machine-wide, because the host runs as SYSTEM (the Relay
/// service) and the PC has one identity whoever is signed in. The installer
/// creates it with the right ACLs and migrates a user's old
/// `%LOCALAPPDATA%\Relay` into it.
pub fn state_dir() -> anyhow::Result<std::path::PathBuf> {
    use anyhow::Context;
    let base = std::env::var_os("ProgramData")
        .map(std::path::PathBuf::from)
        .context("ProgramData is not set")?;
    Ok(base.join("Relay"))
}

/// Files that make up the host's identity and pairings.
pub const STATE_FILES: [&str; 4] = [
    "identity.key",
    "paired-clients.txt",
    "pin.txt",
    "display-snapshot.bin",
];

/// One-time move from the per-user location the host used before it became
/// a service: when the machine-wide dir has no identity yet and this user's
/// `%LOCALAPPDATA%\Relay` has one, copy the state files over so the Mac's
/// pairing survives. Only meaningful when running as that user; the
/// installer does the same, elevated, for the installing user.
pub fn migrate_user_state() {
    let (Ok(dir), Some(local)) = (state_dir(), std::env::var_os("LOCALAPPDATA")) else {
        return;
    };
    let old = std::path::PathBuf::from(local).join("Relay");
    if dir.join("identity.key").exists() || !old.join("identity.key").exists() {
        return;
    }
    if let Err(e) = std::fs::create_dir_all(&dir) {
        log::warn!("could not create {}: {e}", dir.display());
        return;
    }
    for name in STATE_FILES {
        let from = old.join(name);
        if from.exists() {
            match std::fs::copy(&from, dir.join(name)) {
                Ok(_) => log::info!("moved {name} to {}", dir.display()),
                Err(e) => log::warn!("could not copy {}: {e}", from.display()),
            }
        }
    }
}

/// Make `path` readable by SYSTEM and administrators only (the identity key
/// lives in a directory everyone may read). Needs administrator rights;
/// silently a no-op without them, since then the file was not ours to lock.
pub fn restrict_to_admins(path: &std::path::Path) {
    if !devnode::is_admin() {
        return;
    }
    use std::os::windows::process::CommandExt;
    let result = std::process::Command::new("icacls.exe")
        .arg(path)
        .args([
            "/inheritance:r",
            "/grant:r",
            "SYSTEM:F",
            r"BUILTIN\Administrators:F",
        ])
        .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
        .output();
    match result {
        Ok(o) if o.status.success() => {}
        Ok(o) => log::warn!(
            "could not restrict {}: {}",
            path.display(),
            String::from_utf8_lossy(&o.stderr).trim()
        ),
        Err(e) => log::warn!("could not run icacls for {}: {e}", path.display()),
    }
}
