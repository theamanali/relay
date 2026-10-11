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
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
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
    private var delays: [Double] = []
    private var dropped = 0
    private var unavailable = 0
    private var gpuFailures = 0
    private var invalidTimes = 0
    private var unsupportedFormats = 0

    /// Pixel formats the shader accepts: 8-bit biplanar 4:2:0, video or full range.
    static let pixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

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
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
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
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            NSLog("MetalPresenter: texture cache creation failed")
            return nil
        }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Direct-to-display (bypassing the compositor when VSync is off)
        // requires an opaque layer covering the screen with nothing drawn on
        // top; the latency overlay breaks that while it is visible.
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

    func reset(generation: Int, clearMetrics: Bool = false) {
        lock.withLock {
            self.generation = generation
            mailbox.reset(generation: generation, clearMetrics: clearMetrics)
            delays.removeAll()
            if clearMetrics { dropped = 0; unavailable = 0; gpuFailures = 0; invalidTimes = 0; unsupportedFormats = 0 }
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
        let fullRange = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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
        var offset = SIMD3<Float>(0, -128 / 255, -128 / 255)
        if !fullRange {
            // Limited range: Y in 16..235, chroma in 16..240.
            offset.x = -16 / 255
            matrix = matrix * simd_float3x3(diagonal: SIMD3<Float>(255 / 219, 255 / 224, 255 / 224))
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
        guard let y = plane(0, .r8Unorm), let cbcr = plane(1, .rg8Unorm) else { return nil }
        return (y, cbcr)
    }

    /// One render pass: clear to black, draw the aspect-fitted picture.
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
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
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
        return out
    }

    // MARK: drawing

    private func draw() {
        autoreleasepool {
            // Wait first, then take the newest image, including arrivals during
            // the drawable wait. The mailbox remains available to VT callbacks.
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
                self.lock.withLock {
                    guard frame.generation == self.generation else { return }
                    guard shown.presentedTime > 0 else { self.dropped += 1; return }
                    let delay = (shown.presentedTime - CMTimeGetSeconds(frame.pts)) * 1_000
                    if delay.isFinite && delay >= 0 {
                        self.delays.append(delay)
                        if self.delays.count > 600 { self.delays.removeFirst(self.delays.count - 600) }
                    } else {
                        self.invalidTimes += 1
                    }
                }
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

    func snapshot() -> VideoPerformanceSnapshot? {
        lock.withLock {
            let sorted = delays.sorted()
            return VideoPerformanceSnapshot(clientMilliseconds: delays.isEmpty ? nil : delays.reduce(0, +) / Double(delays.count),
                                            droppedFrames: dropped,
                                            clientP95: sorted.isEmpty ? nil : sorted[Int((Double(sorted.count - 1) * 0.95).rounded())],
                                            backend: "metal", replaced: mailbox.replaced, late: mailbox.late,
                                            unavailable: unavailable + unsupportedFormats, samples: delays.count,
                                            gpuFailures: gpuFailures, invalidTimes: invalidTimes)
        }
    }
}
