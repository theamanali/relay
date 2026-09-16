//! Sends the current Windows cursor shape to the client. Pointer motion stays
//! local on the Mac; this channel changes only when Windows changes or hides
//! the cursor.

use std::mem::size_of;

use anyhow::{bail, Context, Result};
use windows::Win32::Foundation::{HANDLE, HINSTANCE};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetObjectW, SelectObject, BITMAP,
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HBRUSH, HDC, HGDIOBJ,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DrawIconEx, GetCursorInfo, GetIconInfo, LoadCursorW, CURSORINFO, CURSOR_SHOWING, DI_NORMAL,
    HCURSOR, HICON, ICONINFO, IDC_ARROW,
};

const FORMAT_BGRA_PREMULTIPLIED: u8 = 1;
const MAX_CURSOR_DIMENSION: i32 = 256;

#[derive(Debug, Clone)]
pub struct CursorUpdate {
    visible: bool,
    width: u16,
    height: u16,
    hotspot_x: u16,
    hotspot_y: u16,
    bgra: Vec<u8>,
}

impl CursorUpdate {
    fn hidden() -> Self {
        Self {
            visible: false,
            width: 0,
            height: 0,
            hotspot_x: 0,
            hotspot_y: 0,
            bgra: Vec::new(),
        }
    }

    fn visible_default() -> Self {
        Self {
            visible: true,
            ..Self::hidden()
        }
    }

    /// `visible`, pixel format, dimensions, hotspot, then tightly packed BGRA.
    pub fn payload(&self) -> Vec<u8> {
        if !self.visible {
            return vec![0];
        }
        if self.bgra.is_empty() {
            return vec![1, 0];
        }
        let mut payload = Vec::with_capacity(10 + self.bgra.len());
        payload.extend_from_slice(&[1, FORMAT_BGRA_PREMULTIPLIED]);
        payload.extend_from_slice(&self.width.to_be_bytes());
        payload.extend_from_slice(&self.height.to_be_bytes());
        payload.extend_from_slice(&self.hotspot_x.to_be_bytes());
        payload.extend_from_slice(&self.hotspot_y.to_be_bytes());
        payload.extend_from_slice(&self.bgra);
        payload
    }
}

pub struct CursorTracker {
    last: Option<(bool, usize)>,
    query_error_logged: bool,
}

impl Default for CursorTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl CursorTracker {
    pub fn new() -> Self {
        Self {
            last: None,
            query_error_logged: false,
        }
    }

    /// Returns an update only when visibility or the cursor handle changes.
    pub fn poll(&mut self) -> Option<CursorUpdate> {
        let mut info = CURSORINFO {
            cbSize: size_of::<CURSORINFO>() as u32,
            ..Default::default()
        };
        if let Err(error) = unsafe { GetCursorInfo(&mut info) } {
            if !self.query_error_logged {
                log::debug!("GetCursorInfo failed: {error}");
                self.query_error_logged = true;
            }
            // A service or restricted desktop can deny cursor inspection. The
            // first update still uses Windows' own standard arrow rather than
            // asking the Mac to invent a visually different fallback.
            if self.last.is_none() {
                self.last = Some((true, 0));
                return Some(system_arrow().unwrap_or_else(|fallback_error| {
                    log::warn!("could not copy the Windows arrow cursor: {fallback_error:#}");
                    CursorUpdate::visible_default()
                }));
            }
            return None;
        }
        self.query_error_logged = false;
        let visible = info.flags.0 & CURSOR_SHOWING.0 != 0;
        let key = (visible, info.hCursor.0 as usize);
        if self.last == Some(key) {
            return None;
        }
        self.last = Some(key);
        if !visible {
            return Some(CursorUpdate::hidden());
        }
        match rasterize(info.hCursor) {
            Ok(update) => Some(update),
            Err(error) => {
                log::warn!("could not copy the Windows cursor shape: {error:#}");
                Some(CursorUpdate::visible_default())
            }
        }
    }
}

fn system_arrow() -> Result<CursorUpdate> {
    let cursor = unsafe { LoadCursorW(HINSTANCE::default(), IDC_ARROW) }
        .context("LoadCursorW(IDC_ARROW)")?;
    rasterize(cursor)
}

fn rasterize(cursor: HCURSOR) -> Result<CursorUpdate> {
    let mut icon = ICONINFO::default();
    unsafe { GetIconInfo(HICON(cursor.0), &mut icon) }.context("GetIconInfo")?;

    let result = (|| {
        let source = if icon.hbmColor.0.is_null() {
            icon.hbmMask
        } else {
            icon.hbmColor
        };
        let mut bitmap = BITMAP::default();
        let got = unsafe {
            GetObjectW(
                HGDIOBJ(source.0),
                size_of::<BITMAP>() as i32,
                Some(&mut bitmap as *mut BITMAP as *mut _),
            )
        };
        if got != size_of::<BITMAP>() as i32 {
            bail!("GetObjectW returned {got}");
        }
        let width = bitmap.bmWidth;
        let height = if icon.hbmColor.0.is_null() {
            bitmap.bmHeight / 2
        } else {
            bitmap.bmHeight
        };
        if !(1..=MAX_CURSOR_DIMENSION).contains(&width)
            || !(1..=MAX_CURSOR_DIMENSION).contains(&height)
        {
            bail!("invalid cursor dimensions {width}x{height}");
        }

        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height, // top-down, matching Mac image coordinates
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                biSizeImage: (width * height * 4) as u32,
                ..Default::default()
            },
            ..Default::default()
        };

        let dc = unsafe { CreateCompatibleDC(HDC::default()) };
        if dc.0.is_null() {
            bail!("CreateCompatibleDC failed");
        }
        let mut bits = std::ptr::null_mut();
        let dib =
            unsafe { CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &mut bits, HANDLE::default(), 0) };
        let dib = match dib {
            Ok(dib) => dib,
            Err(error) => {
                unsafe {
                    let _ = DeleteDC(dc);
                }
                return Err(error).context("CreateDIBSection");
            }
        };
        let old = unsafe { SelectObject(dc, HGDIOBJ(dib.0)) };
        let bytes = (width * height * 4) as usize;
        unsafe { std::ptr::write_bytes(bits, 0, bytes) };
        let drawn = unsafe {
            DrawIconEx(
                dc,
                0,
                0,
                HICON(cursor.0),
                width,
                height,
                0,
                HBRUSH::default(),
                DI_NORMAL,
            )
        };
        let pixels = if drawn.is_ok() {
            unsafe { std::slice::from_raw_parts(bits as *const u8, bytes) }.to_vec()
        } else {
            Vec::new()
        };
        unsafe {
            SelectObject(dc, old);
            let _ = DeleteObject(HGDIOBJ(dib.0));
            let _ = DeleteDC(dc);
        }
        drawn.context("DrawIconEx")?;
        Ok(CursorUpdate {
            visible: true,
            width: width as u16,
            height: height as u16,
            hotspot_x: icon.xHotspot.min(width as u32 - 1) as u16,
            hotspot_y: icon.yHotspot.min(height as u32 - 1) as u16,
            bgra: pixels,
        })
    })();

    unsafe {
        delete_bitmap(icon.hbmColor);
        delete_bitmap(icon.hbmMask);
    }
    result
}

unsafe fn delete_bitmap(bitmap: HBITMAP) {
    if !bitmap.0.is_null() {
        let _ = DeleteObject(HGDIOBJ(bitmap.0));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_payload_is_compact() {
        assert_eq!(CursorUpdate::hidden().payload(), vec![0]);
    }

    #[test]
    fn shape_payload_has_metadata_and_pixels() {
        let update = CursorUpdate {
            visible: true,
            width: 2,
            height: 1,
            hotspot_x: 1,
            hotspot_y: 0,
            bgra: vec![1, 2, 3, 4, 5, 6, 7, 8],
        };
        assert_eq!(
            update.payload(),
            vec![1, 1, 0, 2, 0, 1, 0, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]
        );
    }
}
