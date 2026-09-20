//! Notification-area icon: the host's only UI once it runs without a console.
//! Hover says what the host is doing; a click opens a menu with the session
//! status (and Disconnect while streaming), the pairing PIN (click to copy),
//! Get new PIN, a Forget paired MacBook submenu, Start on system boot and Exit.
//!
//! The icon is the client's tower-and-MacBook glyph, rendered on the Mac into
//! `assets/relay-{light,dark}.ico` (see `assets/README.md`) and embedded here.
//! Windows does not tint tray icons, so there is one per taskbar theme; the
//! menu follows the same theme through `menu_theme`.

use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    CloseHandle, HANDLE, HWND, LPARAM, LRESULT, RECT, WAIT_OBJECT_0, WPARAM,
};
use windows::Win32::Graphics::Gdi::InvalidateRect;
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::System::Threading::{GetCurrentThreadId, INFINITE};
use windows::Win32::UI::Input::KeyboardAndMouse::VK_RETURN;
use windows::Win32::UI::Shell::{
    Shell_NotifyIconGetRect, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP,
    NIM_ADD, NIM_DELETE, NIM_MODIFY, NIM_SETVERSION, NINF_KEY, NIN_SELECT, NOTIFYICONDATAW,
    NOTIFYICONIDENTIFIER, NOTIFYICON_VERSION_4,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CallNextHookEx, CreateIconFromResourceEx, CreatePopupMenu, CreateWindowExW,
    DefWindowProcW, DestroyIcon, DestroyMenu, DispatchMessageW, FindWindowExW, GetCursorPos,
    GetMenuItemID, GetSystemMetrics, GetWindowThreadProcessId, KillTimer, MenuItemFromPoint,
    MessageBoxW, ModifyMenuW, MsgWaitForMultipleObjects, PeekMessageW, PostMessageW,
    PostQuitMessage, RegisterClassW, RegisterWindowMessageW, SetForegroundWindow, SetTimer,
    SetWindowsHookExW, TrackPopupMenuEx, TranslateMessage, UnhookWindowsHookEx, HICON, HMENU,
    IDYES, LR_DEFAULTCOLOR, MB_DEFBUTTON2, MB_ICONQUESTION, MB_SETFOREGROUND, MB_YESNO,
    MF_BYCOMMAND, MF_CHECKED, MF_DISABLED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MSG,
    MSGF_MENU, PM_REMOVE, QS_ALLINPUT, SM_CXSMICON, TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RETURNCMD,
    TPM_RIGHTBUTTON, WH_MSGFILTER, WINDOW_EX_STYLE, WM_APP, WM_CONTEXTMENU, WM_DESTROY,
    WM_ENDSESSION, WM_KEYDOWN, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MENUSELECT, WM_NULL, WM_QUIT,
    WM_SETTINGCHANGE, WM_TIMER, WNDCLASSW, WS_OVERLAPPED,
};
use winreg::enums::HKEY_CURRENT_USER;
use winreg::RegKey;

use crate::crypto::{fingerprint, Key32, PeerList};
use crate::protocol::stop_reason;
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
/// The tooltip follows the session; a second's lag is invisible on hover.
const STATUS_TIMER_ID: usize = 3;
const STATUS_REFRESH_MS: u32 = 1_000;
/// The icon was activated from the keyboard (shellapi.h has no name for it).
const NIN_KEYSELECT: u32 = NIN_SELECT | NINF_KEY;

// Menu command ids.
const CMD_STATUS: u32 = 1;
const CMD_COPY_PIN: u32 = 2;
const CMD_NEW_PIN: u32 = 3;
const CMD_NO_PAIRED: u32 = 4;
const CMD_EXIT: u32 = 5;
const CMD_DISCONNECT: u32 = 6;
const CMD_START_ON_BOOT: u32 = 7;
/// `CMD_FORGET_BASE + n` forgets the n-th entry of `Tray::open_menu_peers`.
const CMD_FORGET_BASE: u32 = 100;

/// Everything the window procedure needs; stored in the window's user data.
struct Tray {
    hwnd: HWND,
    icon: HICON,
    /// What the icon says on hover; `refresh_tip` keeps it current.
    tip: String,
    status: Arc<Mutex<HostStatus>>,
    paired: Arc<Mutex<PeerList>>,
    on_quit: Box<dyn Fn()>,
    /// Spawned by the Relay service (the quit event exists): Exit stops the
    /// service and Start on system boot is live.
    under_service: bool,
    /// Explorer broadcasts this when it (re)starts: the icon must be re-added.
    taskbar_created: u32,
    /// `NIM_ADD` succeeded for the current Explorer instance.
    icon_added: bool,
    /// A popup menu's modal loop (or the Forget confirmation) is running on
    /// this thread.
    menu_open: bool,
    /// The live popup and PIN text, present only during `TrackPopupMenuEx`.
    open_menu: Option<HMENU>,
    open_menu_pin: String,
    /// The Forget submenu's entries, in command-id order.
    open_menu_peers: Vec<(Key32, String)>,
    /// Command id under the highlight in the open menu (`WM_MENUSELECT`), so
    /// the filter hook knows what Return would choose.
    highlighted: u32,
}

thread_local! {
    /// The tray whose menu is open, for `menu_filter` (hooks carry no
    /// context). Only the tray thread installs the hook.
    static HOOK_TRAY: std::cell::Cell<*mut Tray> = const { std::cell::Cell::new(std::ptr::null_mut()) };
}

/// `WH_MSGFILTER` on the tray thread: sees the popup menu's input before
/// the menu's modal loop does; nonzero swallows the message.
unsafe extern "system" fn menu_filter(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == MSGF_MENU as i32 {
        let tray = HOOK_TRAY.with(|t| t.get());
        if !tray.is_null() && (*tray).filter_menu_message(&*(lparam.0 as *const MSG)) {
            return LRESULT(1);
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// Show the icon and run the message loop on the calling thread until the
/// window is destroyed. `on_quit` runs on Exit (via the service's quit event
/// when there is one), on that event alone, and on session end (logoff /
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

        // Started by the service: it asks us to quit through this event
        // (Stop-Service, shutdown, session change) — and Exit goes through
        // it too, by asking the SCM to stop the service.
        let quit_event = crate::service::open_quit_event();

        menu_theme::apply();
        let tip = status.lock().unwrap().tooltip();
        let tray = Box::new(Tray {
            hwnd,
            icon: load_icon()?,
            tip,
            status,
            paired,
            on_quit: Box::new(on_quit),
            under_service: quit_event.is_some(),
            taskbar_created: RegisterWindowMessageW(w!("TaskbarCreated")),
            icon_added: false,
            menu_open: false,
            open_menu: None,
            open_menu_pin: String::new(),
            open_menu_peers: Vec::new(),
            highlighted: 0,
        });
        let tray = Box::into_raw(tray);
        set_user_data(hwnd, tray as isize);
        // No taskbar yet (the worker starts at the login screen, before
        // Explorer): not an error, the icon is added on TaskbarCreated.
        if let Err(e) = (*tray).add_icon() {
            log::info!("no notification area yet ({e:#}); the icon appears once Explorer is up");
            (*tray).start_icon_retry();
        }
        if SetTimer(hwnd, STATUS_TIMER_ID, STATUS_REFRESH_MS, None) == 0 {
            log::warn!(
                "could not start the tray status timer; the tooltip will not follow the session"
            );
        }

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
        // `HostStatus::tooltip` already fits the 127 units; the zip is the
        // last line of defence against overrunning the terminator.
        let room = data.szTip.len() - 1;
        for (dst, src) in data
            .szTip
            .iter_mut()
            .zip(self.tip.encode_utf16().take(room))
        {
            *dst = src;
        }
        data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        data
    }

    /// Re-read the session and push a changed tooltip to the shell.
    fn refresh_tip(&mut self) {
        let tip = self.status.lock().unwrap().tooltip();
        if tip == self.tip {
            return;
        }
        self.tip = tip;
        if self.icon_added {
            let data = self.notify_data();
            unsafe {
                let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
            }
        }
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
            self.highlighted = 0;
            if SetTimer(self.hwnd, MENU_REFRESH_TIMER_ID, MENU_REFRESH_MS, None) == 0 {
                log::warn!("could not start the tray menu refresh timer");
            }
            // Get new PIN must not close the menu (the point is to read the
            // new PIN). A popup closes on any choice, so a message-filter
            // hook on this thread intercepts that one item's click/Return,
            // rotates the PIN and relabels the open item instead.
            HOOK_TRAY.with(|t| t.set(self as *mut Tray));
            let hook =
                SetWindowsHookExW(WH_MSGFILTER, Some(menu_filter), None, GetCurrentThreadId())
                    .map_err(|e| {
                        log::debug!("no menu filter hook ({e}); Get new PIN closes the menu")
                    })
                    .ok();
            // Anchor above the icon itself, not at the cursor: bottom-aligned
            // at the cursor puts the last item (Exit) under the pointer, and a
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
            if let Some(hook) = hook {
                let _ = UnhookWindowsHookEx(hook);
            }
            HOOK_TRAY.with(|t| t.set(std::ptr::null_mut()));
            let _ = KillTimer(self.hwnd, MENU_REFRESH_TIMER_ID);
            self.open_menu = None;
            self.open_menu_pin.clear();
            let _ = PostMessageW(self.hwnd, WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
            // `menu_open` stays set through the command: Forget shows a
            // modal box, and a click on the icon meanwhile must not stack a
            // menu on top of it.
            self.command(cmd.0 as u32);
            self.open_menu_peers.clear();
            self.menu_open = false;
        }
    }

    /// The message-filter hook's view of a menu message: true to swallow it.
    /// Only Get new PIN is handled here; everything else closes the menu as
    /// usual through `TrackPopupMenuEx`.
    unsafe fn filter_menu_message(&mut self, msg: &MSG) -> bool {
        let Some(menu) = self.open_menu else {
            return false;
        };
        let on_new_pin = match msg.message {
            WM_LBUTTONDOWN | WM_LBUTTONUP => {
                let item = MenuItemFromPoint(None, menu, msg.pt);
                item >= 0 && GetMenuItemID(menu, item) == CMD_NEW_PIN
            }
            WM_KEYDOWN if msg.wParam.0 as u16 == VK_RETURN.0 => self.highlighted == CMD_NEW_PIN,
            _ => false,
        };
        if !on_new_pin {
            return false;
        }
        // Act on the release (and on Return); the press is only swallowed so
        // the menu never sees half a click.
        if msg.message != WM_LBUTTONDOWN {
            match self.status.lock().unwrap().rotate_pin() {
                Ok(true) => log::info!("pairing PIN rotated from the tray"),
                Ok(false) => {}
                Err(e) => log::warn!("could not rotate the pairing PIN: {e:#}"),
            }
            self.refresh_open_menu();
        }
        true
    }

    /// Popup menu strings are snapshots. Keep the visible PIN current when a
    /// successful pairing rotates it on the server thread.
    fn refresh_open_menu(&mut self) {
        let Some(menu) = self.open_menu else { return };
        let pin = self.status.lock().unwrap().pin.clone();
        if pin == self.open_menu_pin {
            return;
        }
        let text = pin_label(&pin);
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
        // An open popup does not repaint for ModifyMenuW on its own. Its
        // window is the shell's "#32768" class; ours is the one on this thread.
        unsafe {
            let mut popup = FindWindowExW(None, None, w!("#32768"), None).ok();
            while let Some(h) = popup {
                if GetWindowThreadProcessId(h, None) == GetCurrentThreadId() {
                    let _ = InvalidateRect(h, None, true);
                }
                popup = FindWindowExW(None, h, w!("#32768"), None).ok();
            }
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

    unsafe fn build_menu(&mut self) -> Result<HMENU> {
        let status = self.status.lock().unwrap();
        let menu = CreatePopupMenu().context("CreatePopupMenu")?;
        append(
            menu,
            MF_STRING | MF_DISABLED | MF_GRAYED,
            CMD_STATUS,
            &status.summary(),
        )?;
        if status.session.is_some() {
            append(menu, MF_STRING, CMD_DISCONNECT, "Disconnect")?;
        }
        append(menu, MF_SEPARATOR, 0, "")?;
        append(menu, MF_STRING, CMD_COPY_PIN, &pin_label(&status.pin))?;
        if !status.pin_fixed {
            append(menu, MF_STRING, CMD_NEW_PIN, "Get new PIN")?;
        }
        append(menu, MF_SEPARATOR, 0, "")?;

        // Forget paired MacBook ▸ one entry per pairing; the snapshot behind
        // the command ids lives until the command has run.
        let forget = CreatePopupMenu().context("CreatePopupMenu")?;
        let active = status.session.as_ref().map(|s| s.client_key);
        self.open_menu_peers = {
            let list = self.paired.lock().unwrap();
            let mut entries: Vec<(Key32, String)> = list
                .iter()
                .map(|(key, name)| (*key, name.clone()))
                .collect();
            entries.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
            entries
        };
        if self.open_menu_peers.is_empty() {
            append(
                forget,
                MF_STRING | MF_DISABLED | MF_GRAYED,
                CMD_NO_PAIRED,
                "No paired MacBooks",
            )?;
        }
        for (n, (key, name)) in self.open_menu_peers.iter().enumerate() {
            let mut label = format!("{name}  ({})", fingerprint(key));
            if active == Some(*key) {
                label.push_str(" \u{2014} streaming");
            }
            append(forget, MF_STRING, CMD_FORGET_BASE + n as u32, &label)?;
        }
        AppendMenuW(
            menu,
            MF_POPUP,
            forget.0 as usize,
            w!("Forget paired MacBook"),
        )
        .context("AppendMenuW(popup)")?;
        append(menu, MF_SEPARATOR, 0, "")?;

        // The service's start type. A dev run shows the real state but
        // cannot change it: it is not the service.
        let mut boot_flags = MF_STRING;
        match crate::service::start_on_boot() {
            Some(true) => boot_flags |= MF_CHECKED,
            Some(false) => {}
            None => boot_flags |= MF_DISABLED | MF_GRAYED,
        }
        if !self.under_service {
            boot_flags |= MF_DISABLED | MF_GRAYED;
        }
        append(menu, boot_flags, CMD_START_ON_BOOT, "Start on system boot")?;
        append(menu, MF_STRING, CMD_EXIT, "Exit")?;
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
            // Get new PIN is handled by `filter_menu_message` while the menu
            // is open; it only lands here if the hook could not be installed.
            CMD_NEW_PIN => match self.status.lock().unwrap().rotate_pin() {
                Ok(true) => log::info!("pairing PIN rotated from the tray"),
                Ok(false) => {}
                Err(e) => log::warn!("could not rotate the pairing PIN: {e:#}"),
            },
            CMD_DISCONNECT => {
                if !self
                    .status
                    .lock()
                    .unwrap()
                    .request_end(stop_reason::HOST_SHUTDOWN)
                {
                    log::debug!("Disconnect chosen but the session had already ended");
                }
            }
            CMD_START_ON_BOOT => {
                let on = !crate::service::start_on_boot().unwrap_or(true);
                match crate::service::set_start_on_boot(on) {
                    Ok(()) => log::info!(
                        "Start on system boot turned {} from the tray",
                        if on { "on" } else { "off" }
                    ),
                    Err(e) => log::warn!("could not change the service start type: {e:#}"),
                }
            }
            CMD_EXIT => self.exit(),
            n if n >= CMD_FORGET_BASE => {
                if let Some((key, name)) = self.open_menu_peers.get((n - CMD_FORGET_BASE) as usize)
                {
                    self.forget(*key, name.clone());
                }
            }
            _ => {}
        }
    }

    /// Close Relay completely. Under the service that means stopping the
    /// service: it answers by setting our quit event, which the message loop
    /// turns into the usual `on_quit`; so nothing respawns at the next sign-in.
    fn exit(&mut self) {
        if self.under_service {
            match crate::service::stop_service() {
                Ok(()) => {
                    log::info!("Exit: stopping the Relay service");
                    return;
                }
                Err(e) => {
                    log::warn!("could not stop the Relay service ({e:#}); quitting the worker only")
                }
            }
        }
        (self.on_quit)();
    }

    /// Confirm, then drop the pairing; a MacBook that is streaming right now
    /// is sent away as not paired.
    fn forget(&mut self, key: Key32, name: String) {
        let fp = fingerprint(&key);
        let text = format!("Forget {name} ({fp})?\n\nIt will need the PIN to connect again.");
        let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
        let answer = unsafe {
            let _ = SetForegroundWindow(self.hwnd);
            MessageBoxW(
                self.hwnd,
                PCWSTR(wide.as_ptr()),
                w!("Relay"),
                MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_SETFOREGROUND,
            )
        };
        if answer != IDYES {
            return;
        }
        match self.paired.lock().unwrap().remove(&key) {
            Ok(true) => log::info!("forgot {name} ({fp}) from the tray"),
            Ok(false) => log::info!("{name} ({fp}) was already forgotten"),
            Err(e) => log::warn!("could not forget {name} ({fp}): {e:#}"),
        }
        let status = self.status.lock().unwrap();
        if status.session.as_ref().is_some_and(|s| s.client_key == key) {
            status.request_end(stop_reason::NOT_PAIRED);
        }
    }
}

/// The menu's PIN line: "PIN: 123 456".
fn pin_label(pin: &str) -> String {
    format!("PIN: {}", spaced_pin(pin))
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
        WM_MENUSELECT => {
            // LOWORD(wParam) is the item id, or its index for a submenu
            // (MF_POPUP in HIWORD), which is never a command of ours.
            let flags = (wparam.0 >> 16) as u32;
            tray.highlighted = if flags & MF_POPUP.0 == 0 && flags != 0xffff {
                (wparam.0 & 0xffff) as u32
            } else {
                0
            };
            LRESULT(0)
        }
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
                    menu_theme::apply();
                    tray.reload_icon();
                }
            }
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == STATUS_TIMER_ID => {
            tray.refresh_tip();
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
            let _ = KillTimer(hwnd, STATUS_TIMER_ID);
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

// --- menu theme ------------------------------------------------------------

/// Win32 popup menus are drawn light unless the process opts into the
/// immersive dark menus through two **undocumented** uxtheme exports — the
/// same ones Explorer's own tray menus (and Notepad++, Windows Terminal's
/// context menus, …) rely on. They are exported by ordinal only:
/// 135 `SetPreferredAppMode(PreferredAppMode) -> PreferredAppMode` and
/// 136 `FlushMenuThemes()`. Before 1903 (build 18362) ordinal 135 was
/// `AllowDarkModeForApp(bool)` with another signature, so older builds keep
/// the light menu. Nothing here can fail loudly: no export, no dark menu.
mod menu_theme {
    use windows::core::PCSTR;
    use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;

    const FIRST_BUILD_WITH_APP_MODE: u32 = 18362;
    const ORDINAL_SET_PREFERRED_APP_MODE: usize = 135;
    const ORDINAL_FLUSH_MENU_THEMES: usize = 136;
    const FORCE_DARK: i32 = 2;
    const FORCE_LIGHT: i32 = 3;

    type SetPreferredAppMode = unsafe extern "system" fn(i32) -> i32;
    type FlushMenuThemes = unsafe extern "system" fn();

    /// Match the menu to the taskbar (which the icon already follows).
    pub fn apply() {
        let dark = !super::taskbar_is_light();
        if !supported() {
            log::debug!("dark menus need Windows 10 1903 or later; keeping the light menu");
            return;
        }
        unsafe {
            let Ok(uxtheme) = LoadLibraryW(windows::core::w!("uxtheme.dll")) else {
                return;
            };
            // MAKEINTRESOURCEA: the ordinal in the low word of the pointer.
            let by_ordinal = |n: usize| GetProcAddress(uxtheme, PCSTR(n as *const u8));
            let (Some(set_mode), Some(flush)) = (
                by_ordinal(ORDINAL_SET_PREFERRED_APP_MODE),
                by_ordinal(ORDINAL_FLUSH_MENU_THEMES),
            ) else {
                log::debug!("uxtheme has no app-mode exports; keeping the light menu");
                return;
            };
            let set_mode: SetPreferredAppMode = std::mem::transmute(set_mode);
            let flush: FlushMenuThemes = std::mem::transmute(flush);
            set_mode(if dark { FORCE_DARK } else { FORCE_LIGHT });
            flush();
        }
        log::debug!("tray menu set to {}", if dark { "dark" } else { "light" });
    }

    fn supported() -> bool {
        RegKey::predef(HKEY_LOCAL_MACHINE)
            .open_subkey(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion")
            .and_then(|k| k.get_value::<String, _>("CurrentBuildNumber"))
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
            .is_some_and(|build| build >= FIRST_BUILD_WITH_APP_MODE)
    }
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
