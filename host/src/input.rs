//! Injects client input with `SendInput`. Mouse positions arrive normalised to
//! the streamed display; we map them into the Windows virtual-desktop coordinate
//! space so the pointer lands on the virtual monitor wherever it sits in the
//! arrangement. Keys arrive as USB HID usages and become PS/2 set-1 scan codes.

use std::mem::size_of;

use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
    MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT,
    MOUSE_EVENT_FLAGS, VIRTUAL_KEY,
};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN,
};

use crate::display::Placement;

const XBUTTON1: i32 = 0x0001;
const XBUTTON2: i32 = 0x0002;

#[derive(Debug, Clone, Copy)]
struct DesktopBounds {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

pub struct Injector {
    target: Placement,
    desktop: DesktopBounds,
    /// Keys currently held, so we can release them if the client vanishes.
    held: Vec<u16>,
}

/// Keep display placement, virtual-desktop metrics and SendInput in physical
/// pixels. Without this, Windows can DPI-virtualise GetSystemMetrics while GDI
/// still reports the virtual monitor's native pixel dimensions.
pub fn enable_physical_pixel_coordinates() -> windows::core::Result<()> {
    unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
}

impl Injector {
    pub fn new(target: Placement, exclusive: bool) -> Self {
        // A normal TravelDisplay session has already made the target the only
        // display at (0, 0), so its normalized input coordinates are also the
        // normalized virtual-desktop coordinates. This remains exact even if
        // a Windows API unexpectedly reports DPI-virtualised metrics.
        let desktop = if exclusive {
            DesktopBounds::from_target(target)
        } else {
            DesktopBounds::current()
        };
        log::info!(
            "input mapping: target {}x{} at ({}, {}), virtual desktop {}x{} at ({}, {})",
            target.width,
            target.height,
            target.x,
            target.y,
            desktop.width,
            desktop.height,
            desktop.x,
            desktop.y
        );
        Injector {
            target,
            desktop,
            held: Vec::new(),
        }
    }

    fn send(input: INPUT) {
        unsafe {
            SendInput(&[input], size_of::<INPUT>() as i32);
        }
    }

    fn mouse(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) {
        Self::send(INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx,
                    dy,
                    mouseData: data as u32, // DWORD carrying a signed wheel delta
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        });
    }

    /// `nx`/`ny` are 0..65535 across the streamed display.
    pub fn mouse_move(&self, nx: u16, ny: u16) {
        let Some((ax, ay)) = absolute_position(nx, ny, self.target, self.desktop) else {
            return;
        };
        Self::mouse(
            ax,
            ay,
            0,
            MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        );
    }

    pub fn mouse_button(&self, button: u8, down: bool) {
        let (flags, data) = match (button, down) {
            (0, true) => (MOUSEEVENTF_LEFTDOWN, 0),
            (0, false) => (MOUSEEVENTF_LEFTUP, 0),
            (1, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
            (1, false) => (MOUSEEVENTF_RIGHTUP, 0),
            (2, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
            (2, false) => (MOUSEEVENTF_MIDDLEUP, 0),
            (3, true) => (MOUSEEVENTF_XDOWN, XBUTTON1),
            (3, false) => (MOUSEEVENTF_XUP, XBUTTON1),
            (4, true) => (MOUSEEVENTF_XDOWN, XBUTTON2),
            (4, false) => (MOUSEEVENTF_XUP, XBUTTON2),
            _ => return,
        };
        Self::mouse(0, 0, data, flags);
    }

    /// Wheel deltas in Windows units (120 per notch).
    pub fn mouse_wheel(&self, dx: i16, dy: i16) {
        if dy != 0 {
            Self::mouse(0, 0, dy as i32, MOUSEEVENTF_WHEEL);
        }
        if dx != 0 {
            Self::mouse(0, 0, dx as i32, MOUSEEVENTF_HWHEEL);
        }
    }

    pub fn key(&mut self, hid_usage: u16, down: bool) {
        let Some(scan) = hid_to_scancode(hid_usage) else {
            log::debug!("no scan code for HID usage 0x{hid_usage:02x}");
            return;
        };
        let mut flags = KEYEVENTF_SCANCODE;
        if scan & 0xE000 == 0xE000 {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        if !down {
            flags |= KEYEVENTF_KEYUP;
        }
        Self::send(INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(0),
                    wScan: scan & 0xFF,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        });
        if down {
            if !self.held.contains(&hid_usage) {
                self.held.push(hid_usage);
            }
        } else {
            self.held.retain(|&k| k != hid_usage);
        }
    }

    /// Release everything still held (called when the session ends so a stuck
    /// modifier can't survive a dropped connection).
    pub fn release_all(&mut self) {
        let held = std::mem::take(&mut self.held);
        for k in held {
            self.key(k, false);
        }
    }
}

impl DesktopBounds {
    fn from_target(target: Placement) -> Self {
        Self {
            x: target.x,
            y: target.y,
            width: target.width as i32,
            height: target.height as i32,
        }
    }

    fn current() -> Self {
        unsafe {
            Self {
                x: GetSystemMetrics(SM_XVIRTUALSCREEN),
                y: GetSystemMetrics(SM_YVIRTUALSCREEN),
                width: GetSystemMetrics(SM_CXVIRTUALSCREEN),
                height: GetSystemMetrics(SM_CYVIRTUALSCREEN),
            }
        }
    }
}

fn absolute_position(
    nx: u16,
    ny: u16,
    target: Placement,
    desktop: DesktopBounds,
) -> Option<(i32, i32)> {
    if target.width <= 1 || target.height <= 1 || desktop.width <= 1 || desktop.height <= 1 {
        return None;
    }
    Some((
        absolute_axis(nx, target.x, target.width, desktop.x, desktop.width),
        absolute_axis(ny, target.y, target.height, desktop.y, desktop.height),
    ))
}

fn absolute_axis(
    normalized: u16,
    target_origin: i32,
    target_length: u32,
    desktop_origin: i32,
    desktop_length: i32,
) -> i32 {
    // Map the two inclusive endpoint ranges directly. Combining the ratios
    // avoids the rounding drift caused by first choosing a target pixel and
    // then normalising that pixel to the virtual desktop.
    let denominator = i64::from(desktop_length - 1);
    let numerator = i64::from(target_origin - desktop_origin) * 65535
        + i64::from(normalized) * i64::from(target_length - 1);
    ((numerator + denominator / 2) / denominator).clamp(0, 65535) as i32
}

impl Drop for Injector {
    fn drop(&mut self) {
        self.release_all();
    }
}

/// USB HID Keyboard/Keypad page (0x07) usage -> PS/2 scan code set 1.
/// Values >= 0xE000 carry the E0 prefix (extended key).
pub fn hid_to_scancode(usage: u16) -> Option<u16> {
    Some(match usage {
        0x04 => 0x1E, // A
        0x05 => 0x30, // B
        0x06 => 0x2E, // C
        0x07 => 0x20, // D
        0x08 => 0x12, // E
        0x09 => 0x21, // F
        0x0A => 0x22, // G
        0x0B => 0x23, // H
        0x0C => 0x17, // I
        0x0D => 0x24, // J
        0x0E => 0x25, // K
        0x0F => 0x26, // L
        0x10 => 0x32, // M
        0x11 => 0x31, // N
        0x12 => 0x18, // O
        0x13 => 0x19, // P
        0x14 => 0x10, // Q
        0x15 => 0x13, // R
        0x16 => 0x1F, // S
        0x17 => 0x14, // T
        0x18 => 0x16, // U
        0x19 => 0x2F, // V
        0x1A => 0x11, // W
        0x1B => 0x2D, // X
        0x1C => 0x15, // Y
        0x1D => 0x2C, // Z
        0x1E => 0x02, // 1
        0x1F => 0x03, // 2
        0x20 => 0x04, // 3
        0x21 => 0x05, // 4
        0x22 => 0x06, // 5
        0x23 => 0x07, // 6
        0x24 => 0x08, // 7
        0x25 => 0x09, // 8
        0x26 => 0x0A, // 9
        0x27 => 0x0B, // 0
        0x28 => 0x1C, // Enter
        0x29 => 0x01, // Escape
        0x2A => 0x0E, // Backspace
        0x2B => 0x0F, // Tab
        0x2C => 0x39, // Space
        0x2D => 0x0C, // -
        0x2E => 0x0D, // =
        0x2F => 0x1A, // [
        0x30 => 0x1B, // ]
        0x31 => 0x2B, // backslash
        0x32 => 0x2B, // non-US #
        0x33 => 0x27, // ;
        0x34 => 0x28, // '
        0x35 => 0x29, // `
        0x36 => 0x33, // ,
        0x37 => 0x34, // .
        0x38 => 0x35, // /
        0x39 => 0x3A, // Caps Lock
        0x3A => 0x3B, // F1
        0x3B => 0x3C,
        0x3C => 0x3D,
        0x3D => 0x3E,
        0x3E => 0x3F,
        0x3F => 0x40,
        0x40 => 0x41,
        0x41 => 0x42,
        0x42 => 0x43,
        0x43 => 0x44, // F10
        0x44 => 0x57, // F11
        0x45 => 0x58, // F12
        0x46 => 0xE037, // Print Screen
        0x47 => 0x46,   // Scroll Lock
        0x49 => 0xE052, // Insert
        0x4A => 0xE047, // Home
        0x4B => 0xE049, // Page Up
        0x4C => 0xE053, // Delete
        0x4D => 0xE04F, // End
        0x4E => 0xE051, // Page Down
        0x4F => 0xE04D, // Right
        0x50 => 0xE04B, // Left
        0x51 => 0xE050, // Down
        0x52 => 0xE048, // Up
        0x53 => 0x45,   // Num Lock
        0x54 => 0xE035, // KP /
        0x55 => 0x37,   // KP *
        0x56 => 0x4A,   // KP -
        0x57 => 0x4E,   // KP +
        0x58 => 0xE01C, // KP Enter
        0x59 => 0x4F,   // KP 1
        0x5A => 0x50,
        0x5B => 0x51,
        0x5C => 0x4B,
        0x5D => 0x4C,
        0x5E => 0x4D,
        0x5F => 0x47,
        0x60 => 0x48,
        0x61 => 0x49,   // KP 9
        0x62 => 0x52,   // KP 0
        0x63 => 0x53,   // KP .
        0x64 => 0x56,   // non-US backslash
        0x65 => 0xE05D, // Application (menu)
        0x67 => 0x59,   // KP =
        0x68 => 0x64,   // F13
        0x69 => 0x65,
        0x6A => 0x66,
        0x6B => 0x67,
        0x6C => 0x68,
        0x6D => 0x69,
        0x6E => 0x6A,
        0x6F => 0x6B,
        0x70 => 0x6C,
        0x71 => 0x6D,
        0x72 => 0x6E,
        0x73 => 0x76,   // F24
        0xE0 => 0x1D,   // Left Ctrl
        0xE1 => 0x2A,   // Left Shift
        0xE2 => 0x38,   // Left Alt
        0xE3 => 0xE05B, // Left GUI (Win)
        0xE4 => 0xE01D, // Right Ctrl
        0xE5 => 0x36,   // Right Shift
        0xE6 => 0xE038, // Right Alt
        0xE7 => 0xE05C, // Right GUI
        _ => return None,
    })
}

#[cfg(test)]
mod coordinate_tests {
    use super::*;

    fn placement(x: i32, y: i32, width: u32, height: u32) -> Placement {
        Placement {
            x,
            y,
            width,
            height,
            hz: 120,
        }
    }

    #[test]
    fn single_display_preserves_normalized_coordinates() {
        let target = placement(0, 0, 3024, 1964);
        let desktop = DesktopBounds {
            x: 0,
            y: 0,
            width: 3024,
            height: 1964,
        };
        for point in [(0, 0), (32768, 32768), (65535, 65535)] {
            assert_eq!(
                absolute_position(point.0, point.1, target, desktop),
                Some((i32::from(point.0), i32::from(point.1)))
            );
        }
    }

    #[test]
    fn offset_display_maps_into_the_full_desktop() {
        let target = placement(0, 0, 3024, 1964);
        let desktop = DesktopBounds {
            x: -1920,
            y: 0,
            width: 4944,
            height: 1964,
        };
        let left = absolute_position(0, 0, target, desktop).unwrap();
        let right = absolute_position(65535, 65535, target, desktop).unwrap();
        assert_eq!(left.0, 25456);
        assert_eq!(left.1, 0);
        assert_eq!(right, (65535, 65535));
    }
}
