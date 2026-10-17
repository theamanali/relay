//! Minimal runtime loader around NVIDIA's generated Video Codec SDK bindings.
//!
//! Loading `nvEncodeAPI64.dll` at runtime keeps the host installer independent
//! of the developer-only Video Codec SDK import libraries.
//! Raw definitions are derived from `nvidia-video-codec-sdk` 0.4.0; its MIT
//! notice is kept beside this module.

use std::fmt;
use std::mem::{transmute, zeroed};

use anyhow::{anyhow, bail, Context, Result};
use windows::core::{s, w};
use windows::Win32::Foundation::{FreeLibrary, HMODULE};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};

mod guid;
pub mod nv_encode_api;
mod version;

use nv_encode_api::{
    NVENCAPI_MAJOR_VERSION, NVENCAPI_MINOR_VERSION, NVENCSTATUS, NV_ENCODE_API_FUNCTION_LIST,
    NV_ENCODE_API_FUNCTION_LIST_VER,
};

/// The API these bindings were generated for, in the encoding
/// `NvEncodeAPIGetMaxSupportedVersion` reports: `(major << 4) | minor`.
/// `NVENCAPI_VERSION` (`major | minor << 24`) is the session-opening
/// encoding and must not be compared with the driver's answer.
pub const REQUIRED_DRIVER_API: u32 = (NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION;

/// Test hook: pretend the driver reports this API version (hex `0xb1` or
/// decimal), to exercise the driver-update error on a current driver.
const DRIVER_API_OVERRIDE_VAR: &str = "RELAY_TEST_NVENC_DRIVER_API";

/// An NVENC API version as the driver reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ApiVersion {
    pub major: u32,
    pub minor: u32,
}

impl ApiVersion {
    fn from_driver(raw: u32) -> Self {
        Self {
            major: raw >> 4,
            minor: raw & 0xf,
        }
    }
}

impl fmt::Display for ApiVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

/// NVIDIA keeps older API versions working on newer drivers, so anything at
/// or above the bindings' version is fine; a lower one needs a driver update.
pub fn check_driver_api(raw: u32) -> Result<ApiVersion> {
    let found = ApiVersion::from_driver(raw);
    if raw < REQUIRED_DRIVER_API {
        bail!(
            "the NVIDIA driver supports NVENC API {found}, Relay needs {}: update the NVIDIA driver",
            ApiVersion::from_driver(REQUIRED_DRIVER_API)
        );
    }
    Ok(found)
}

fn parse_test_override(value: &str) -> Option<u32> {
    let value = value.trim();
    match value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        Some(hex) => u32::from_str_radix(hex, 16).ok(),
        None => value.parse().ok(),
    }
}

/// `nvEncodeAPI64.dll`, freed on drop, so every early return unloads it.
struct Library(HMODULE);

impl Drop for Library {
    fn drop(&mut self) {
        unsafe {
            let _ = FreeLibrary(self.0);
        }
    }
}

pub struct NvApi {
    _library: Library,
    pub functions: NV_ENCODE_API_FUNCTION_LIST,
    /// The newest API the installed driver supports.
    pub driver_api: ApiVersion,
}

impl NvApi {
    pub fn load() -> Result<Self> {
        let driver_api_override = std::env::var(DRIVER_API_OVERRIDE_VAR)
            .ok()
            .and_then(|value| parse_test_override(&value));
        if let Some(raw) = driver_api_override {
            log::warn!("{DRIVER_API_OVERRIDE_VAR}: treating the driver's NVENC API as {raw:#x}");
        }
        Self::load_with(driver_api_override)
    }

    fn load_with(driver_api_override: Option<u32>) -> Result<Self> {
        unsafe {
            let library = Library(
                LoadLibraryW(w!("nvEncodeAPI64.dll"))
                    .context("loading NVIDIA driver encoder nvEncodeAPI64.dll")?,
            );
            let Some(max_version) =
                GetProcAddress(library.0, s!("NvEncodeAPIGetMaxSupportedVersion"))
            else {
                bail!("the NVIDIA driver does not export NvEncodeAPIGetMaxSupportedVersion: update the NVIDIA driver");
            };
            type MaxSupportedVersion = unsafe extern "C" fn(*mut u32) -> NVENCSTATUS;
            let max_version: MaxSupportedVersion = transmute(max_version);
            let mut raw = 0u32;
            let status = max_version(&mut raw);
            if status != NVENCSTATUS::NV_ENC_SUCCESS {
                bail!("NvEncodeAPIGetMaxSupportedVersion failed with {status:?}");
            }
            let driver_api = check_driver_api(driver_api_override.unwrap_or(raw))?;

            let Some(proc) = GetProcAddress(library.0, s!("NvEncodeAPICreateInstance")) else {
                bail!("NVIDIA driver does not export NvEncodeAPICreateInstance");
            };
            type CreateInstance =
                unsafe extern "C" fn(*mut NV_ENCODE_API_FUNCTION_LIST) -> NVENCSTATUS;
            let create: CreateInstance = transmute(proc);
            let mut functions: NV_ENCODE_API_FUNCTION_LIST = zeroed();
            functions.version = NV_ENCODE_API_FUNCTION_LIST_VER;
            let status = create(&mut functions);
            if status != NVENCSTATUS::NV_ENC_SUCCESS {
                bail!("NvEncodeAPICreateInstance failed with {status:?}");
            }
            Ok(Self {
                _library: library,
                functions,
                driver_api,
            })
        }
    }

    pub fn required<T: Copy>(&self, function: Option<T>, name: &str) -> Result<T> {
        function.ok_or_else(|| anyhow!("NVIDIA driver does not provide {name}"))
    }
}

/// Serializes tests that load nvEncodeAPI64.dll, so one can check that a
/// failed load leaves it unloaded.
#[cfg(test)]
pub(crate) static NVENC_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;

    #[test]
    fn required_version_uses_the_drivers_encoding_not_the_session_one() {
        assert_eq!(REQUIRED_DRIVER_API, 0xC1);
        assert_ne!(REQUIRED_DRIVER_API, nv_encode_api::NVENCAPI_VERSION);
    }

    #[test]
    fn the_same_or_a_newer_driver_api_passes() {
        for raw in [0xC1, 0xC2, 0xD0, 0xD1] {
            assert!(check_driver_api(raw).is_ok(), "{raw:#x}");
        }
        assert_eq!(
            check_driver_api(0xD0).unwrap(),
            ApiVersion {
                major: 13,
                minor: 0
            }
        );
    }

    #[test]
    fn an_older_driver_api_asks_for_a_driver_update() {
        for raw in [0xC0, 0xB1, 0x90] {
            let error = format!("{:#}", check_driver_api(raw).unwrap_err());
            assert!(error.contains("update the NVIDIA driver"), "{error}");
            assert!(error.contains("12.1"), "{error}");
        }
        let error = format!("{:#}", check_driver_api(0xB1).unwrap_err());
        assert!(error.contains("11.1"), "{error}");
    }

    #[test]
    fn the_test_override_reads_hex_or_decimal() {
        assert_eq!(parse_test_override("0xb1"), Some(0xB1));
        assert_eq!(parse_test_override("0XC1"), Some(0xC1));
        assert_eq!(parse_test_override("176"), Some(176));
        assert_eq!(parse_test_override(" 193 "), Some(193));
        assert_eq!(parse_test_override("old"), None);
    }

    #[test]
    fn a_driver_that_is_too_old_leaves_the_dll_unloaded() {
        let _nvenc = NVENC_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dll = w!("nvEncodeAPI64.dll");
        let loaded_before = unsafe { GetModuleHandleW(dll) }.is_ok();
        match NvApi::load_with(Some(0xB1)) {
            Ok(_) => panic!("an 11.1 driver must be refused"),
            // No NVIDIA driver on this machine (CI): nothing to check.
            Err(e) if format!("{e:#}").contains("loading NVIDIA driver encoder") => return,
            Err(e) => assert!(
                format!("{e:#}").contains("update the NVIDIA driver"),
                "{e:#}"
            ),
        }
        if !loaded_before {
            assert!(
                unsafe { GetModuleHandleW(dll) }.is_err(),
                "nvEncodeAPI64.dll still loaded after a failed version check"
            );
        }
    }
}
