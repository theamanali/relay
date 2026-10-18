import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import simd

/// One pending decoded image, one GPU submission. Drawable waits never hold
/// the decoder or connection queue. The decoder's biplanar YCbCr output is
/// wrapped as two Metal textures over the same IOSurface (no copy) and
/// converted to RGB by a fixed shader; the pixel buffer's attachments choose
/// the matrix and range. No Core Image, no intermediates.
// GPU resources are immutable after init; presentation work uses queue.
// Mailbox, generation and metrics are lock-protected. Layer layout is UI-owned.
final class MetalPresenter: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let commands: MTLCommandQueue
    /// One per drawable format: 8-bit streams keep `bgra8Unorm` (the path
    /// latency was measured on); 10-bit streams draw into `bgr10a2Unorm` so
    /// their extra precision reaches the screen.
    private let pipelines: [MTLPixelFormat: MTLRenderPipelineState]
    /// The HUD, alpha-blended over the picture in the same pass.
    private let overlayPipelines: [MTLPixelFormat: MTLRenderPipelineState]
    /// The HUD bitmap and its distance from the top-left corner, in drawable
    /// pixels; replaced whole, never written while the GPU may read it.
    private var overlay: (texture: MTLTexture, margin: Int)?
    /// The layer format the newest frame wants; applied before the next drawable.
    private var wantedLayerFormat = MTLPixelFormat.bgra8Unorm
    private let sampler: MTLSamplerState
    private let nearest: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "relay.present", qos: .userInteractive)
    private let lock = NSLock()
    /// Pixel buffers are retained and read-only after decoder submission.
    private struct Frame: @unchecked Sendable {
        let image: CVPixelBuffer
        let pts: CMTime
        let sequence: UInt64
        let generation: Int
    }
    /// Immutable texture views retained solely to keep IOSurfaces alive until completion.
    private struct TextureLifetime: @unchecked Sendable {
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
    }
    private var mailbox = LatestFrame<Frame>()
    private var running = false
    private var generation = 0
    private var dropped = 0
    private var unavailable = 0
    private var gpuFailures = 0
    private var unsupportedFormats = 0
    /// Each shown frame: its sequence, when it reached the screen (seconds
    /// on the host clock, the same base as `systemUptime`) and receive → on
    /// screen in ms; on Metal's callback thread. Set before the first frame.
    var presentedHandler: (@Sendable (_ sequence: UInt64, _ presentedAt: Double, _ milliseconds: Double) -> Void)?

    /// Pixel formats the shader accepts: biplanar 4:2:0 or 4:4:4, 8- or
    /// 10-bit, video or full range. 4:4:4's chroma plane is simply full size;
    /// the shader samples by normalized coordinates either way.
    static let pixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
    ]

    static func isTenBit(_ format: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(format)
    }

    static func isFullRange(_ format: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(format)
    }

    /// "420v", "x444": for logs.
    static func fourCC(_ format: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xff) }, encoding: .ascii) ?? String(format, radix: 16)
    }

    static func layerFormat(for image: CVPixelBuffer) -> MTLPixelFormat {
        isTenBit(CVPixelBufferGetPixelFormatType(image)) ? .bgr10a2Unorm : .bgra8Unorm
    }

    /// Matches `Uniforms` in the shader source. `scale` is the aspect-fit
    /// size of the picture in clip space; the matrix and offset turn a
    /// (Y, Cb, Cr) sample into RGB.
    private struct Uniforms {
        var scale: SIMD2<Float>
        var offset: SIMD3<Float>
        var matrix: simd_float3x3
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 scale;
        float3 offset;
        float3x3 matrix;
    };

    struct Vertex {
        float4 position [[position]];
        float2 uv;
    };

    // Full-screen strip of four vertices, shrunk to the aspect-fitted picture.
    vertex Vertex pictureVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 corner = float2(id & 1, id >> 1);          // 0/1 in x and y
        Vertex out;
        out.position = float4((corner * 2.0 - 1.0) * u.scale, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 ycbcrToRGB(Vertex in [[stage_in]],
                            texture2d<float> luma [[texture(0)]],
                            texture2d<float> chroma [[texture(1)]],
                            sampler s [[sampler(0)]],
                            constant Uniforms &u [[buffer(0)]]) {
        float3 ycbcr = float3(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg);
        return float4(u.matrix * (ycbcr + u.offset), 1.0);
    }

    struct OverlayRect {
        float2 origin;   // top-left, clip space
        float2 size;     // clip space, y down
    };

    vertex Vertex overlayVertex(uint id [[vertex_id]], constant OverlayRect &r [[buffer(0)]]) {
        float2 corner = float2(id & 1, id >> 1);
        Vertex out;
        out.position = float4(r.origin + corner * float2(r.size.x, -r.size.y), 0.0, 1.0);
        out.uv = corner;
        return out;
    }

    // Premultiplied BGRA from CoreGraphics; blending is one / one-minus-alpha.
    fragment float4 overlayFragment(Vertex in [[stage_in]], texture2d<float> hud [[texture(0)]],
                                    sampler s [[sampler(0)]]) {
        return hud.sample(s, in.uv);
    }
    """

    init?(vsync: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commands = device.makeCommandQueue() else { return nil }
        self.commands = commands
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "pictureVertex")
            desc.fragmentFunction = library.makeFunction(name: "ycbcrToRGB")
            let overlay = MTLRenderPipelineDescriptor()
            overlay.vertexFunction = library.makeFunction(name: "overlayVertex")
            overlay.fragmentFunction = library.makeFunction(name: "overlayFragment")
            let blend = overlay.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .one
            blend.sourceAlphaBlendFactor = .one
            blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            var overlayPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .bgr10a2Unorm] {
                desc.colorAttachments[0].pixelFormat = format
                pipelines[format] = try device.makeRenderPipelineState(descriptor: desc)
                overlay.colorAttachments[0].pixelFormat = format
                overlayPipelines[format] = try device.makeRenderPipelineState(descriptor: overlay)
            }
            self.pipelines = pipelines
            self.overlayPipelines = overlayPipelines
        } catch {
            NSLog("MetalPresenter: shader build failed: %@", String(describing: error))
            return nil
        }
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.sampler = sampler
        samplerDesc.minFilter = .nearest
        samplerDesc.magFilter = .nearest
        guard let nearest = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.nearest = nearest
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            NSLog("MetalPresenter: texture cache creation failed")
            return nil
        }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Direct-to-display (bypassing the compositor when VSync is off)
        // requires an opaque layer covering the screen with nothing drawn on
        // top, which is why the latency HUD is drawn into the frame itself.
        layer.isOpaque = true
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        setVSync(vsync)
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Prevent screen tearing, at up to a frame of delay; takes effect with
    /// the next drawable, so it can change mid-session.
    func setVSync(_ on: Bool) {
        guard layer.displaySyncEnabled != on || !vsyncLogged else { return }
        vsyncLogged = true
        layer.displaySyncEnabled = on
        NSLog("MetalPresenter: VSync %@", on ? "on" : "off (tearing possible)")
    }
    private var vsyncLogged = false

    /// Show `image` (premultiplied, top-left at `marginPixels` from the
    /// drawable's corner) on every frame from the next one on; nil removes it.
    /// A new texture each time, so a frame in flight keeps the old one.
    func setOverlay(_ image: CGImage?, marginPixels: Int) {
        guard let image else { lock.withLock { overlay = nil }; return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width,
                                                            height: image.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let bytesPerRow = image.width * 4
        guard let texture = commands.device.makeTexture(descriptor: desc),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: bytesPerRow)
        lock.withLock { overlay = (texture, marginPixels) }
    }

    func reset(generation: Int, clearMetrics: Bool = false) {
        lock.withLock {
            self.generation = generation
            mailbox.reset(generation: generation, clearMetrics: clearMetrics)
            if clearMetrics { dropped = 0; unavailable = 0; gpuFailures = 0; unsupportedFormats = 0 }
        }
        queue.async { if let cache = self.textureCache { CVMetalTextureCacheFlush(cache, 0) } }
    }

    func submit(_ image: CVPixelBuffer, pts: CMTime, sequence: UInt64, generation: Int) {
        lock.lock()
        guard mailbox.offer(Frame(image: image, pts: pts, sequence: sequence, generation: generation),
                            sequence: sequence, generation: generation) else {
            lock.unlock()
            return
        }
        wantedLayerFormat = Self.layerFormat(for: image)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.draw() } }
    }

    // MARK: colour

    /// BT.601/709/2020 matrix and range for a decoded buffer. NVENC signals
    /// nothing in the VUI, so the decoder's default attachments decide; this
    /// only reads them, the same as Core Image did.
    static func conversion(for image: CVPixelBuffer) -> (offset: SIMD3<Float>, matrix: simd_float3x3) {
        let format = CVPixelBufferGetPixelFormatType(image)
        let fullRange = isFullRange(format)
        // A sample's code value per 1.0 of the texture's normalized read:
        // 255 for 8-bit; 10-bit samples sit in the top bits of 16 (r16Unorm
        // reads code × 64 / 65535), so 65535 / 64 for them.
        let bits: Float = isTenBit(format) ? 10 : 8
        let unit: Float = isTenBit(format) ? 65535 / 64 : 255
        let step = powf(2, bits - 8)           // 1 for 8-bit, 4 for 10-bit
        let maxCode = powf(2, bits) - 1        // 255 or 1023
        let matrixKey = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let kr: Float
        let kb: Float
        switch matrixKey.map({ $0 as CFString }) {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4?: (kr, kb) = (0.299, 0.114)
        case kCVImageBufferYCbCrMatrix_ITU_R_2020?: (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.2126, 0.0722) // 709
        }
        let kg = 1 - kr - kb
        // Y'CbCr -> R'G'B' for the given luma coefficients.
        let r = SIMD3<Float>(1, 0, 2 * (1 - kr))
        let g = SIMD3<Float>(1, -2 * (1 - kb) * kb / kg, -2 * (1 - kr) * kr / kg)
        let b = SIMD3<Float>(1, 2 * (1 - kb), 0)
        var matrix = simd_float3x3(rows: [r, g, b])
        let mid = 128 * step / unit
        var offset = SIMD3<Float>(0, -mid, -mid)
        if fullRange {
            matrix = matrix * simd_float3x3(diagonal: SIMD3<Float>(repeating: unit / maxCode))
        } else {
            // Limited range: Y in 16..235, chroma in 16..240 (×4 for 10-bit).
            offset.x = -16 * step / unit
            matrix = matrix * simd_float3x3(diagonal: SIMD3<Float>(unit / (219 * step), unit / (224 * step), unit / (224 * step)))
        }
        return (offset, matrix)
    }

    private func textures(for image: CVPixelBuffer) -> (CVMetalTexture, CVMetalTexture)? {
        guard let textureCache, CVPixelBufferGetPlaneCount(image) == 2 else { return nil }
        func plane(_ i: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
            var t: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(image, i), h = CVPixelBufferGetHeightOfPlane(image, i)
            let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, image, nil, format, w, h, i, &t)
            return r == kCVReturnSuccess ? t : nil
        }
        let tenBit = Self.isTenBit(CVPixelBufferGetPixelFormatType(image))
        guard let y = plane(0, tenBit ? .r16Unorm : .r8Unorm),
              let cbcr = plane(1, tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
        return (y, cbcr)
    }

    /// One render pass: clear to black, draw the aspect-fitted picture, then
    /// the HUD if one is set.
    @discardableResult
    private func encode(_ image: CVPixelBuffer, luma: MTLTexture, chroma: MTLTexture,
                        into target: MTLTexture, command: MTLCommandBuffer) -> Bool {
        let picture = SIMD2(Float(CVPixelBufferGetWidth(image)), Float(CVPixelBufferGetHeight(image)))
        let bounds = SIMD2(Float(target.width), Float(target.height))
        let fit = min(bounds.x / picture.x, bounds.y / picture.y)
        let (offset, matrix) = Self.conversion(for: image)
        var uniforms = Uniforms(scale: picture * fit / bounds, offset: offset, matrix: matrix)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let pipeline = pipelines[target.pixelFormat],
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let overlay = lock.withLock({ overlay }), let overlayPipeline = overlayPipelines[target.pixelFormat] {
            // Pixel-exact: one texel per drawable pixel, so nearest sampling.
            var rect = SIMD4<Float>(-1 + 2 * Float(overlay.margin) / bounds.x,
                                    1 - 2 * Float(overlay.margin) / bounds.y,
                                    2 * Float(overlay.texture.width) / bounds.x,
                                    2 * Float(overlay.texture.height) / bounds.y)
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(overlay.texture, index: 0)
            encoder.setFragmentSamplerState(nearest, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return true
    }

    /// Test hook: render `image` into a fresh BGRA texture of the given size
    /// and return its bytes (row-major, 4 bytes per pixel), or nil.
    func renderOffscreen(_ image: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        guard Self.pixelFormats.contains(CVPixelBufferGetPixelFormatType(image)),
              let (luma, chroma) = textures(for: image),
              let lumaTex = CVMetalTextureGetTexture(luma),
              let chromaTex = CVMetalTextureGetTexture(chroma) else { return nil }
        let format = Self.layerFormat(for: image)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .shared
        guard let target = commands.device.makeTexture(descriptor: desc),
              let command = commands.makeCommandBuffer(),
              encode(image, luma: lumaTex, chroma: chromaTex, into: target, command: command) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime((image, luma, chroma)) {}
        var out = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard format == .bgr10a2Unorm else { return out }
        // Unpack 10:10:10:2 (blue in the low bits) to the same BGRA bytes.
        for i in stride(from: 0, to: out.count, by: 4) {
            let v = UInt32(out[i]) | UInt32(out[i + 1]) << 8 | UInt32(out[i + 2]) << 16 | UInt32(out[i + 3]) << 24
            func eight(_ c: UInt32) -> UInt8 { UInt8((c * 255 + 511) / 1023) }
            out[i] = eight(v & 0x3ff); out[i + 1] = eight(v >> 10 & 0x3ff); out[i + 2] = eight(v >> 20 & 0x3ff); out[i + 3] = 255
        }
        return out
    }

    // MARK: drawing

    private func draw() {
        autoreleasepool {
            // Wait first, then take the newest image, including arrivals during
            // the drawable wait. The mailbox remains available to VT callbacks.
            let wanted = lock.withLock { wantedLayerFormat }
            if layer.pixelFormat != wanted { layer.pixelFormat = wanted }
            guard let drawable = layer.nextDrawable(), let command = commands.makeCommandBuffer() else {
                lock.withLock { if mailbox.take() != nil { unavailable += 1 }; running = false }
                return
            }
            guard let frame = lock.withLock({ () -> Frame? in
                let frame = mailbox.take()
                if frame == nil { running = false }
                return frame
            }) else { return }

            guard Self.pixelFormats.contains(CVPixelBufferGetPixelFormatType(frame.image)),
                  let (luma, chroma) = textures(for: frame.image),
                  let lumaTex = CVMetalTextureGetTexture(luma),
                  let chromaTex = CVMetalTextureGetTexture(chroma) else {
                lock.withLock { unsupportedFormats += 1 }
                if lock.withLock({ unsupportedFormats == 1 }) {
                    NSLog("MetalPresenter: unsupported pixel format %08x", CVPixelBufferGetPixelFormatType(frame.image))
                }
                queue.async { self.continueDrawing() }
                return
            }

            guard encode(frame.image, luma: lumaTex, chroma: chromaTex, into: drawable.texture, command: command) else {
                lock.withLock { unavailable += 1 }
                queue.async { self.continueDrawing() }
                return
            }

            drawable.addPresentedHandler { [weak self] shown in
                guard let self else { return }
                let current = self.lock.withLock { () -> Bool in
                    guard frame.generation == self.generation else { return false }
                    if shown.presentedTime <= 0 { self.dropped += 1; return false }
                    return true
                }
                guard current else { return }
                self.presentedHandler?(frame.sequence, shown.presentedTime,
                                       (shown.presentedTime - CMTimeGetSeconds(frame.pts)) * 1_000)
            }
            let resources = TextureLifetime(luma: luma, chroma: chroma)
            command.addCompletedHandler { [weak self] buffer in
                // Keep the IOSurface and its texture views alive until GPU reads finish.
                withExtendedLifetime((frame.image, resources)) {}
                guard let self else { return }
                if buffer.status == .error {
                    self.lock.withLock {
                        if frame.generation == self.generation { self.gpuFailures += 1 }
                    }
                    NSLog("Metal presentation failed: %@", String(describing: buffer.error))
                }
                self.queue.async { self.continueDrawing() }
            }
            lock.lock()
            guard frame.generation == generation else {
                lock.unlock()
                queue.async { self.continueDrawing() }
                return
            }
            command.present(drawable)
            command.commit()
            lock.unlock()
        }
    }

    private func continueDrawing() {
        let more = lock.withLock { () -> Bool in
            if mailbox.pending == nil { running = false; return false }
            return true
        }
        if more { draw() }
    }

    func counters() -> PresenterCounters {
        lock.withLock {
            PresenterCounters(replaced: mailbox.replaced, late: mailbox.late, dropped: dropped,
                              unavailable: unavailable + unsupportedFormats, gpuFailures: gpuFailures)
        }
    }
}
