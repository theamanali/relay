//! Numeric SDR desktop diagnostic. Presents native RGB10 patches through DWM,
//! reads actual Desktop Duplication pixels, composes a cursor into an RGB10
//! target and reads it again. This is deliberately separate from a Main10 SPS.
use super::*;
use std::fs::File;
use std::io::Write;
use std::path::Path;
use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_CPU_ACCESS_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::{
    IDXGIFactory2, DXGI_SWAP_CHAIN_DESC1, DXGI_SWAP_EFFECT_FLIP_DISCARD,
    DXGI_USAGE_RENDER_TARGET_OUTPUT,
};
use windows::Win32::UI::HiDpi::{
    SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::*;

const WIDTH: u32 = 1024;
const HEIGHT: u32 = 256;

fn patch(x: u32, y: u32) -> [u32; 3] {
    if y < 16 {
        return [
            [0, 0, 0],
            [1023, 1023, 1023],
            [1023, 0, 0],
            [0, 1023, 0],
            [0, 0, 1023],
            [1, 2, 3],
            [512, 256, 64],
            [1020, 1021, 1022],
        ][(x / 128) as usize];
    }
    let v = 400 + x / 16;
    match y / 64 {
        0 => [v, 256, 64],
        1 => [64, v, 256],
        2 => [256, 64, v],
        _ => [v, v, v],
    }
}

fn pack(rgb: [u32; 3]) -> u32 {
    rgb[0] | rgb[1] << 10 | rgb[2] << 20 | 3 << 30
}
fn unpack(value: u32, ten_bit: bool) -> [u32; 3] {
    if ten_bit {
        [value & 1023, (value >> 10) & 1023, (value >> 20) & 1023]
    } else {
        [
            ((value >> 16) & 255) * 1023 / 255,
            ((value >> 8) & 255) * 1023 / 255,
            (value & 255) * 1023 / 255,
        ]
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    DefWindowProcW(hwnd, msg, w, l)
}

struct Window(HWND);
impl Drop for Window {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.0);
        }
    }
}

fn read_pixels(
    device: &ID3D11Device,
    context: &ID3D11DeviceContext,
    texture: &ID3D11Texture2D,
) -> Result<Vec<u32>> {
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe {
        texture.GetDesc(&mut desc);
    }
    let (width, height) = (desc.Width, desc.Height);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
    desc.MiscFlags = 0;
    let mut staging = None;
    unsafe {
        device.CreateTexture2D(&desc, None, Some(&mut staging))?;
    }
    let staging = staging.context("staging texture missing")?;
    let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        context.CopyResource(&staging, texture);
        context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
        let words_per_pixel = if desc.Format
            == windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_R16G16B16A16_FLOAT
        {
            2
        } else {
            1
        };
        let mut pixels = Vec::with_capacity((width * height * words_per_pixel) as usize);
        for y in 0..height {
            pixels.extend_from_slice(std::slice::from_raw_parts(
                mapped
                    .pData
                    .cast::<u8>()
                    .add((y * mapped.RowPitch) as usize)
                    .cast::<u32>(),
                (width * words_per_pixel) as usize,
            ));
        }
        context.Unmap(&staging, 0);
        Ok(pixels)
    }
}

/// No topology or colour changes here. The caller chooses an already active
/// output; the small window is destroyed on every return path. Optional dump
/// uses the actual production capture/encode pipeline, not synthetic input.
pub fn run(
    gpu: &GpuInfo,
    display: &str,
    ten_bit: bool,
    full_color: bool,
    codec: Codec,
    dump: Option<&Path>,
    hold: Duration,
) -> Result<()> {
    let _apartment = Apartment::new()?;
    let placement = crate::display::current_placement(display)?;
    anyhow::ensure!(
        placement.width >= WIDTH + 128 && placement.height >= HEIGHT + 128,
        "display too small for precision window"
    );
    let location = crate::display::dxgi_output_for(display)?;
    probe_formats(gpu, location.adapter_index, location.output_index)?;
    anyhow::ensure!(
        location.adapter_luid == gpu.luid,
        "diagnostic requires selected NVIDIA GPU"
    );
    let (device, context, duplication, _, width, height) =
        create_capture(location.adapter_index, location.output_index, ten_bit)?;
    let format = InputFormat::for_depth(ten_bit).dxgi();
    unsafe {
        let old_dpi = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let class = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            lpszClassName: w!("RelaySdrPrecision"),
            ..Default::default()
        };
        RegisterClassW(&class);
        let created = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            w!("RelaySdrPrecision"),
            w!("Relay native RGB10 SDR precision diagnostic"),
            WS_POPUP | WS_VISIBLE,
            placement.x + 64,
            placement.y + 64,
            WIDTH as i32,
            HEIGHT as i32,
            None,
            None,
            None,
            None,
        );
        SetThreadDpiAwarenessContext(old_dpi);
        let window = Window(created?);
        let factory: IDXGIFactory2 = CreateDXGIFactory1()?;
        let desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: WIDTH,
            Height: HEIGHT,
            Format: DXGI_FORMAT_R10G10B10A2_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: 2,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            ..Default::default()
        };
        let swap = factory.CreateSwapChainForHwnd(&device, window.0, &desc, None, None)?;
        let pixels: Vec<u32> = (0..HEIGHT)
            .flat_map(|y| (0..WIDTH).map(move |x| pack(patch(x, y))))
            .collect();
        // Keep presenting until DXGI delivers this pattern, not a stale desktop.
        let deadline = Instant::now() + Duration::from_secs(8);
        let composition = create_texture(&device, width, height, format)?;
        let use_broker = ten_bit && crate::test_fault("capture-broker");
        let broker = if use_broker {
            Some(capture_source::Broker::new(
                &device, display, width, height,
            )?)
        } else {
            None
        };
        let converter = if ten_bit && !use_broker {
            Some(SdrConverter::new(&device, &composition, width, height)?)
        } else {
            None
        };
        let monitor = factory
            .EnumAdapters1(location.adapter_index)?
            .EnumOutputs(location.output_index)?
            .GetDesc()?
            .Monitor;
        let capture = if ten_bit && !use_broker {
            Some(SdrCapture::new(&device, monitor, width, height)?)
        } else {
            None
        };
        let captured = loop {
            let back: ID3D11Texture2D = swap.GetBuffer(0)?;
            context.UpdateSubresource(
                &back,
                0,
                None,
                pixels.as_ptr().cast(),
                WIDTH * 4,
                WIDTH * HEIGHT * 4,
            );
            swap.Present(1, windows::Win32::Graphics::Dxgi::DXGI_PRESENT(0))
                .ok()?;
            let result = if let Some(broker) = &broker {
                if broker.copy_latest(&context, &composition)? {
                    Some(read_pixels(&device, &context, &composition)?)
                } else {
                    None
                }
            } else if let Some(capture) = &capture {
                if let Some(frame) = capture.latest()? {
                    let texture = frame.texture()?;
                    let fp16 = read_pixels(&device, &context, &texture)?;
                    converter.as_ref().unwrap().convert(&context, &texture)?;
                    Some(
                        fp16.as_chunks::<2>()
                            .0
                            .iter()
                            .map(|v| {
                                pack([
                                    linear_to_code(half_to_float(v[0] as u16)),
                                    linear_to_code(half_to_float((v[0] >> 16) as u16)),
                                    linear_to_code(half_to_float(v[1] as u16)),
                                ])
                            })
                            .collect::<Vec<_>>(),
                    )
                } else {
                    None
                }
            } else {
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut resource = None;
                if duplication
                    .AcquireNextFrame(0, &mut info, &mut resource)
                    .is_ok()
                {
                    let result = (|| -> Result<Vec<u32>> {
                        let frame: ID3D11Texture2D =
                            resource.context("no captured resource")?.cast()?;
                        let mut desc = D3D11_TEXTURE2D_DESC::default();
                        frame.GetDesc(&mut desc);
                        anyhow::ensure!(
                            desc.Format == format,
                            "acquired format differs from expected desktop format"
                        );
                        let result = read_pixels(&device, &context, &frame)?;
                        context.CopyResource(&composition, &frame);
                        Ok(result)
                    })();
                    duplication.ReleaseFrame()?;
                    Some(result?)
                } else {
                    None
                }
            };
            if let Some(result) = result {
                let sample = unpack(result[(96 * width + 72) as usize], ten_bit);
                if sample
                    .iter()
                    .zip(patch(8, 32))
                    .all(|(a, b)| a.abs_diff(b) <= 5)
                {
                    break result;
                }
            }
            anyhow::ensure!(Instant::now() < deadline, "native RGB10 window never appeared in captured desktop (occluded or quantized beyond tolerance)");
            thread::sleep(Duration::from_millis(10));
        };
        let mut cursor = CursorOverlay::new(&device, &composition, width, height)?;
        let pristine = create_texture(&device, width, height, format)?;
        context.CopyResource(&pristine, &composition);
        // These go through the exact production shape decoding, shader and
        // blending paths. Draw outside the samples; check preserved codes
        // across each pass, plus exact monochrome inversion of RGB10 values.
        for kind in [1u32, 2, 4] {
            context.CopyResource(&composition, &pristine);
            cursor.diagnostic_shape(kind, 81, 96)?;
            cursor.draw(&context);
            let drawn = read_pixels(&device, &context, &composition)?;
            for x in 0..match kind {
                1 => 4,
                4 => 3,
                _ => 2,
            } {
                let i = (96 * width + 81 + x) as usize;
                let before = unpack(captured[i], ten_bit);
                let expected = match (kind, x) {
                    (1, 0) => [0, 0, 0],
                    (1, 1) | (2, 1) => [1023, 1023, 1023],
                    (1, 2) => before,
                    (1, 3) | (4, 1) => before.map(|v| 1023 - v),
                    (4, 2) => std::array::from_fn(|c| {
                        let mask = [201, 93, 17][c];
                        if ten_bit {
                            before[c] ^ ((mask * 1023 + 127) / 255)
                        } else {
                            (((before[c] * 255 + 511) / 1023) ^ mask) * 1023 / 255
                        }
                    }),
                    _ => [30, 20, 10].map(|v| (v * 1023 + 127) / 255),
                };
                let actual = unpack(drawn[i], ten_bit);
                anyhow::ensure!(
                    actual.iter().zip(expected).all(|(a, b)| a.abs_diff(b) <= 3),
                    "cursor kind {kind}, pixel {x}: {actual:?}, expected {expected:?}"
                );
            }
        }
        println!("normal, masked and monochrome cursor GPU checks passed (replace, transparent, black/white and invert)");
        let composed = read_pixels(&device, &context, &composition)?;
        let mut csv = String::from("band,patch,x,y,expected_r,expected_g,expected_b,capture_r,capture_g,capture_b,composed_r,composed_g,composed_b\n");
        let mut distinct = [
            std::collections::BTreeSet::new(),
            std::collections::BTreeSet::new(),
            std::collections::BTreeSet::new(),
            std::collections::BTreeSet::new(),
        ];
        let mut max_error = 0;
        let mut composed_error = 0;
        let mut composed_distinct: [std::collections::BTreeSet<u32>; 4] = Default::default();
        for band in 0..4 {
            for step in 0..64 {
                let x = step * 16 + 8;
                let y = band * 64 + 32;
                let index = ((y + 64) * width + x + 64) as usize;
                let expected = patch(x, y);
                let raw = unpack(captured[index], ten_bit);
                let after = unpack(composed[index], ten_bit);
                anyhow::ensure!(
                    raw.iter()
                        .zip(after)
                        .all(|(a, b)| a.abs_diff(b) <= u32::from(ten_bit)),
                    "cursor composition reduced precision outside cursor: {raw:?} -> {after:?}"
                );
                for i in 0..3 {
                    max_error = max_error.max(raw[i].abs_diff(expected[i]));
                    composed_error = composed_error.max(after[i].abs_diff(expected[i]));
                }
                distinct[band as usize].insert(raw[band.min(2) as usize]);
                composed_distinct[band as usize].insert(after[band.min(2) as usize]);
                csv.push_str(&format!(
                    "{band},{step},{},{},{},{},{},{},{},{},{},{},{}\n",
                    x + 64,
                    y + 64,
                    expected[0],
                    expected[1],
                    expected[2],
                    raw[0],
                    raw[1],
                    raw[2],
                    after[0],
                    after[1],
                    after[2]
                ));
            }
        }
        for step in 0..8 {
            let (x, y) = (step * 128 + 64, 8);
            let i = ((y + 64) * width + x + 64) as usize;
            let expected = patch(x, y);
            let raw = unpack(captured[i], ten_bit);
            let after = unpack(composed[i], ten_bit);
            let tolerance = if ten_bit { 2 } else { 4 };
            anyhow::ensure!(raw.iter().zip(expected).all(|(a,b)| a.abs_diff(b) <= tolerance) && after.iter().zip(expected).all(|(a,b)| a.abs_diff(b) <= tolerance),
                "SDR range/channel control {step}: raw {raw:?}, composed {after:?}, expected {expected:?}");
            csv.push_str(&format!(
                "4,{step},{},{},{},{},{},{},{},{},{},{},{}\n",
                x + 64,
                y + 64,
                expected[0],
                expected[1],
                expected[2],
                raw[0],
                raw[1],
                raw[2],
                after[0],
                after[1],
                after[2]
            ));
        }
        println!("black/white, RGB primary, near-black and near-white numeric controls passed");
        let counts: Vec<usize> = distinct.iter().map(|s| s.len()).collect();
        println!("actual desktop capture/composition: {}-bit, distinct codes per 64-code sub-8-bit ramp {counts:?}, max RGB code error {max_error}", if ten_bit {10} else {8});
        println!("after GPU conversion/cursor composition: distinct codes {:?}, max RGB error {composed_error}", composed_distinct.iter().map(|s|s.len()).collect::<Vec<_>>());
        if let Some(path) = dump {
            std::fs::write(path.with_extension("csv"), csv)?;
        }
        anyhow::ensure!(
            max_error <= 5,
            "channel/range mismatch in captured SDR patches"
        );
        if ten_bit {
            anyhow::ensure!(
                counts.iter().all(|n| *n >= 48),
                "RGB10 texture contains quantized 8-bit source; precision NOT established"
            );
        }
        let until = Instant::now() + hold;
        while Instant::now() < until {
            let back: ID3D11Texture2D = swap.GetBuffer(0)?;
            context.UpdateSubresource(
                &back,
                0,
                None,
                pixels.as_ptr().cast(),
                WIDTH * 4,
                WIDTH * HEIGHT * 4,
            );
            swap.Present(1, windows::Win32::Graphics::Dxgi::DXGI_PRESENT(0))
                .ok()?;
            thread::sleep(Duration::from_millis(10));
        }
        drop(duplication);
        drop(capture);
        drop(broker);
        if let Some(path) = dump {
            let cfg = EncoderConfig {
                capture_adapter_idx: location.adapter_index,
                capture_luid: location.adapter_luid,
                encode_luid: gpu.luid,
                output_idx: location.output_index,
                width,
                height,
                fps: 30,
                bitrate_mbps: 200,
                codec,
                gop: 30,
                quality: Quality::Quality,
                full_color,
                ten_bit,
                intra_refresh: false,
            };
            let mut encoder = NativeNvenc::spawn(&cfg)?;
            let mut file = File::create(path)?;
            for _ in 0..12 {
                let frame = encoder
                    .next_access_unit()?
                    .context("capture ended during diagnostic encode")?;
                for nal in frame.param_sets.iter().chain(&frame.nals) {
                    file.write_all(&[0, 0, 0, 1])?;
                    file.write_all(nal)?;
                }
            }
            println!("production capture/encode dump: {} (12 frames, Best, 200 Mbps; decode and compare patch centres, lossy)",path.display());
        }
        drop(swap);
        drop(window);
    }
    Ok(())
}

fn half_to_float(v: u16) -> f32 {
    let sign = ((v as u32) & 0x8000) << 16;
    let e = ((v >> 10) & 31) as u32;
    let m = (v & 1023) as u32;
    if e == 0 {
        (if sign == 0 { 1.0 } else { -1.0 }) * m as f32 * 2f32.powi(-24)
    } else if e == 31 {
        f32::from_bits(sign | 0x7f800000 | m << 13)
    } else {
        f32::from_bits(sign | ((e + 112) << 23) | m << 13)
    }
}
fn linear_to_code(v: f32) -> u32 {
    ((if v <= 0.0031308 {
        v * 12.92
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    }) * 1023.0)
        .round()
        .clamp(0.0, 1023.0) as u32
}

fn probe_formats(gpu: &GpuInfo, adapter: u32, output: u32) -> Result<()> {
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_R16G16B16A16_FLOAT;
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
        let output: IDXGIOutput5 = factory
            .EnumAdapters1(adapter)?
            .EnumOutputs(output)?
            .cast()?;
        let device = create_device_for(gpu.luid)?;
        for formats in [
            vec![DXGI_FORMAT_R10G10B10A2_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM],
            vec![DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_B8G8R8A8_UNORM],
            vec![DXGI_FORMAT_B8G8R8A8_UNORM],
        ] {
            match output.DuplicateOutput1(&device, 0, &formats) {
                Ok(dup) => println!(
                    "format probe {formats:?}: duplication {:?}",
                    dup.GetDesc().ModeDesc.Format
                ),
                Err(e) => println!("format probe {formats:?}: {e}"),
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rgb10_packing_keeps_sub_8_bit_steps_and_channel_order() {
        for r in 0..1024 {
            assert_eq!(unpack(pack([r, 256, 64]), true), [r, 256, 64]);
        }
        let unique: std::collections::BTreeSet<_> = (400..464).map(|v| v * 255 / 1023).collect();
        assert!(
            unique.len() <= 17,
            "8-bit expansion cannot pass the 48-code diagnostic threshold"
        );
    }
}
