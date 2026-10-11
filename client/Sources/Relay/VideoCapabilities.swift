// What this Mac can decode in hardware beyond HEVC Main, and the per-stream
// facts (chroma format, bit depth) that decide the decoder's output format.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The parts of an HEVC SPS that choose a pixel format.
struct HEVCStreamFormat: Equatable {
    /// 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    var chromaFormat: Int
    var bitDepth: Int

    var fullColor: Bool { chromaFormat == 3 }
    var tenBit: Bool { bitDepth > 8 }

    /// Reads `chroma_format_idc` and `bit_depth_luma_minus8` from an SPS NAL
    /// unit (2-byte header included, emulation prevention still in place).
    init?(sps nal: Data) {
        var bytes: [UInt8] = []
        var zeros = 0
        for byte in nal.dropFirst(2) {
            // 00 00 03 is an escape: drop the 03.
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            bytes.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        var r = BitReader(bytes)
        guard r.bits(4) != nil, let maxSubLayersMinus1 = r.bits(3), r.bits(1) != nil else { return nil }
        // profile_tier_level: 96 bits of general profile and level, then the
        // per-sub-layer presence flags (padded to eight) and their data.
        guard r.skip(96) else { return nil }
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            guard let p = r.bits(1), let l = r.bits(1) else { return nil }
            profilePresent.append(p == 1)
            levelPresent.append(l == 1)
        }
        if maxSubLayersMinus1 > 0 { guard r.skip(2 * (8 - maxSubLayersMinus1)) else { return nil } }
        for i in 0..<maxSubLayersMinus1 {
            guard r.skip((profilePresent[i] ? 88 : 0) + (levelPresent[i] ? 8 : 0)) else { return nil }
        }
        guard r.golomb() != nil, let chroma = r.golomb() else { return nil } // sps id, chroma_format_idc
        if chroma == 3 { guard r.bits(1) != nil else { return nil } }       // separate_colour_plane_flag
        guard r.golomb() != nil, r.golomb() != nil, let window = r.bits(1) else { return nil }
        if window == 1 { for _ in 0..<4 { guard r.golomb() != nil else { return nil } } }
        guard let depthMinus8 = r.golomb(), chroma <= 3, depthMinus8 <= 8 else { return nil }
        chromaFormat = chroma
        bitDepth = depthMinus8 + 8
    }

    init(chromaFormat: Int, bitDepth: Int) {
        self.chromaFormat = chromaFormat
        self.bitDepth = bitDepth
    }

    /// The biplanar format the presenter reads for this stream, so the
    /// decoder never converts 10-bit or 4:4:4 down. 4:2:2 is not requested
    /// by Relay and is read as 4:2:0.
    func pixelFormat(fullRange: Bool) -> OSType {
        switch (fullColor, tenBit, fullRange) {
        case (false, false, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (false, false, true): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (false, true, false): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, true, true): kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (true, false, false): kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (true, false, true): kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        case (true, true, false): kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case (true, true, true): kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        }
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bits(_ count: Int) -> Int? {
        guard position + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            value = value << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard position + count <= bytes.count * 8 else { return false }
        position += count
        return true
    }

    /// Unsigned Exp-Golomb, ue(v).
    mutating func golomb() -> Int? {
        var zeros = 0
        while true {
            guard let bit = bits(1) else { return nil }
            if bit == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let rest = bits(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }
}

/// Whether this Mac's media engine decodes HEVC 4:4:4 and 10-bit, checked
/// once by opening a hardware-only decoder for a canned 1280 × 720 stream
/// of each kind. Apple silicon always decodes HEVC Main.
enum VideoCapabilities {
    static let supports10Bit = hardwareDecodes(ParameterSets.main10)
    static let supports444 = hardwareDecodes(ParameterSets.rext444) && hardwareDecodes(ParameterSets.rext444TenBit)

    /// VPS, SPS and PPS made with ffmpeg (libx265, 1280 × 720).
    enum ParameterSets {
        static let main = sets(
            "40010c01ffff01600000030090000003000003005d959809",
            "42010101600000030090000003000003005da00280802d165959a4932bc05a020000030002000003003c10",
            "4401c172b46240")
        static let main10 = sets(
            "40010c01ffff02200000030090000003000003005d959809",
            "42010102200000030090000003000003005da00280802d1365959a4932bc05a020000003002000000303c1",
            "4401c172b46240")
        static let rext444 = sets(
            "40010c01ffff0408000003009e0800000300005d959809",
            "4201010408000003009e0800000300005d9000501005a2cb2b349265780b4040000003004000000782",
            "4401c172860c4624")
        static let rext444TenBit = sets(
            "40010c01ffff0408000003009c0800000300005d959809",
            "4201010408000003009c0800000300005d9000501005a26cb2b349265780b4040000030004000003007820",
            "4401c172860c4624")

        private static func sets(_ hex: String...) -> [Data] { hex.compactMap { Data(hex: $0) } }
    }

    static func hardwareDecodes(_ sets: [Data]) -> Bool {
        guard sets.count == 3, let format = formatDescription(sets) else { return false }
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: spec, imageBufferAttributes: nil,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    private static func formatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sets[0].withUnsafeBytes { vps in sets[1].withUnsafeBytes { sps in sets[2].withUnsafeBytes { pps in
            let pointers = [vps, sps, pps].map { $0.bindMemory(to: UInt8.self).baseAddress! }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: pointers,
                parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, extensions: nil,
                formatDescriptionOut: &format)
        }}}
        return status == noErr ? format : nil
    }
}
