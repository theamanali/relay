import CoreImage
import CoreMedia
import Metal
import QuartzCore

/// One pending decoded image, one GPU submission. Drawable waits never hold
/// the decoder or connection queue. Core Image performs GPU YUV conversion
/// using the pixel buffer's color metadata (including full/video range).
final class MetalPresenter {
    let layer = CAMetalLayer()
    private let commands: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let queue = DispatchQueue(label: "traveldisplay.present", qos: .userInteractive)
    private let lock = NSLock()
    private struct Frame {
        let image: CVPixelBuffer
        let pts: CMTime
        let sequence: UInt64
        let generation: Int
    }
    private var mailbox = LatestFrame<Frame>()
    private var running = false
    private var generation = 0
    private var delays: [Double] = []
    private var dropped = 0
    private var unavailable = 0
    private var gpuFailures = 0
    private var invalidTimes = 0

    init?(vsync: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commands = device.makeCommandQueue() else { return nil }
        self.commands = commands
        context = CIContext(mtlCommandQueue: commands, options: [.cacheIntermediates: false])
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false // Core Image writes the drawable texture.
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = vsync
        NSLog("MetalPresenter: VSync %@", vsync ? "on" : "off (tearing possible)")
        layer.colorspace = colorSpace
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset(generation: Int, clearMetrics: Bool = false) {
        lock.withLock {
            self.generation = generation
            mailbox.reset(generation: generation, clearMetrics: clearMetrics)
            delays.removeAll()
            if clearMetrics { dropped = 0; unavailable = 0; gpuFailures = 0; invalidTimes = 0 }
        }
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
            let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
            let source = CIImage(cvPixelBuffer: frame.image)
            let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: (bounds.width - source.extent.width * scale) / 2,
                                                  y: (bounds.height - source.extent.height * scale) / 2))
                .composited(over: CIImage(color: .black).cropped(to: bounds))
            context.render(image, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
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
            command.addCompletedHandler { [weak self] buffer in
                // Retain the source until GPU reads finish.
                withExtendedLifetime(frame.image) {}
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
                                            unavailable: unavailable, samples: delays.count,
                                            gpuFailures: gpuFailures, invalidTimes: invalidTimes)
        }
    }
}
