//! High-precision SDR source, including Windows' cursor composition. DXGI's
//! SDR desktop is BGRA8 even on MTT's 10-bit display on this machine.
//! WGC FP16 retains native sub-8-bit content. Convert linear scRGB to the same
//! full-range SDR RGB codes used by the 8-bit path, on the encoding GPU.
use super::*;
use windows::core::PCSTR;
use windows::Graphics::Capture::{
    Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession,
};
use windows::Graphics::DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat};
use windows::Win32::Graphics::Direct3D::Fxc::{
    D3DCompile, D3DCOMPILE_ENABLE_STRICTNESS, D3DCOMPILE_OPTIMIZATION_LEVEL3,
};
use windows::Win32::Graphics::Direct3D::{ID3DBlob, ID3DInclude};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_R16G16B16A16_FLOAT;
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::System::WinRT::Direct3D11::{
    CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess,
};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
use windows::Win32::System::WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED};

pub(crate) fn is_system() -> Result<bool> {
    use windows::Win32::Security::{
        GetTokenInformation, IsWellKnownSid, TokenUser, WinLocalSystemSid, TOKEN_QUERY, TOKEN_USER,
    };
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    unsafe {
        let mut token = windows::Win32::Foundation::HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token)?;
        let mut size = 0;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut size);
        let mut bytes = vec![0u8; size as usize];
        let info = GetTokenInformation(
            token,
            TokenUser,
            Some(bytes.as_mut_ptr().cast()),
            size,
            &mut size,
        );
        let _ = CloseHandle(token);
        info?;
        anyhow::ensure!(
            bytes.len() >= size_of::<TOKEN_USER>(),
            "truncated process token user"
        );
        let user = std::ptr::read_unaligned(bytes.as_ptr().cast::<TOKEN_USER>());
        Ok(IsWellKnownSid(user.User.Sid, WinLocalSystemSid).as_bool())
    }
}

pub(super) struct Apartment;
impl Apartment {
    pub(super) fn new() -> Result<Self> {
        // windows-rs caches agile WinRT activation factories process-wide.
        // The last MTA must not disappear between capability queries, encoder
        // trials and capture threads: reusing those factories after teardown
        // causes an access violation on this Windows/NVIDIA stack. Pin one MTA
        // for the process lifetime (one cookie, not one per session), while
        // still balancing every thread's own RoInitialize/RoUninitialize.
        static PROCESS_MTA: std::sync::OnceLock<std::result::Result<usize, String>> =
            std::sync::OnceLock::new();
        let pin = PROCESS_MTA.get_or_init(|| unsafe {
            windows::Win32::System::Com::CoIncrementMTAUsage()
                .map(|cookie| cookie.0 as usize)
                .map_err(|e| e.to_string())
        });
        if let Err(e) = pin {
            bail!("could not keep Windows capture runtime alive: {e}");
        }
        unsafe {
            RoInitialize(RO_INIT_MULTITHREADED)?;
        }
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}

pub(super) fn supported(device: &ID3D11Device) -> Result<bool> {
    // The capability query owns the apartment outside its NVENC session.
    if is_system()? {
        // Activation is per-user. The SYSTEM process uses a user capture
        // source; API metadata and GPU formats describe hardware capability,
        // while source startup checks current user/desktop availability.
        if !windows::Foundation::Metadata::ApiInformation::IsMethodPresent(
            &windows::core::HSTRING::from("Windows.Graphics.Capture.Direct3D11CaptureFramePool"),
            &windows::core::HSTRING::from("CreateFreeThreaded"),
        )? {
            return Ok(false);
        }
    } else if !GraphicsCaptureSession::IsSupported()? {
        return Ok(false);
    }
    let fp16 = unsafe { device.CheckFormatSupport(DXGI_FORMAT_R16G16B16A16_FLOAT) }?;
    let rgb10 = unsafe { device.CheckFormatSupport(DXGI_FORMAT_R10G10B10A2_UNORM) }?;
    Ok(fp16 & D3D11_FORMAT_SUPPORT_SHADER_LOAD.0 as u32 != 0
        && rgb10 & D3D11_FORMAT_SUPPORT_RENDER_TARGET.0 as u32 != 0
        && rgb10 & D3D11_FORMAT_SUPPORT_BLENDABLE.0 as u32 != 0)
}

pub(super) struct SdrCapture {
    session: GraphicsCaptureSession,
    pool: Direct3D11CaptureFramePool,
    _item: GraphicsCaptureItem,
    _device: IDirect3DDevice,
    width: u32,
    height: u32,
    closed: Arc<AtomicBool>,
    closed_token: windows::Foundation::EventRegistrationToken,
}

pub(super) struct Frame(pub Direct3D11CaptureFrame);
impl Drop for Frame {
    fn drop(&mut self) {
        let _ = self.0.Close();
    }
}

impl SdrCapture {
    /// Must be created, polled and dropped inside a live WinRT apartment.
    pub(super) fn new(
        device: &ID3D11Device,
        monitor: HMONITOR,
        width: u32,
        height: u32,
    ) -> Result<Self> {
        let interop: IGraphicsCaptureItemInterop =
            windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
        let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(monitor) }?;
        let rtdevice: IDirect3DDevice = unsafe {
            CreateDirect3D11DeviceFromDXGIDevice(
                &device.cast::<windows::Win32::Graphics::Dxgi::IDXGIDevice>()?,
            )
        }?
        .cast()?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            &rtdevice,
            DirectXPixelFormat::R16G16B16A16Float,
            2,
            item.Size()?,
        )?;
        let session = pool.CreateCaptureSession(&item)?;
        let closed = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&closed);
        let closed_token =
            item.Closed(&windows::Foundation::TypedEventHandler::new(move |_, _| {
                flag.store(true, Ordering::Relaxed);
                Ok(())
            }))?;
        let capture = Self {
            session,
            pool,
            _item: item,
            _device: rtdevice,
            width,
            height,
            closed,
            closed_token,
        };
        // A pointer can already be baked into DDA's BGRA8 desktop rather
        // than supplied as separate shape metadata (notably on an IDD).
        // That desktop is deliberately discarded here. Let WGC compose the
        // cursor into its FP16 frame instead, and never draw a DDA cursor on
        // top: one cursor owner, including in the SYSTEM user's helper.
        capture
            .session
            .SetIsCursorCaptureEnabled(!crate::test_fault("omit-wgc-cursor"))?;
        // Unpackaged desktop apps can request border suppression directly.
        // Never invoke a consent picker or change any global privacy setting.
        if let Err(e) = capture.session.SetIsBorderRequired(false) {
            log::warn!("Windows capture border could not be suppressed: {e}");
        }
        capture.session.StartCapture()?;
        log::info!("SDR desktop + cursor source: Windows Graphics Capture FP16 linear scRGB -> GPU sRGB OETF -> RGB10; no DXGI cursor overlay; source QPC timing through the existing frame timing contract");
        Ok(capture)
    }

    pub(super) fn latest(&self) -> Result<Option<Frame>> {
        anyhow::ensure!(
            !self.closed.load(Ordering::Relaxed),
            "WGC monitor capture closed; recreating capture"
        );
        let mut latest = None;
        for _ in 0..2 {
            match self.pool.TryGetNextFrame() {
                Ok(frame) => {
                    let frame = Frame(frame);
                    let size = frame.0.ContentSize()?;
                    anyhow::ensure!(
                        size.Width == self.width as i32 && size.Height == self.height as i32,
                        "WGC desktop size changed to {}x{}; recreating capture",
                        size.Width,
                        size.Height
                    );
                    latest = Some(frame);
                }
                // windows 0.58 represents S_OK + null frame as Error(S_OK).
                Err(e) if e.code().is_ok() => break,
                Err(e) => return Err(e).context("WGC TryGetNextFrame"),
            }
        }
        Ok(latest)
    }
}
impl Drop for SdrCapture {
    fn drop(&mut self) {
        let _ = self._item.RemoveClosed(self.closed_token);
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

impl Frame {
    pub(super) fn texture(&self) -> Result<ID3D11Texture2D> {
        let access: IDirect3DDxgiInterfaceAccess = self.0.Surface()?.cast()?;
        unsafe { access.GetInterface() }.context("WGC D3D11 surface")
    }
    pub(super) fn present_qpc(&self, frequency: i64) -> Result<i64> {
        system_relative_to_qpc(self.0.SystemRelativeTime()?.Duration, frequency)
    }
}

/// WGC returns the compositor's QPC time in 100 ns TimeSpan units, rather
/// than raw counter ticks. Its epoch is shared by the helper and SYSTEM.
fn system_relative_to_qpc(time: i64, frequency: i64) -> Result<i64> {
    anyhow::ensure!(
        time > 0 && frequency > 0,
        "invalid WGC SystemRelativeTime/frequency"
    );
    i64::try_from(time as u128 * frequency as u128 / 10_000_000)
        .context("WGC SystemRelativeTime exceeds QPC range")
}

const SHADER: &[u8] = br#"
struct V { float4 position : SV_Position; };
V vs_main(uint id : SV_VertexID) {
    V v; float2 p = float2((id << 1) & 2, id & 2);
    v.position = float4(p * float2(2,-2) + float2(-1,1), 0, 1); return v;
}
Texture2D<float4> source : register(t0);
float4 ps_main(V v) : SV_Target {
    float3 x = saturate(source.Load(int3(int2(v.position.xy),0)).rgb);
    float3 low = x * 12.92;
    float3 high = 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    return float4(lerp(high, low, x <= 0.0031308),1);
}
"#;

fn compile(entry: &'static [u8], target: &'static [u8]) -> Result<ID3DBlob> {
    let mut code = None;
    let mut errors = None;
    unsafe {
        D3DCompile(
            SHADER.as_ptr().cast(),
            SHADER.len(),
            PCSTR::null(),
            None,
            None::<&ID3DInclude>,
            PCSTR(entry.as_ptr()),
            PCSTR(target.as_ptr()),
            D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &mut code,
            Some(&mut errors),
        )?;
    }
    code.context("SDR conversion shader bytecode missing")
}

pub(super) struct SdrConverter {
    source: ID3D11Texture2D,
    view: ID3D11ShaderResourceView,
    target: ID3D11RenderTargetView,
    vs: ID3D11VertexShader,
    ps: ID3D11PixelShader,
    width: u32,
    height: u32,
}

impl SdrConverter {
    pub(super) fn new(
        device: &ID3D11Device,
        target: &ID3D11Texture2D,
        width: u32,
        height: u32,
    ) -> Result<Self> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R16G16B16A16_FLOAT,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
            ..Default::default()
        };
        let (mut source, mut view, mut rtv, mut vs, mut ps) = (None, None, None, None, None);
        unsafe {
            device.CreateTexture2D(&desc, None, Some(&mut source))?;
            device.CreateShaderResourceView(
                source.as_ref().context("FP16 texture")?,
                None,
                Some(&mut view),
            )?;
            device.CreateRenderTargetView(target, None, Some(&mut rtv))?;
            let vs_code = compile(b"vs_main\0", b"vs_5_0\0")?;
            let ps_code = compile(b"ps_main\0", b"ps_5_0\0")?;
            device.CreateVertexShader(
                std::slice::from_raw_parts(
                    vs_code.GetBufferPointer().cast(),
                    vs_code.GetBufferSize(),
                ),
                None::<&ID3D11ClassLinkage>,
                Some(&mut vs),
            )?;
            device.CreatePixelShader(
                std::slice::from_raw_parts(
                    ps_code.GetBufferPointer().cast(),
                    ps_code.GetBufferSize(),
                ),
                None::<&ID3D11ClassLinkage>,
                Some(&mut ps),
            )?;
        }
        Ok(Self {
            source: source.context("FP16 source")?,
            view: view.context("FP16 SRV")?,
            target: rtv.context("RGB10 RTV")?,
            vs: vs.context("SDR VS")?,
            ps: ps.context("SDR PS")?,
            width,
            height,
        })
    }

    pub(super) fn convert(
        &self,
        context: &ID3D11DeviceContext,
        source: &ID3D11Texture2D,
    ) -> Result<()> {
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe {
            source.GetDesc(&mut desc);
        }
        if desc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT
            || desc.Width != self.width
            || desc.Height != self.height
        {
            return Err(anyhow::Error::new(UnsupportedCaptureFormat)
                .context("WGC source no longer FP16 at the session size"));
        }
        unsafe {
            context.CopyResource(&self.source, source);
            context.RSSetViewports(Some(&[D3D11_VIEWPORT {
                Width: self.width as f32,
                Height: self.height as f32,
                MaxDepth: 1.0,
                ..Default::default()
            }]));
            context.IASetPrimitiveTopology(
                windows::Win32::Graphics::Direct3D::D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
            );
            context.VSSetShader(&self.vs, None);
            context.PSSetShader(&self.ps, None);
            context.PSSetShaderResources(0, Some(&[Some(self.view.clone())]));
            context.OMSetBlendState(None, None, u32::MAX);
            context.OMSetRenderTargets(
                Some(&[Some(self.target.clone())]),
                None::<&ID3D11DepthStencilView>,
            );
            context.Draw(3, 0);
            context.PSSetShaderResources(0, Some(&[None]));
            context.OMSetRenderTargets(None, None::<&ID3D11DepthStencilView>);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wgc_time_uses_the_host_qpc_epoch_without_a_process_offset() {
        let year = 365 * 24 * 3600 * 10_000_000i64;
        for time in [123_456_789, year, year + 765_432] {
            for frequency in [10_000_000, 3_579_545, 24_000_000] {
                let ticks = system_relative_to_qpc(time, frequency).unwrap();
                assert!(
                    crate::clock::ticks_to_us(ticks, frequency).abs_diff(time as u64 / 10) <= 1
                );
            }
        }
        assert!(system_relative_to_qpc(-1, 10_000_000).is_err());
        assert!(system_relative_to_qpc(1, 0).is_err());
        assert!(system_relative_to_qpc(i64::MAX, 24_000_000).is_err());
    }

    #[test]
    fn sdr_conversion_shaders_compile() {
        compile(b"vs_main\0", b"vs_5_0\0").unwrap();
        compile(b"ps_main\0", b"ps_5_0\0").unwrap();
    }
}
