// Hardware decode + display through AVSampleBufferDisplayLayer. Frames arrive
// already in the length-prefixed layout VideoToolbox wants, so each FRAME
// message becomes one CMSampleBuffer with no rewriting.

import AVFoundation
import CoreMedia
import Foundation

final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()

    private var codec: Proto.Codec = .hevc
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets: [Data] = []
    private var waitingForKeyframe = true
    private(set) var framesDisplayed = 0
    private(set) var streamSize = CGSize.zero

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func streamDidStart(_ start: Proto.StreamStart) {
        codec = start.codec
        streamSize = CGSize(width: start.width, height: start.height)
        formatDescription = nil
        lastParameterSets = []
        waitingForKeyframe = true
        framesDisplayed = 0
        flush(removeImage: true)
    }

    func reset() {
        formatDescription = nil
        lastParameterSets = []
        waitingForKeyframe = true
        flush(removeImage: true)
    }

    // MARK: codec config

    func setParameterSets(_ sets: [Data]) {
        guard sets != lastParameterSets else { return }
        lastParameterSets = sets
        formatDescription = makeFormatDescription(sets)
        waitingForKeyframe = true
        if formatDescription == nil {
            NSLog("VideoRenderer: could not build a format description from %d parameter sets", sets.count)
        } else {
            flush(removeImage: false)
        }
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

    // MARK: frames

    /// `nalUnits` is the raw FRAME payload: 4-byte length-prefixed NAL units.
    func enqueue(frame nalUnits: Data, keyframe: Bool) {
        guard let formatDescription, !nalUnits.isEmpty else { return }

        if layerFailed {
            NSLog("VideoRenderer: display layer failed (%@), resyncing on next keyframe",
                  layer.error?.localizedDescription ?? "unknown")
            flush(removeImage: false)
            waitingForKeyframe = true
        }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }

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
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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

        // Show each frame as soon as it is decoded; the host paces the stream.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !keyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        enqueueOnLayer(sampleBuffer)
        framesDisplayed += 1
    }

    // MARK: layer plumbing (the renderer API moved in macOS 14)

    private var layerFailed: Bool {
        if #available(macOS 14.0, *) {
            return layer.sampleBufferRenderer.status == .failed
        } else {
            return layer.status == .failed
        }
    }

    private func enqueueOnLayer(_ sb: CMSampleBuffer) {
        if #available(macOS 14.0, *) {
            layer.sampleBufferRenderer.enqueue(sb)
        } else {
            layer.enqueue(sb)
        }
    }

    private func flush(removeImage: Bool) {
        if #available(macOS 14.0, *) {
            if removeImage {
                layer.sampleBufferRenderer.flushAndRemoveImage()
            } else {
                layer.sampleBufferRenderer.flush()
            }
        } else {
            if removeImage {
                layer.flushAndRemoveImage()
            } else {
                layer.flush()
            }
        }
    }
}
