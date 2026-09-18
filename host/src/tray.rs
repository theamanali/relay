//! Notification-area icon: the host's only UI once it runs without a console.
//! Hover says "Relay"; a click opens a menu with the session status, the
//! pairing PIN (click to copy), New PIN, the paired Macs and Quit.
//!
//! The icon is the client's tower-and-MacBook glyph, rendered on the Mac into
//! `assets/relay-{light,dark}.ico` (see `assets/README.md`) and embedded here.
//! Windows does not tint tray icons, so there is one per taskbar theme.

use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    CloseHandle, HANDLE, HWND, LPARAM, LRESULT, RECT, WAIT_OBJECT_0, WPARAM,
};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::System::Threading::INFINITE;
use windows::Win32::UI::Shell::{
    Shell_NotifyIconGetRect, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP,
    NIM_ADD, NIM_DELETE, NIM_MODIFY, NIM_SETVERSION, NINF_KEY, NIN_SELECT, NOTIFYICONDATAW,
    NOTIFYICONIDENTIFIER, NOTIFYICON_VERSION_4,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreateIconFromResourceEx, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyIcon, DestroyMenu, DispatchMessageW, GetCursorPos, GetSystemMetrics, KillTimer,
    ModifyMenuW, MsgWaitForMultipleObjects, PeekMessageW, PostMessageW, PostQuitMessage,
    RegisterClassW, RegisterWindowMessageW, SetForegroundWindow, SetTimer, TrackPopupMenuEx,
    TranslateMessage, HICON, HMENU, LR_DEFAULTCOLOR, MF_BYCOMMAND, MF_CHECKED, MF_DISABLED,
    MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MSG, PM_REMOVE, QS_ALLINPUT, SM_CXSMICON,
    TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON, WINDOW_EX_STYLE, WM_APP,
    WM_CONTEXTMENU, WM_DESTROY, WM_ENDSESSION, WM_NULL, WM_QUIT, WM_SETTINGCHANGE, WM_TIMER,
    WNDCLASSW, WS_OVERLAPPED,
};
use winreg::enums::HKEY_CURRENT_USER;
use winreg::RegKey;

use crate::crypto::{fingerprint, PeerList};
use crate::status::HostStatus;

const ICON_LIGHT: &[u8] = include_bytes!("../assets/relay-light.ico");
const ICON_DARK: &[u8] = include_bytes!("../assets/relay-dark.ico");

/// Notification callback from the shell; `LOWORD(lParam)` carries the event.
const WM_TRAY: u32 = WM_APP + 1;
const ICON_ID: u32 = 1;
const ICON_RETRY_TIMER_ID: usize = 1;
const ICON_RETRY_MS: u32 = 1_000;
const MENU_REFRESH_TIMER_ID: usize = 2;
const MENU_REFRESH_MS: u32 = 100;
/// The icon was activated from the keyboard (shellapi.h has no name for it).
const NIN_KEYSELECT: u32 = NIN_SELECT | NINF_KEY;

// Menu command ids. Paired entries are inert, so they share one id.
const CMD_STATUS: u32 = 1;
const CMD_COPY_PIN: u32 = 2;
const CMD_NEW_PIN: u32 = 3;
const CMD_PAIRED: u32 = 4;
const CMD_QUIT: u32 = 5;

/// Everything the window procedure needs; stored in the window's user data.
struct Tray {
    hwnd: HWND,
    icon: HICON,
    status: Arc<Mutex<HostStatus>>,
    paired: Arc<Mutex<PeerList>>,
    on_quit: Box<dyn Fn()>,
    /// Explorer broadcasts this when it (re)starts: the icon must be re-added.
    taskbar_created: u32,
    /// `NIM_ADD` succeeded for the current Explorer instance.
    icon_added: bool,
    /// A popup menu's modal loop is running on this thread.
    menu_open: bool,
    /// The live popup and PIN text, present only during `TrackPopupMenuEx`.
    open_menu: Option<HMENU>,
    open_menu_pin: String,
}

/// Show the icon and run the message loop on the calling thread until the
/// window is destroyed. `on_quit` runs on Quit and on session end (logoff /
/// shutdown) and is expected not to return.
pub fn run(
    status: Arc<Mutex<HostStatus>>,
    paired: Arc<Mutex<PeerList>>,
    on_quit: impl Fn() + 'static,
) -> Result<()> {
    unsafe {
        let instance = GetModuleHandleW(None).context("GetModuleHandleW")?;
        let class = WNDCLASSW {
            lpfnWndProc: Some(wnd_proc),
            hInstance: instance.into(),
            lpszClassName: w!("RelayTray"),
            ..Default::default()
        };
        if RegisterClassW(&class) == 0 {
            return Err(anyhow!(
                "RegisterClassW failed: {}",
                windows::core::Error::from_win32()
            ));
        }
        // A real (hidden) top-level window, not HWND_MESSAGE: message-only
        // windows never receive the broadcasts this relies on (TaskbarCreated,
        // WM_SETTINGCHANGE, WM_ENDSESSION).
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("RelayTray"),
            w!("Relay"),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            None,
            None,
            instance,
            None,
        )
        .context("CreateWindowExW")?;

        let tray = Box::new(Tray {
            hwnd,
            icon: load_icon()?,
            status,
            paired,
            on_quit: Box::new(on_quit),
            taskbar_created: RegisterWindowMessageW(w!("TaskbarCreated")),
            icon_added: false,
            menu_open: false,
            open_menu: None,
            open_menu_pin: String::new(),
        });
        let tray = Box::into_raw(tray);
        set_user_data(hwnd, tray as isize);
        // No taskbar yet (the worker starts at the login screen, before
        // Explorer): not an error, the icon is added on TaskbarCreated.
        if let Err(e) = (*tray).add_icon() {
            log::info!("no notification area yet ({e:#}); the icon appears once Explorer is up");
            (*tray).start_icon_retry();
        }

        // Started by the service: it asks us to quit through this event
        // (Stop-Service, shutdown, session change), the same way as Quit.
        let quit_event = crate::service::open_quit_event();
        let handles: Vec<HANDLE> = quit_event.into_iter().collect();
        let mut msg = MSG::default();
        loop {
            let woke = MsgWaitForMultipleObjects(Some(&handles), false, INFINITE, QS_ALLINPUT);
            if !handles.is_empty() && woke == WAIT_OBJECT_0 {
                log::info!("quit requested by the Relay service");
                ((*tray).on_quit)();
            }
            let mut done = false;
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    done = true;
                    break;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            if done {
                break;
            }
        }
        for h in handles {
            let _ = CloseHandle(h);
        }
        drop(Box::from_raw(tray));
    }
    Ok(())
}

impl Tray {
    fn notify_data(&self) -> NOTIFYICONDATAW {
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.hwnd,
            uID: ICON_ID,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage: WM_TRAY,
            hIcon: self.icon,
            ..Default::default()
        };
        for (dst, src) in data.szTip.iter_mut().zip("Relay".encode_utf16()) {
            *dst = src;
        }
        data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        data
    }

    fn add_icon(&mut self) -> Result<()> {
        let data = self.notify_data();
        unsafe {
            if !Shell_NotifyIconW(NIM_ADD, &data).as_bool() {
                return Err(anyhow!("Shell_NotifyIconW(NIM_ADD) failed"));
            }
            // Version 4 delivers NIN_SELECT/NIN_KEYSELECT and the cursor
            // position in wParam instead of the legacy mouse messages alone.
            let _ = Shell_NotifyIconW(NIM_SETVERSION, &data);
            let _ = KillTimer(self.hwnd, ICON_RETRY_TIMER_ID);
        }
        self.icon_added = true;
        Ok(())
    }

    fn start_icon_retry(&self) {
        unsafe {
            if SetTimer(self.hwnd, ICON_RETRY_TIMER_ID, ICON_RETRY_MS, None) == 0 {
                log::warn!("could not start the tray icon retry timer");
            }
        }
    }

    fn remove_icon(&mut self) {
        let data = self.notify_data();
        unsafe {
            let _ = KillTimer(self.hwnd, ICON_RETRY_TIMER_ID);
            let _ = Shell_NotifyIconW(NIM_DELETE, &data);
        }
        self.icon_added = false;
    }

    /// The taskbar theme changed: swap to the icon drawn for it.
    fn reload_icon(&mut self) {
        match load_icon() {
            Ok(icon) => {
                let old = std::mem::replace(&mut self.icon, icon);
                let data = self.notify_data();
                unsafe {
                    let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
                    let _ = DestroyIcon(old);
                }
                log::info!(
                    "tray icon reloaded for a {} taskbar",
                    if taskbar_is_light() { "light" } else { "dark" }
                );
            }
            Err(e) => log::warn!("tray icon reload failed: {e:#}"),
        }
    }

    fn show_menu(&mut self) {
        // `TrackPopupMenuEx` runs a modal loop on this thread, and the shell
        // can queue a second activation for the same click; without this the
        // menu would pop straight back up after being dismissed.
        if self.menu_open {
            return;
        }
        self.menu_open = true;
        unsafe {
            let menu = match self.build_menu() {
                Ok(m) => m,
                Err(e) => {
                    log::warn!("tray menu failed: {e:#}");
                    self.menu_open = false;
                    return;
                }
            };
            self.open_menu = Some(menu);
            self.open_menu_pin = self.status.lock().unwrap().pin.clone();
            if SetTimer(self.hwnd, MENU_REFRESH_TIMER_ID, MENU_REFRESH_MS, None) == 0 {
                log::warn!("could not start the tray menu refresh timer");
            }
            // Anchor above the icon itself, not at the cursor: bottom-aligned
            // at the cursor puts the last item (Quit) under the pointer, and a
            // double-click or a click-to-dismiss then quits the host.
            let (x, y) = match self.icon_rect() {
                Some(r) => (r.left, r.top),
                None => {
                    let mut pt = Default::default();
                    let _ = GetCursorPos(&mut pt);
                    (pt.x, pt.y)
                }
            };
            // Without focus the menu would not close when the user clicks
            // elsewhere; the WM_NULL afterwards is the documented companion.
            let _ = SetForegroundWindow(self.hwnd);
            let cmd = TrackPopupMenuEx(
                menu,
                (TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_BOTTOMALIGN).0,
                x,
                y,
                self.hwnd,
                None,
            );
            let _ = KillTimer(self.hwnd, MENU_REFRESH_TIMER_ID);
            self.open_menu = None;
            self.open_menu_pin.clear();
            let _ = PostMessageW(self.hwnd, WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
            self.menu_open = false;
            self.command(cmd.0 as u32);
        }
    }

    /// Popup menu strings are snapshots. Keep the visible PIN current when a
    /// successful pairing rotates it on the server thread.
    fn refresh_open_menu(&mut self) {
        let Some(menu) = self.open_menu else { return };
        let pin = self.status.lock().unwrap().pin.clone();
        if pin == self.open_menu_pin {
            return;
        }
        let text = format!("PIN {}", spaced_pin(&pin));
        let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
        match unsafe {
            ModifyMenuW(
                menu,
                CMD_COPY_PIN,
                MF_BYCOMMAND | MF_STRING,
                CMD_COPY_PIN as usize,
                PCWSTR(wide.as_ptr()),
            )
        } {
            Ok(()) => self.open_menu_pin = pin,
            Err(e) => log::warn!("updating the open tray PIN failed: {e:#}"),
        }
    }

    /// Where the shell draws our icon (taskbar or overflow flyout).
    fn icon_rect(&self) -> Option<RECT> {
        let id = NOTIFYICONIDENTIFIER {
            cbSize: std::mem::size_of::<NOTIFYICONIDENTIFIER>() as u32,
            hWnd: self.hwnd,
            uID: ICON_ID,
            ..Default::default()
        };
        unsafe { Shell_NotifyIconGetRect(&id).ok() }
    }

    unsafe fn build_menu(&self) -> Result<HMENU> {
        let status = self.status.lock().unwrap();
        let menu = CreatePopupMenu().context("CreatePopupMenu")?;
        let line = match &status.session {
            Some(s) => format!(
                "Streaming to {} \u{2014} {}\u{00d7}{} @ {} Hz",
                s.client, s.width, s.height, s.hz
            ),
            None => "Idle".to_string(),
        };
        append(menu, MF_STRING | MF_DISABLED | MF_GRAYED, CMD_STATUS, &line)?;
        append(
            menu,
            MF_STRING,
            CMD_COPY_PIN,
            &format!("PIN {}", spaced_pin(&status.pin)),
        )?;
        if !status.pin_fixed {
            append(menu, MF_STRING, CMD_NEW_PIN, "New PIN")?;
        }
        append(menu, MF_SEPARATOR, 0, "")?;

        let paired = CreatePopupMenu().context("CreatePopupMenu")?;
        let list = self.paired.lock().unwrap();
        if list.is_empty() {
            append(
                paired,
                MF_STRING | MF_DISABLED | MF_GRAYED,
                CMD_PAIRED,
                "No paired Macs",
            )?;
        } else {
            let active = status.session.as_ref().map(|s| s.client_key);
            let mut entries: Vec<(String, String, bool)> = list
                .iter()
                .map(|(key, name)| {
                    let fp = fingerprint(key);
                    (name.clone(), fp, active == Some(*key))
                })
                .collect();
            entries.sort();
            for (name, fp, streaming) in entries {
                let flags = if streaming {
                    MF_STRING | MF_CHECKED
                } else {
                    MF_STRING
                };
                append(paired, flags, CMD_PAIRED, &format!("{name}  ({fp})"))?;
            }
        }
        AppendMenuW(menu, MF_POPUP, paired.0 as usize, w!("Paired Macs"))
            .context("AppendMenuW(popup)")?;
        // Under the service a quit is not final: the next sign-in starts a
        // new worker.
        let quit_label = if crate::service::open_quit_event()
            .map(|h| {
                let _ = CloseHandle(h);
            })
            .is_some()
        {
            "Quit Relay until next sign-in"
        } else {
            "Quit Relay"
        };
        append(menu, MF_SEPARATOR, 0, "")?;
        append(menu, MF_STRING, CMD_QUIT, quit_label)?;
        Ok(menu)
    }

    fn command(&mut self, cmd: u32) {
        match cmd {
            CMD_COPY_PIN => {
                let pin = self.status.lock().unwrap().pin.clone();
                if let Err(e) = copy_to_clipboard(self.hwnd, &pin) {
                    log::warn!("copying the PIN failed: {e:#}");
                }
            }
            CMD_NEW_PIN => match self.status.lock().unwrap().rotate_pin() {
                Ok(true) => log::info!("pairing PIN rotated from the tray"),
                Ok(false) => {}
                Err(e) => log::warn!("could not rotate the pairing PIN: {e:#}"),
            },
            CMD_QUIT => (self.on_quit)(),
            _ => {}
        }
    }
}

unsafe fn append(
    menu: HMENU,
    flags: windows::Win32::UI::WindowsAndMessaging::MENU_ITEM_FLAGS,
    id: u32,
    text: &str,
) -> Result<()> {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    AppendMenuW(menu, flags, id as usize, PCWSTR(wide.as_ptr())).context("AppendMenuW")
}

/// "123456" -> "123 456": easier to read across the room.
fn spaced_pin(pin: &str) -> String {
    let mid = pin.len().div_ceil(2);
    if pin.len() < 5 {
        return pin.to_string();
    }
    format!("{} {}", &pin[..mid], &pin[mid..])
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let tray = get_user_data(hwnd) as *mut Tray;
    if tray.is_null() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let tray = &mut *tray;
    match msg {
        WM_TRAY => {
            // Version 4 sends NIN_SELECT for a left click *as well as* the
            // legacy WM_LBUTTONUP; reacting to both would open the menu twice.
            let event = (lparam.0 & 0xffff) as u32;
            if matches!(event, WM_CONTEXTMENU | NIN_SELECT | NIN_KEYSELECT) {
                tray.show_menu();
            }
            LRESULT(0)
        }
        WM_SETTINGCHANGE => {
            // Light/dark switch: the section name arrives as a string.
            if lparam.0 != 0 {
                let section = PCWSTR(lparam.0 as *const u16);
                if section.to_string().is_ok_and(|s| s == "ImmersiveColorSet") {
                    tray.reload_icon();
                }
            }
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == ICON_RETRY_TIMER_ID => {
            if !tray.icon_added && tray.add_icon().is_ok() {
                log::info!("notification area is ready; tray icon added");
            }
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == MENU_REFRESH_TIMER_ID => {
            tray.refresh_open_menu();
            LRESULT(0)
        }
        WM_ENDSESSION => {
            // Logoff or shutdown while streaming: put the displays back now,
            // there is no next start to do it.
            if wparam.0 != 0 {
                tray.remove_icon();
                (tray.on_quit)();
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            tray.remove_icon();
            let _ = DestroyIcon(tray.icon);
            PostQuitMessage(0);
            LRESULT(0)
        }
        m if m == tray.taskbar_created => {
            tray.icon_added = false;
            if let Err(e) = tray.add_icon() {
                log::warn!("re-adding the tray icon failed: {e:#}");
                tray.start_icon_retry();
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// --- icon ------------------------------------------------------------------

/// Whether the taskbar is light (black glyph) or dark (white glyph).
fn taskbar_is_light() -> bool {
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
        .and_then(|k| k.get_value::<u32, _>("SystemUsesLightTheme"))
        .map(|v| v != 0)
        .unwrap_or(false)
}

fn load_icon() -> Result<HICON> {
    let bytes = if taskbar_is_light() {
        ICON_LIGHT
    } else {
        ICON_DARK
    };
    let want = unsafe { GetSystemMetrics(SM_CXSMICON) }.max(16) as u32;
    let (size, image) = pick_ico_entry(bytes, want)?;
    unsafe {
        CreateIconFromResourceEx(
            image,
            true,
            0x0003_0000,
            size as i32,
            size as i32,
            LR_DEFAULTCOLOR,
        )
        .context("CreateIconFromResourceEx")
    }
}

/// The `.ico` directory entry closest to `want` pixels (preferring larger):
/// its pixel size and image bytes (PNG or DIB, both fine for the loader).
fn pick_ico_entry(ico: &[u8], want: u32) -> Result<(u32, &[u8])> {
    let u16_at = |i: usize| u16::from_le_bytes([ico[i], ico[i + 1]]);
    let u32_at = |i: usize| u32::from_le_bytes([ico[i], ico[i + 1], ico[i + 2], ico[i + 3]]);
    if ico.len() < 6 || u16_at(0) != 0 || u16_at(2) != 1 {
        return Err(anyhow!("not an .ico file"));
    }
    let count = u16_at(4) as usize;
    let mut best: Option<(u32, &[u8])> = None;
    for n in 0..count {
        let entry = 6 + n * 16;
        if ico.len() < entry + 16 {
            break;
        }
        let size = match ico[entry] {
            0 => 256,
            w => w as u32,
        };
        let len = u32_at(entry + 8) as usize;
        let offset = u32_at(entry + 12) as usize;
        if ico.len() < offset + len {
            continue;
        }
        let image = &ico[offset..offset + len];
        let better = match best {
            None => true,
            Some((have, _)) => rank(size, want) < rank(have, want),
        };
        if better {
            best = Some((size, image));
        }
    }
    best.ok_or_else(|| anyhow!("no usable image in the .ico"))
}

/// Exact match first, then the nearest larger size, then the nearest smaller.
fn rank(size: u32, want: u32) -> (u8, u32) {
    if size == want {
        (0, 0)
    } else if size > want {
        (1, size - want)
    } else {
        (2, want - size)
    }
}

// --- clipboard -------------------------------------------------------------

fn copy_to_clipboard(hwnd: HWND, text: &str) -> Result<()> {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        OpenClipboard(hwnd).context("OpenClipboard")?;
        let result = (|| -> Result<()> {
            EmptyClipboard().context("EmptyClipboard")?;
            let handle = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2).context("GlobalAlloc")?;
            let dst = GlobalLock(handle) as *mut u16;
            if dst.is_null() {
                return Err(anyhow!("GlobalLock failed"));
            }
            std::ptr::copy_nonoverlapping(wide.as_ptr(), dst, wide.len());
            let _ = GlobalUnlock(handle);
            // The clipboard owns the memory from here on.
            SetClipboardData(
                CF_UNICODETEXT.0 as u32,
                windows::Win32::Foundation::HANDLE(handle.0),
            )
            .context("SetClipboardData")?;
            Ok(())
        })();
        let _ = CloseClipboard();
        result
    }
}

// --- window user data ------------------------------------------------------

unsafe fn set_user_data(hwnd: HWND, value: isize) {
    use windows::Win32::UI::WindowsAndMessaging::{SetWindowLongPtrW, GWLP_USERDATA};
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, value);
}

unsafe fn get_user_data(hwnd: HWND) -> isize {
    use windows::Win32::UI::WindowsAndMessaging::{GetWindowLongPtrW, GWLP_USERDATA};
    GetWindowLongPtrW(hwnd, GWLP_USERDATA)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_is_spaced_in_the_middle() {
        assert_eq!(spaced_pin("123456"), "123 456");
        assert_eq!(spaced_pin("1234567"), "1234 567");
        assert_eq!(spaced_pin("1234"), "1234");
    }

    fn ico(entries: &[(u8, &[u8])]) -> Vec<u8> {
        let mut out = vec![0, 0, 1, 0, entries.len() as u8, 0];
        let mut offset = 6 + 16 * entries.len();
        for (w, img) in entries {
            out.extend_from_slice(&[*w, *w, 0, 0, 1, 0, 32, 0]);
            out.extend_from_slice(&(img.len() as u32).to_le_bytes());
            out.extend_from_slice(&(offset as u32).to_le_bytes());
            offset += img.len();
        }
        for (_, img) in entries {
            out.extend_from_slice(img);
        }
        out
    }

    #[test]
    fn picks_exact_then_larger_then_smaller() {
        let file = ico(&[(16, b"a"), (32, b"bb"), (0, b"ccc")]);
        assert_eq!(pick_ico_entry(&file, 16).unwrap(), (16, &b"a"[..]));
        assert_eq!(pick_ico_entry(&file, 20).unwrap(), (32, &b"bb"[..]));
        assert_eq!(pick_ico_entry(&file, 300).unwrap(), (256, &b"ccc"[..]));
    }

    #[test]
    fn rejects_non_ico() {
        assert!(pick_ico_entry(b"\x89PNG", 16).is_err());
    }
}
