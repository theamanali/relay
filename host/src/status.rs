//! What the tray shows: the pairing PIN and the session in progress. The
//! server writes it, the tray reads it when its menu opens; plain data behind
//! a mutex, no callbacks.

use std::path::PathBuf;

use crate::crypto::Key32;

/// A client that is streaming right now.
#[derive(Clone, Debug)]
pub struct SessionInfo {
    pub client: String,
    pub client_key: Key32,
    pub width: u32,
    pub height: u32,
    pub hz: u32,
}

#[derive(Debug)]
pub struct HostStatus {
    /// PIN a new client must present.
    pub pin: String,
    /// `--pin` was given: never rotate it.
    pub pin_fixed: bool,
    /// Where a rotated PIN is written so `relay-host pin` agrees with the tray.
    pub pin_path: PathBuf,
    pub session: Option<SessionInfo>,
}

impl HostStatus {
    pub fn new(pin: String, pin_fixed: bool, pin_path: PathBuf) -> Self {
        HostStatus {
            pin,
            pin_fixed,
            pin_path,
            session: None,
        }
    }

    /// Replace the PIN unless `--pin` fixed it. Returns whether it changed.
    pub fn rotate_pin(&mut self) -> anyhow::Result<bool> {
        if self.pin_fixed {
            return Ok(false);
        }
        self.pin = crate::crypto::rotate_pin(&self.pin_path)?;
        Ok(true)
    }
}
