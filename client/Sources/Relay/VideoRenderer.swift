// Hardware decode through an owned VTDecompressionSession, display through
// Metal. Frames arrive in the length-prefixed
// layout VideoToolbox wants, so each FRAME message becomes one CMSampleBuffer
// with no rewriting.
//
// The layer only ever sees decoded pixel buffers. Letting it decode compressed
// samples itself means it also owns the decoder, and on a parameter-set change
// (a fullscreen game switching display mode, or the host restarting its
// encoder after Desktop Duplication drops) it drains and rebuilds that decoder
// on its own schedule; under load that is where the picture froze. Owning the
// session makes the transition explicit: invalidate the old session without
// waiting for its in-flight frames, build a new one, resync on the next
// keyframe, and drop whatever the old session still emits.

import QuartzCore
import CoreMedia
import Foundation
import VideoToolbox

struct VideoPerformanceSnapshot {
    let clientMilliseconds: Double?
    let droppedFrames: Int
    var clientP95: Double? = nil
    var backend = "metal"
    var replaced = 0
    var late = 0
    var unavailable = 0
    var samples = 0
    var gpuFailures = 0
    var invalidTimes = 0
}

/// Session mutations are serialized by SessionPipeline; decoder output shares
/// only lock-protected counters/generation. Handlers are installed before start.
final class VideoRenderer: @unchecked Sendable {
    private let metal: MetalPresenter
    var layer: CALayer { metal.layer }
    private(set) var failure: String?
    enum InitializationError: LocalizedError {
        case metalUnavailable
        var errorDescription: String? { "Relay requires Metal on an Apple silicon Mac. The Metal presenter could not be initialized." }
    }

    /// Called (on a decoder thread) when the first frame is submitted for display.
    var firstFrameHandler: (@Sendable (Int) -> Void)?
    /// Called (on a decoder thread) when the decoded picture size changes,
    /// including for the first frame. The host does not resend STREAM_START
    /// when its encoder restarts at a new display mode, so this is how the
    /// view learns the size it must letterbox pointer positions against.
    var frameSizeHandler: (@Sendable (Int, CGSize) -> Void)?
    /// Receive-to-decode-and-display-enqueue timing for each completed frame.
    /// Final presentation timing comes from Metal drawable callbacks.
    var frameDecodedHandler: (@Sendable (UInt64, Double) -> Void)?

    /// Size announced in STREAM_START; the decoded size may differ later.
    private(set) var streamSize = CGSize.zero
    /// Frames handed to the display layer since STREAM_START.
    var framesDisplayed: Int { lock.withLock { displayedCount } }

    // Decoder state, touched only from the connection queue.
    private var codec: Proto.Codec = .hevc
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = true

    // Shared with the decoder output handlers, which run on VideoToolbox threads.
    private let lock = NSLock()
    /// Bumped whenever the session is replaced; output tagged with an older
    /// generation is dropped so a late frame from before a mode change never
    /// lands on top of the new keyframe.
    private var generation = 0
    /// Set by an output handler when the current session reported a decode
    /// error; the next enqueue waits for a keyframe again.
    private var resyncRequested = false
    /// Set when the current session itself is gone (sleep/wake, GPU reset).
    private var sessionLost = false
    private var displayedCount = 0
    private var displayedSize = CGSize.zero

    init(metalVSync: Bool = false) throws {
        guard let metal = MetalPresenter(vsync: metalVSync) else { throw InitializationError.metalUnavailable }
        self.metal = metal
    }

    func isCurrent(generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func streamDidStart(_ start: Proto.StreamStart) {
        failure = nil
        codec = start.codec
        streamSize = CGSize(width: start.width, height: start.height)
        formatDescription = nil
        replaceSession()
        metal.reset(generation: generation, clearMetrics: true)
        lock.withLock {
            displayedCount = 0
            displayedSize = .zero
        }
        flush(removeImage: true)
    }

    func reset() {
        failure = nil
        formatDescription = nil
        replaceSession()
        flush(removeImage: true)
    }

    // MARK: codec config

    /// CODEC_CONFIG only arrives when the host starts or restarts its encoder,
    /// so identical bytes still mean "new stream": always a fresh session,
    /// never a comparison against the last one.
    func setParameterSets(_ sets: [Data]) {
        let previous = formatDescription.map(CMVideoFormatDescriptionGetDimensions)
        failure = nil
        formatDescription = makeFormatDescription(sets)
        if let formatDescription {
            let d = CMVideoFormatDescriptionGetDimensions(formatDescription)
            var note = "VideoRenderer: codec config \(d.width)x\(d.height)"
            if let previous { note += " (was \(previous.width)x\(previous.height))" }
            NSLog("%@", note + ", rebuilding decoder")
        } else {
            failure = "The PC sent an unsupported video configuration."
            NSLog("VideoRenderer: could not build a format description from %d parameter sets", sets.count)
        }
        replaceSession()
        // Frames the old encoder produced must not show after the new
        // keyframe, but keep the last picture up through the gap rather than
        // flashing black while the host restarts.
        flush(removeImage: false)
    }

    private func makeFormatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
        // Keep the byte buffers alive for the duration of the call.
        let buffers: [[UInt8]] = sets.map { [UInt8]($0) }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }
        for b in buffers {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(b.count, 1))
            p.initialize(from: b, count: b.count)
            storage.append(p)
            pointers.append(UnsafePointer(p))
            sizes.append(b.count)
        }

        var desc: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &desc
            )
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &desc
            )
        case .av1:
            return nil
        }
        if status != noErr {
            NSLog("VideoRenderer: format description failed: %d", status)
            return nil
        }
        return desc
    }

    // MARK: decoder session

    /// Tear down the current session (if any) and build one for the current
    /// format description. Never waits for in-flight frames: under load that
    /// wait is the stall. Their output handlers see a stale generation instead.
    private func replaceSession() {
        // Retire the generation before invalidating, and never hold the lock
        // across the VideoToolbox call: an output handler may be blocked on it.
        lock.withLock {
            generation += 1
            metal.reset(generation: generation)
            resyncRequested = false
            sessionLost = false
        }
        if let old = session {
            VTDecompressionSessionInvalidate(old)
        }
        session = formatDescription.flatMap(makeSession)
        waitingForKeyframe = true
    }

    private func makeSession(_ fd: CMVideoFormatDescription) -> VTDecompressionSession? {
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        // IOSurface-backed output so the layer displays it without a copy.
        var imageAttrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        do {
            imageAttrs[kCVPixelBufferMetalCompatibilityKey] = true
            // The shader reads 8-bit biplanar planes directly; this is the
            // hardware decoder's native output, so no conversion is added.
            imageAttrs[kCVPixelBufferPixelFormatTypeKey] = MetalPresenter.pixelFormats
        }
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &s
        )
        guard status == noErr, let s else {
            failure = "Hardware video decoding could not start (VideoToolbox \(status))."
            NSLog("VideoRenderer: decoder session failed: %d", status)
            return nil
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hardware: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: kCFAllocatorDefault, valueOut: &hardware)
        NSLog("VideoRenderer: hardware decoder %@", String(describing: hardware?.takeRetainedValue()))
        return s
    }

    // MARK: frames

    /// `nalUnits` is the raw FRAME payload: 4-byte length-prefixed NAL units.
    func enqueue(frame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime) {
        guard let formatDescription, !nalUnits.isEmpty else { return }

        let (resync, lost) = lock.withLock {
            defer { resyncRequested = false }
            return (resyncRequested, sessionLost)
        }
        if lost || session == nil {
            // The hardware session went away underneath us, or never built.
            // Only a keyframe can start the rebuilt session, so retry there
            // rather than once per frame.
            guard keyframe else { return }
            replaceSession()
            guard session != nil else { return }
        } else if resync {
            waitingForKeyframe = true
        }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }
        guard let session else { return }

        let length = nalUnits.count
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            NSLog("VideoRenderer: block buffer failed: %d", status)
            return
        }
        status = nalUnits.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard status == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            // Metal presentation compares this receipt time with the actual
            // drawable presentation time to measure the client pipeline.
            presentationTimeStamp: receivedAt,
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            NSLog("VideoRenderer: sample buffer failed: %d", status)
            return
        }
        if !keyframe {
            setAttachment(kCMSampleAttachmentKey_NotSync, on: sampleBuffer)
        }

        // Asynchronous so the connection queue goes straight back to the
        // socket; the frame is shown from the output handler when it lands.
        let gen = lock.withLock { generation }
        var infoFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags,
            outputHandler: { [weak self] status, _, image, pts, _ in
                self?.decoded(
                    image,
                    status: status,
                    pts: pts,
                    sequence: sequence,
                    generation: gen
                )
            }
        )
        if status != noErr {
            NSLog("VideoRenderer: decode submit failed: %d", status)
            if status == kVTInvalidSessionErr {
                replaceSession()
            } else {
                waitingForKeyframe = true
            }
        }
    }

    /// Output handler: runs on a VideoToolbox thread, possibly for a session
    /// that has since been replaced.
    private func decoded(
        _ image: CVImageBuffer?,
        status: OSStatus,
        pts: CMTime,
        sequence: UInt64,
        generation gen: Int
    ) {
        let decodedAt = CMClockGetTime(CMClockGetHostTimeClock())
        var first = false
        var sizeChanged = false
        var size = CGSize.zero
        var decodedMilliseconds: Double?
        lock.lock()
        defer {
            lock.unlock()
            if first { firstFrameHandler?(gen) }
            if sizeChanged { frameSizeHandler?(gen, size) }
            if let decodedMilliseconds {
                frameDecodedHandler?(sequence, decodedMilliseconds)
            }
        }
        guard gen == generation else { return } // torn-down session, expected
        guard status == noErr else {
            NSLog("VideoRenderer: decode failed: %d, resyncing on next keyframe", status)
            resyncRequested = true
            if status == kVTInvalidSessionErr { sessionLost = true }
            return
        }
        guard let image else { return } // nothing to show for this frame

        displayedCount += 1
        first = displayedCount == 1
        size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        sizeChanged = size != displayedSize
        displayedSize = size
        decodedMilliseconds = CMTimeGetSeconds(CMTimeSubtract(decodedAt, pts)) * 1_000
        metal.submit(image, pts: pts, sequence: sequence, generation: gen)
    }

    private func setAttachment(_ key: CFString, on sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func flush(removeImage: Bool) {
        let gen = lock.withLock { generation }
        DispatchQueue.main.async {
            guard self.isCurrent(generation: gen) else { return }
            self.layer.isHidden = removeImage
        }
    }

    func loadPerformanceSnapshot(_ completion: (VideoPerformanceSnapshot?) -> Void) {
        completion(metal.snapshot())
    }
}
