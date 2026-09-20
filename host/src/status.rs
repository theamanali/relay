//! What the tray shows: the pairing PIN and the session in progress. The
//! server writes it, the tray reads it when its menu opens; plain data behind
//! a mutex, no callbacks. The one thing that flows the other way is the
//! session's end request, an atomic the tray stores into and the stream
//! loop polls.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;

use crate::crypto::Key32;

/// `SessionInfo::end_request` value meaning "nobody asked".
pub const NO_END_REQUEST: u8 = u8::MAX;

/// `szTip` holds 128 UTF-16 units including the terminator.
const TOOLTIP_MAX_UTF16: usize = 127;

/// A client that is streaming right now.
#[derive(Clone, Debug)]
pub struct SessionInfo {
    pub client: String,
    pub client_key: Key32,
    pub width: u32,
    pub height: u32,
    pub hz: u32,
    /// A `stop_reason` the tray wants sent to the client, ending the session;
    /// `NO_END_REQUEST` otherwise.
    pub end_request: Arc<AtomicU8>,
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

    /// Ask the running session to stop with `reason`. False when idle.
    pub fn request_end(&self, reason: u8) -> bool {
        match &self.session {
            Some(s) => {
                s.end_request.store(reason, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }

    /// The tray menu's first line (the mode is in the log, not the menu).
    pub fn summary(&self) -> String {
        match &self.session {
            Some(s) => format!("Streaming to {}", s.client),
            None => "Idle".to_string(),
        }
    }

    /// The icon's hover text: just who, the menu has the mode. Kept within
    /// what `szTip` can hold by shortening the client's name.
    pub fn tooltip(&self) -> String {
        let Some(s) = &self.session else {
            return "Relay: Idle".to_string();
        };
        let prefix = "Relay: Streaming to ";
        let room = TOOLTIP_MAX_UTF16.saturating_sub(prefix.encode_utf16().count());
        format!("{prefix}{}", fit_utf16(&s.client, room))
    }
}

/// `text` if it fits in `max` UTF-16 units, else its start plus an ellipsis.
fn fit_utf16(text: &str, max: usize) -> String {
    if text.encode_utf16().count() <= max {
        return text.to_string();
    }
    let keep = max.saturating_sub(1);
    let mut out = String::new();
    let mut units = 0;
    for ch in text.chars() {
        units += ch.len_utf16();
        if units > keep {
            break;
        }
        out.push(ch);
    }
    out.push('\u{2026}');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(session: Option<SessionInfo>) -> HostStatus {
        let mut s = HostStatus::new("123456".into(), false, PathBuf::new());
        s.session = session;
        s
    }

    fn session(client: &str) -> SessionInfo {
        SessionInfo {
            client: client.to_string(),
            client_key: [7; 32],
            width: 3024,
            height: 1964,
            hz: 120,
            end_request: Arc::new(AtomicU8::new(NO_END_REQUEST)),
        }
    }

    #[test]
    fn idle_tooltip_and_summary() {
        let s = status(None);
        assert_eq!(s.tooltip(), "Relay: Idle");
        assert_eq!(s.summary(), "Idle");
        assert!(!s.request_end(0));
    }

    #[test]
    fn streaming_tooltip_and_summary_name_the_client() {
        let s = status(Some(session("Aman's MacBook")));
        assert_eq!(s.tooltip(), "Relay: Streaming to Aman's MacBook");
        assert_eq!(s.summary(), "Streaming to Aman's MacBook");
    }

    #[test]
    fn long_client_name_is_clamped_to_the_tip_limit() {
        let long = "M".repeat(200);
        let s = status(Some(session(&long)));
        let tip = s.tooltip();
        assert_eq!(tip.encode_utf16().count(), 127);
        assert!(tip.contains('…'));
        assert!(tip.starts_with("Relay: Streaming to MMM"));
    }

    #[test]
    fn end_request_reaches_the_session() {
        let s = status(Some(session("x")));
        let flag = Arc::clone(&s.session.as_ref().unwrap().end_request);
        assert!(s.request_end(4));
        assert_eq!(flag.load(Ordering::Relaxed), 4);
    }

    #[test]
    fn fit_counts_utf16_units() {
        assert_eq!(fit_utf16("abc", 3), "abc");
        assert_eq!(fit_utf16("abcd", 3), "ab…");
        // A surrogate pair is two units; it must not be split.
        assert_eq!(fit_utf16("a😀b", 3), "a…");
    }
}
