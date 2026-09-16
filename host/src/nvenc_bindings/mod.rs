//! Minimal runtime loader around NVIDIA's generated Video Codec SDK bindings.
//!
//! Loading `nvEncodeAPI64.dll` at runtime keeps the host installer independent
//! of the developer-only Video Codec SDK import libraries.
//! Raw definitions are derived from `nvidia-video-codec-sdk` 0.4.0; its MIT
//! notice is kept beside this module.

use std::mem::{transmute, zeroed};

use anyhow::{anyhow, bail, Context, Result};
use windows::core::{s, w};
use windows::Win32::Foundation::{FreeLibrary, HMODULE};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};

mod guid;
pub mod nv_encode_api;
mod version;

use nv_encode_api::{NVENCSTATUS, NV_ENCODE_API_FUNCTION_LIST, NV_ENCODE_API_FUNCTION_LIST_VER};

pub struct NvApi {
    module: HMODULE,
    pub functions: NV_ENCODE_API_FUNCTION_LIST,
}

impl NvApi {
    pub fn load() -> Result<Self> {
        unsafe {
            let module = LoadLibraryW(w!("nvEncodeAPI64.dll"))
                .context("loading NVIDIA driver encoder nvEncodeAPI64.dll")?;
            let proc = GetProcAddress(module, s!("NvEncodeAPICreateInstance"));
            let Some(proc) = proc else {
                let _ = FreeLibrary(module);
                bail!("NVIDIA driver does not export NvEncodeAPICreateInstance");
            };
            type CreateInstance =
                unsafe extern "C" fn(*mut NV_ENCODE_API_FUNCTION_LIST) -> NVENCSTATUS;
            let create: CreateInstance = transmute(proc);
            let mut functions: NV_ENCODE_API_FUNCTION_LIST = zeroed();
            functions.version = NV_ENCODE_API_FUNCTION_LIST_VER;
            let status = create(&mut functions);
            if status != NVENCSTATUS::NV_ENC_SUCCESS {
                let _ = FreeLibrary(module);
                bail!("NvEncodeAPICreateInstance failed with {status:?}");
            }
            Ok(Self { module, functions })
        }
    }

    pub fn required<T: Copy>(&self, function: Option<T>, name: &str) -> Result<T> {
        function.ok_or_else(|| anyhow!("NVIDIA driver does not provide {name}"))
    }
}

impl Drop for NvApi {
    fn drop(&mut self) {
        unsafe {
            let _ = FreeLibrary(self.module);
        }
    }
}
