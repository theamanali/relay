//! Which desktop a thread works on. Desktop Duplication and `SendInput` only
//! work from a thread attached to the *input* desktop: `Default` normally,
//! `Winlogon` at the lock and login screens and during a UAC prompt. A
//! SYSTEM process in the interactive session (the worker under the Relay
//! service) may open `Winlogon`; a user process may not, which is why a
//! dev run cannot stream the lock screen.
//!
//! `SetThreadDesktop` fails for a thread that owns windows or hooks, so only
//! capture/input threads bind directly. Topology uses a fresh, scoped thread
//! so even cleanup requested by the tray can bind without moving its windows.

use anyhow::{bail, Context, Result};
use windows::Win32::Foundation::{GENERIC_ALL, HANDLE};
use windows::Win32::System::RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetProcessWindowStation, GetThreadDesktop, GetUserObjectInformationW,
    OpenInputDesktop, SetThreadDesktop, DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS, HDESK,
    UOI_NAME,
};
use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};

pub fn process_session_id() -> Result<u32> {
    let mut session = 0;
    unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) }
        .context("ProcessIdToSessionId")?;
    Ok(session)
}

/// Read-only context for display failures; preserve the actual API error too.
pub fn context_description() -> String {
    unsafe {
        let station = GetProcessWindowStation()
            .map(|h| object_name(HANDLE(h.0)))
            .unwrap_or_else(|e| format!("unavailable ({e})"));
        let desktop = GetThreadDesktop(GetCurrentThreadId())
            .map(|h| desktop_name(h))
            .unwrap_or_else(|e| format!("unavailable ({e})"));
        format!(
            "pid={} tid={} session={:?} console={} station={station} thread-desktop={desktop} input-desktop={}",
            GetCurrentProcessId(), GetCurrentThreadId(), process_session_id().ok(),
            WTSGetActiveConsoleSessionId(), input_desktop_name()
        )
    }
}

fn check_console(session: u32, console: u32) -> Result<()> {
    if session == 0 || console == u32::MAX || session != console {
        bail!("display context is not the active console: session={session}, console={console}");
    }
    Ok(())
}

/// A new thread has no windows/hooks and may bind even when called by the tray.
/// Never change the process window station (shared with capture, input and UI).
/// Reopen the input desktop for each operation: it can change during a stream.
pub fn with_input_desktop<T: Send>(
    operation: &str,
    work: impl FnOnce() -> Result<T> + Send,
) -> Result<T> {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("display-topology".into())
            .spawn_scoped(scope, || {
                log::info!("{operation}: before binding: {}", context_description());
                let result = (|| {
                    check_console(process_session_id()?, unsafe {
                        WTSGetActiveConsoleSessionId()
                    })?;
                    let _binding = DesktopBinding::open()?;
                    log::info!("{operation}: bound: {}", context_description());
                    work().with_context(|| format!("{operation}; {}", context_description()))
                })();
                if let Err(e) = &result {
                    log::warn!("{operation}: {e:#}; {}", context_description());
                }
                result
            })
            .context("starting topology thread")?
            .join()
            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
    })
}

/// Keep the opened handle alive while bound; CloseDesktop fails on a handle
/// still used by a thread. Return to the borrowed original handle before closing.
struct DesktopBinding {
    original: HDESK,
    opened: HDESK,
}

impl DesktopBinding {
    fn open() -> Result<Self> {
        unsafe {
            let station = object_name(HANDLE(GetProcessWindowStation()?.0));
            if !station.eq_ignore_ascii_case("WinSta0") {
                bail!("topology requires WinSta0, process window station is {station}");
            }
            let original = GetThreadDesktop(GetCurrentThreadId()).context("GetThreadDesktop")?;
            let opened = OpenInputDesktop(
                DESKTOP_CONTROL_FLAGS(0),
                false,
                DESKTOP_ACCESS_FLAGS(GENERIC_ALL.0),
            )
            .context("OpenInputDesktop for topology")?;
            if let Err(e) = SetThreadDesktop(opened) {
                let _ = CloseDesktop(opened);
                return Err(e).context("SetThreadDesktop for topology");
            }
            Ok(Self { original, opened })
        }
    }
}

impl Drop for DesktopBinding {
    fn drop(&mut self) {
        unsafe {
            if let Err(e) = SetThreadDesktop(self.original) {
                log::warn!("returning topology thread to original desktop: {e}");
            }
            if let Err(e) = CloseDesktop(self.opened) {
                log::warn!("closing topology desktop: {e}");
            }
        }
    }
}

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
    object_name(HANDLE(desktop.0))
}

unsafe fn object_name(handle: HANDLE) -> String {
    let mut buf = [0u16; 64];
    let mut needed = 0u32;
    if GetUserObjectInformationW(
        handle,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topology_requires_an_active_non_service_console_session() {
        assert!(check_console(1, 1).is_ok());
        assert!(check_console(2, 2).is_ok()); // new login session after sign-out
        assert!(check_console(1, 2).is_err()); // old worker must not change new console
        assert!(check_console(0, 0).is_err());
        assert!(check_console(1, u32::MAX).is_err()); // console changing
    }

    #[test]
    #[ignore = "requires an interactive Windows desktop; read-only, no display changes"]
    fn topology_binding_is_scoped_and_errors_propagate() {
        use windows::core::w;
        use windows::Win32::UI::WindowsAndMessaging::{
            CreateWindowExW, DestroyWindow, WINDOW_EX_STYLE, WINDOW_STYLE,
        };

        // Emulate the tray: a calling thread with a window cannot move desktops.
        // This window is never shown and no display configuration is changed.
        let window = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                w!("Relay topology test"),
                WINDOW_STYLE(0),
                0,
                0,
                1,
                1,
                None,
                None,
                None,
                None,
            )
        }
        .unwrap();
        let before = context_description();
        let caller = unsafe { GetCurrentThreadId() };
        with_input_desktop("binding smoke test", || {
            assert_ne!(unsafe { GetCurrentThreadId() }, caller);
            let current = unsafe { desktop_name(GetThreadDesktop(GetCurrentThreadId())?) };
            assert_eq!(current, input_desktop_name());
            Ok(())
        })
        .unwrap();
        let error = with_input_desktop("binding error test", || -> Result<()> {
            bail!("deliberate test error")
        })
        .unwrap_err();
        assert!(format!("{error:#}").contains("deliberate test error"));
        assert_eq!(before, context_description());
        // Also exercise the real read-only CCD query from this window-owning caller.
        assert!(!crate::topology::Snapshot::take().unwrap().paths.is_empty());
        unsafe {
            DestroyWindow(window).unwrap();
        }
    }
}
