//! GPU cursor composition for Desktop Duplication frames.
//!
//! Desktop Duplication supplies the pointer position and shape separately from
//! the desktop texture.  Uploading that small shape and blending a four-vertex
//! quad avoids `IDXGISurface1::GetDC`, which synchronizes an entire 6 MP frame
//! with GDI and substantially limits capture throughput.

use std::ffi::c_void;
use std::mem::size_of;

use anyhow::{anyhow, bail, Context, Result};
use windows::core::PCSTR;
use windows::Win32::Foundation::BOOL;
use windows::Win32::Graphics::Direct3D::Fxc::{
    D3DCompile, D3DCOMPILE_ENABLE_STRICTNESS, D3DCOMPILE_OPTIMIZATION_LEVEL3,
};
use windows::Win32::Graphics::Direct3D::{
    ID3DBlob, ID3DInclude, D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11BlendState, ID3D11Buffer, ID3D11ClassLinkage, ID3D11DepthStencilView, ID3D11Device,
    ID3D11DeviceContext, ID3D11PixelShader, ID3D11RenderTargetView, ID3D11SamplerState,
    ID3D11ShaderResourceView, ID3D11Texture2D, ID3D11VertexShader, D3D11_BIND_CONSTANT_BUFFER,
    D3D11_BIND_SHADER_RESOURCE, D3D11_BLEND_DESC, D3D11_BLEND_INV_DEST_COLOR,
    D3D11_BLEND_INV_SRC_ALPHA, D3D11_BLEND_INV_SRC_COLOR, D3D11_BLEND_ONE, D3D11_BLEND_OP_ADD,
    D3D11_BLEND_SRC_ALPHA, D3D11_BLEND_ZERO, D3D11_BUFFER_DESC, D3D11_COLOR_WRITE_ENABLE_ALL,
    D3D11_COMPARISON_NEVER, D3D11_FILTER_MIN_MAG_MIP_POINT, D3D11_SAMPLER_DESC,
    D3D11_SUBRESOURCE_DATA, D3D11_TEXTURE2D_DESC, D3D11_TEXTURE_ADDRESS_CLAMP, D3D11_USAGE_DEFAULT,
    D3D11_USAGE_IMMUTABLE, D3D11_VIEWPORT,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    IDXGIOutputDuplication, DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_POINTER_SHAPE_INFO,
    DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR,
    DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME,
};

const SHADER: &[u8] = br#"
cbuffer CursorRect : register(b0) {
    float4 rect;
};

struct VertexOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

VertexOut vs_main(uint id : SV_VertexID) {
    float2 uv = float2(id & 1, (id >> 1) & 1);
    VertexOut output;
    output.position = float4(lerp(rect.xy, rect.zw, uv), 0.0, 1.0);
    output.uv = uv;
    return output;
}

Texture2D cursor_texture : register(t0);
SamplerState cursor_sampler : register(s0);

float4 ps_main(VertexOut input) : SV_Target {
    return cursor_texture.Sample(cursor_sampler, input.uv);
}
"#;

#[repr(C)]
struct CursorConstants {
    rect: [f32; 4],
}

struct CursorShape {
    view: ID3D11ShaderResourceView,
    xor_view: Option<ID3D11ShaderResourceView>,
    width: u32,
    height: u32,
}

pub struct CursorOverlay {
    device: ID3D11Device,
    target: ID3D11RenderTargetView,
    vertex_shader: ID3D11VertexShader,
    pixel_shader: ID3D11PixelShader,
    constants: ID3D11Buffer,
    sampler: ID3D11SamplerState,
    blend: ID3D11BlendState,
    xor_blend: ID3D11BlendState,
    shape: Option<CursorShape>,
    x: i32,
    y: i32,
    visible: bool,
    frame_width: u32,
    frame_height: u32,
}

impl CursorOverlay {
    pub fn new(
        device: &ID3D11Device,
        target_texture: &ID3D11Texture2D,
        frame_width: u32,
        frame_height: u32,
    ) -> Result<Self> {
        let vs_blob = compile("vs_main", "vs_5_0")?;
        let ps_blob = compile("ps_main", "ps_5_0")?;
        let mut vertex_shader = None;
        let mut pixel_shader = None;
        unsafe {
            device.CreateVertexShader(
                blob_bytes(&vs_blob),
                None::<&ID3D11ClassLinkage>,
                Some(&mut vertex_shader),
            )?;
            device.CreatePixelShader(
                blob_bytes(&ps_blob),
                None::<&ID3D11ClassLinkage>,
                Some(&mut pixel_shader),
            )?;
        }

        let buffer_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of::<CursorConstants>() as u32,
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
            ..Default::default()
        };
        let mut constants = None;
        unsafe { device.CreateBuffer(&buffer_desc, None, Some(&mut constants)) }
            .context("CreateBuffer(cursor constants)")?;

        let sampler_desc = D3D11_SAMPLER_DESC {
            Filter: D3D11_FILTER_MIN_MAG_MIP_POINT,
            AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
            ComparisonFunc: D3D11_COMPARISON_NEVER,
            MaxLOD: f32::MAX,
            ..Default::default()
        };
        let mut sampler = None;
        unsafe { device.CreateSamplerState(&sampler_desc, Some(&mut sampler)) }
            .context("CreateSamplerState(cursor)")?;

        let blend = create_blend_state(device, false)?;
        let xor_blend = create_blend_state(device, true)?;
        let mut target = None;
        unsafe { device.CreateRenderTargetView(target_texture, None, Some(&mut target)) }
            .context("CreateRenderTargetView(encoder input)")?;

        Ok(Self {
            device: device.clone(),
            target: target.ok_or_else(|| anyhow!("cursor render target was not created"))?,
            vertex_shader: vertex_shader
                .ok_or_else(|| anyhow!("cursor vertex shader was not created"))?,
            pixel_shader: pixel_shader
                .ok_or_else(|| anyhow!("cursor pixel shader was not created"))?,
            constants: constants.ok_or_else(|| anyhow!("cursor constants were not created"))?,
            sampler: sampler.ok_or_else(|| anyhow!("cursor sampler was not created"))?,
            blend,
            xor_blend,
            shape: None,
            x: 0,
            y: 0,
            visible: false,
            frame_width,
            frame_height,
        })
    }

    pub fn update(
        &mut self,
        duplication: &IDXGIOutputDuplication,
        info: &DXGI_OUTDUPL_FRAME_INFO,
    ) -> Result<()> {
        if info.LastMouseUpdateTime != 0 {
            self.visible = info.PointerPosition.Visible.as_bool();
            self.x = info.PointerPosition.Position.x;
            self.y = info.PointerPosition.Position.y;
        }
        if info.PointerShapeBufferSize == 0 {
            return Ok(());
        }

        let mut raw = vec![0u8; info.PointerShapeBufferSize as usize];
        let mut required = 0;
        let mut shape_info = DXGI_OUTDUPL_POINTER_SHAPE_INFO::default();
        unsafe {
            duplication.GetFramePointerShape(
                raw.len() as u32,
                raw.as_mut_ptr().cast(),
                &mut required,
                &mut shape_info,
            )
        }
        .context("GetFramePointerShape")?;

        let Some((rgba, xor, width, height, pitch)) = convert_shape(&raw, shape_info)? else {
            return Ok(());
        };
        let view = create_cursor_view(&self.device, &rgba, width, height, pitch)?;
        let xor_view = xor
            .as_ref()
            .map(|pixels| create_cursor_view(&self.device, pixels, width, height, pitch))
            .transpose()?;
        self.shape = Some(CursorShape {
            view,
            xor_view,
            width,
            height,
        });
        Ok(())
    }

    pub fn draw(&self, context: &ID3D11DeviceContext) {
        let Some(shape) = &self.shape else { return };
        if !self.visible {
            return;
        }
        let left = 2.0 * self.x as f32 / self.frame_width as f32 - 1.0;
        let right = 2.0 * (self.x + shape.width as i32) as f32 / self.frame_width as f32 - 1.0;
        let top = 1.0 - 2.0 * self.y as f32 / self.frame_height as f32;
        let bottom = 1.0 - 2.0 * (self.y + shape.height as i32) as f32 / self.frame_height as f32;
        let constants = CursorConstants {
            rect: [left, top, right, bottom],
        };
        let viewport = D3D11_VIEWPORT {
            Width: self.frame_width as f32,
            Height: self.frame_height as f32,
            MinDepth: 0.0,
            MaxDepth: 1.0,
            ..Default::default()
        };

        unsafe {
            context.UpdateSubresource(
                &self.constants,
                0,
                None,
                (&constants as *const CursorConstants).cast(),
                0,
                0,
            );
            context.RSSetViewports(Some(&[viewport]));
            context.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
            context.VSSetShader(&self.vertex_shader, None);
            context.VSSetConstantBuffers(0, Some(&[Some(self.constants.clone())]));
            context.PSSetShader(&self.pixel_shader, None);
            context.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
            context.PSSetShaderResources(0, Some(&[Some(shape.view.clone())]));
            context.OMSetBlendState(&self.blend, None, u32::MAX);
            context.OMSetRenderTargets(
                Some(&[Some(self.target.clone())]),
                None::<&ID3D11DepthStencilView>,
            );
            context.Draw(4, 0);

            if let Some(xor_view) = &shape.xor_view {
                context.PSSetShaderResources(0, Some(&[Some(xor_view.clone())]));
                context.OMSetBlendState(&self.xor_blend, None, u32::MAX);
                context.Draw(4, 0);
            }

            // Release the references held by the immediate context before a
            // pointer-shape update replaces its small texture.
            context.PSSetShaderResources(0, Some(&[None]));
            context.OMSetRenderTargets(None, None::<&ID3D11DepthStencilView>);
        }
    }
}

fn create_blend_state(device: &ID3D11Device, xor: bool) -> Result<ID3D11BlendState> {
    let mut desc = D3D11_BLEND_DESC::default();
    let target = &mut desc.RenderTarget[0];
    target.BlendEnable = BOOL::from(true);
    target.SrcBlend = if xor {
        D3D11_BLEND_INV_DEST_COLOR
    } else {
        D3D11_BLEND_SRC_ALPHA
    };
    target.DestBlend = if xor {
        D3D11_BLEND_INV_SRC_COLOR
    } else {
        D3D11_BLEND_INV_SRC_ALPHA
    };
    target.BlendOp = D3D11_BLEND_OP_ADD;
    target.SrcBlendAlpha = D3D11_BLEND_ONE;
    target.DestBlendAlpha = D3D11_BLEND_ZERO;
    target.BlendOpAlpha = D3D11_BLEND_OP_ADD;
    target.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8;
    let mut state = None;
    unsafe { device.CreateBlendState(&desc, Some(&mut state)) }
        .context("CreateBlendState(cursor)")?;
    state.ok_or_else(|| anyhow!("cursor blend state was not created"))
}

fn create_cursor_view(
    device: &ID3D11Device,
    pixels: &[u8],
    width: u32,
    height: u32,
    pitch: u32,
) -> Result<ID3D11ShaderResourceView> {
    let needed = pitch as usize * height as usize;
    if pixels.len() < needed {
        bail!("cursor shape has {} bytes, needs {needed}", pixels.len());
    }
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_IMMUTABLE,
        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
        ..Default::default()
    };
    let initial = D3D11_SUBRESOURCE_DATA {
        pSysMem: pixels.as_ptr().cast(),
        SysMemPitch: pitch,
        SysMemSlicePitch: needed as u32,
    };
    let mut texture = None;
    unsafe { device.CreateTexture2D(&desc, Some(&initial), Some(&mut texture)) }
        .context("CreateTexture2D(cursor)")?;
    let texture = texture.ok_or_else(|| anyhow!("cursor texture was not created"))?;
    let mut view = None;
    unsafe { device.CreateShaderResourceView(&texture, None, Some(&mut view)) }
        .context("CreateShaderResourceView(cursor)")?;
    view.ok_or_else(|| anyhow!("cursor texture view was not created"))
}

type ConvertedShape = (Vec<u8>, Option<Vec<u8>>, u32, u32, u32);

fn convert_shape(
    raw: &[u8],
    info: DXGI_OUTDUPL_POINTER_SHAPE_INFO,
) -> Result<Option<ConvertedShape>> {
    if info.Width == 0 || info.Height == 0 || info.Pitch == 0 {
        bail!("Desktop Duplication returned an empty cursor shape");
    }
    let needed = info.Pitch as usize * info.Height as usize;
    if raw.len() < needed {
        bail!("cursor shape has {} bytes, needs {needed}", raw.len());
    }

    if info.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR.0 as u32 {
        return Ok(Some((
            raw[..needed].to_vec(),
            None,
            info.Width,
            info.Height,
            info.Pitch,
        )));
    }

    if info.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR.0 as u32 {
        let mut rgba = raw[..needed].to_vec();
        let mut xor = rgba.clone();
        for y in 0..info.Height as usize {
            for x in 0..info.Width as usize {
                let alpha = y * info.Pitch as usize + x * 4 + 3;
                rgba[alpha] = if raw[alpha] == 0 { 0xff } else { 0 };
                xor[alpha] = if raw[alpha] == 0 { 0 } else { 0xff };
            }
        }
        return Ok(Some((rgba, Some(xor), info.Width, info.Height, info.Pitch)));
    }

    if info.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME.0 as u32 {
        let height = info.Height / 2;
        if height == 0 {
            bail!("monochrome cursor has no image rows");
        }
        let mask_size = info.Pitch as usize * height as usize;
        let pitch = info.Width * 4;
        let mut rgba = vec![0u8; pitch as usize * height as usize];
        let mut xor = vec![0u8; rgba.len()];
        for y in 0..height as usize {
            for x in 0..info.Width as usize {
                let mask = y * info.Pitch as usize + x / 8;
                let bit = 7 - (x % 8);
                let and_value = (raw[mask] >> bit) & 1;
                let xor_value = (raw[mask + mask_size] >> bit) & 1;
                let pixel = y * pitch as usize + x * 4;
                match (and_value, xor_value) {
                    (0, 0) => rgba[pixel + 3] = 0xff,
                    (0, 1) => rgba[pixel..pixel + 4].fill(0xff),
                    (1, 1) => xor[pixel..pixel + 4].fill(0xff),
                    _ => {}
                }
            }
        }
        return Ok(Some((rgba, Some(xor), info.Width, height, pitch)));
    }

    log::warn!(
        "unsupported Desktop Duplication cursor shape type {}",
        info.Type
    );
    Ok(None)
}

fn compile(entry: &str, target: &str) -> Result<ID3DBlob> {
    let entry = format!("{entry}\0");
    let target = format!("{target}\0");
    let mut code = None;
    let mut errors = None;
    let result = unsafe {
        D3DCompile(
            SHADER.as_ptr().cast::<c_void>(),
            SHADER.len(),
            PCSTR::null(),
            None,
            None::<&ID3DInclude>,
            PCSTR::from_raw(entry.as_ptr()),
            PCSTR::from_raw(target.as_ptr()),
            D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    if let Err(error) = result {
        let detail = errors
            .as_ref()
            .map(|blob| String::from_utf8_lossy(unsafe { blob_bytes(blob) }).into_owned())
            .unwrap_or_default();
        bail!("D3DCompile({target:?}) failed: {error}: {detail}");
    }
    code.ok_or_else(|| anyhow!("D3DCompile returned no shader bytecode"))
}

unsafe fn blob_bytes(blob: &ID3DBlob) -> &[u8] {
    std::slice::from_raw_parts(blob.GetBufferPointer().cast(), blob.GetBufferSize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_shaders_compile() {
        assert!(unsafe { blob_bytes(&compile("vs_main", "vs_5_0").unwrap()) }.len() > 32);
        assert!(unsafe { blob_bytes(&compile("ps_main", "ps_5_0").unwrap()) }.len() > 32);
    }

    #[test]
    fn masked_cursor_splits_replace_and_xor_pixels() {
        let raw = [10, 20, 30, 0, 40, 50, 60, 0xff];
        let info = DXGI_OUTDUPL_POINTER_SHAPE_INFO {
            Type: DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR.0 as u32,
            Width: 2,
            Height: 1,
            Pitch: 8,
            ..Default::default()
        };
        let (rgba, xor, width, height, pitch) = convert_shape(&raw, info).unwrap().unwrap();
        assert_eq!((width, height, pitch), (2, 1, 8));
        assert_eq!(rgba[3], 0xff);
        assert_eq!(rgba[7], 0);
        let xor = xor.unwrap();
        assert_eq!(xor[3], 0);
        assert_eq!(xor[7], 0xff);
    }
}
