//! Which desktop a thread works on. Desktop Duplication and `SendInput` only
//! work from a thread attached to the *input* desktop: `Default` normally,
//! `Winlogon` at the lock and login screens and during a UAC prompt. A
//! SYSTEM process in the interactive session (the worker under the Relay
//! service) may open `Winlogon`; a user process may not, which is why a
//! dev run cannot stream the lock screen.
//!
//! `SetThreadDesktop` fails for a thread that owns windows or hooks, so only
//! the capture and input threads bind; the tray thread never does.

use anyhow::{Context, Result};
use windows::Win32::Foundation::GENERIC_ALL;
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, SetThreadDesktop,
    DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS, UOI_NAME,
};

/// Attach the calling thread to the current input desktop. Returns its name.
pub fn bind_input_desktop() -> Result<String> {
    unsafe {
        let desktop = OpenInputDesktop(
            DESKTOP_CONTROL_FLAGS(0),
            false,
            DESKTOP_ACCESS_FLAGS(GENERIC_ALL.0),
        )
        .context("OpenInputDesktop")?;
        let result = SetThreadDesktop(desktop).context("SetThreadDesktop");
        let name = desktop_name(desktop);
        let _ = CloseDesktop(desktop);
        result?;
        Ok(name)
    }
}

/// Name of the current input desktop without binding to it ("Default",
/// "Winlogon", …), or "?" when it cannot be opened from here.
pub fn input_desktop_name() -> String {
    unsafe {
        match OpenInputDesktop(
            DESKTOP_CONTROL_FLAGS(0),
            false,
            DESKTOP_ACCESS_FLAGS(GENERIC_ALL.0),
        ) {
            Ok(desktop) => {
                let name = desktop_name(desktop);
                let _ = CloseDesktop(desktop);
                name
            }
            Err(_) => "?".to_string(),
        }
    }
}

unsafe fn desktop_name(desktop: windows::Win32::System::StationsAndDesktops::HDESK) -> String {
    let mut buf = [0u16; 64];
    let mut needed = 0u32;
    if GetUserObjectInformationW(
        windows::Win32::Foundation::HANDLE(desktop.0),
        UOI_NAME,
        Some(buf.as_mut_ptr().cast()),
        (buf.len() * 2) as u32,
        Some(&mut needed),
    )
    .is_err()
    {
        return "?".to_string();
    }
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}
