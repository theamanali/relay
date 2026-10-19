// Picture options the PC applies: its encoder preset, full 4:4:4 color and
// 10-bit color. A PC says which it offers in its TXT record (`enc`); the
// Mac asks for them in CLIENT_HELLO's extension (docs/PROTOCOL.md).

import Foundation

/// The PC's encoder preset (NVENC P1 / P4 / P6). The value is the wire byte.
enum EncoderQuality: Int, CaseIterable {
    case fastest = 1
    case balanced = 2
    case best = 3

    var title: String {
        switch self {
        case .fastest: "Fastest"
        case .balanced: "Balanced"
        case .best: "Best quality"
        }
    }

    /// The settings subtitle for this choice.
    var detail: String {
        switch self {
        case .fastest: "Lowest delay. Best for games and motion."
        case .balanced: "Sharper picture, a little more delay."
        case .best: "Sharpest picture, the most delay."
        }
    }
}

/// What a PC can do with the CLIENT_HELLO extension, from TXT `enc`
/// ("q,444,10"). A PC with no `enc` key predates it.
struct VideoFeatures: OptionSet, Equatable {
    let rawValue: Int
    static let encoderQuality = VideoFeatures(rawValue: 1)
    static let fullColor = VideoFeatures(rawValue: 2)
    static let tenBit = VideoFeatures(rawValue: 4)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(txt value: String) {
        var features: VideoFeatures = []
        for item in value.split(separator: ",") {
            switch item.trimmingCharacters(in: .whitespaces) {
            case "q": features.insert(.encoderQuality)
            case "444": features.insert(.fullColor)
            case "10": features.insert(.tenBit)
            default: break
            }
        }
        self = features
    }
}

/// CLIENT_HELLO extension `video_flags`.
enum VideoFlags {
    static let fullColor: UInt8 = 0x01
    static let tenBit: UInt8 = 0x02
}

/// Whether a picture option can be used with a PC from this Mac, and if
/// not, the one-line reason the settings show in place of its description.
enum VideoOptionAvailability: Equatable {
    case available
    case pcNeedsUpdate
    case pcCannot
    case macCannot

    var reason: String? {
        switch self {
        case .available: nil
        case .pcNeedsUpdate: "Needs Relay to be updated on the PC."
        case .pcCannot: "This PC’s GPU can’t encode it."
        case .macCannot: "This Mac can’t decode it in hardware."
        }
    }

    /// `pcFeatures` nil: the PC advertises nothing (older Relay).
    static func of(_ feature: VideoFeatures, pcFeatures: VideoFeatures?, macDecodes: Bool = true) -> Self {
        guard macDecodes else { return .macCannot }
        guard let pcFeatures else { return .pcNeedsUpdate }
        return pcFeatures.contains(feature) ? .available : .pcCannot
    }
}

/// STREAM_START's `video_format` (kept out of Protocol.swift, which fakehost
/// compiles on its own).
extension Proto.StreamStart {
    var quality: EncoderQuality? { EncoderQuality(rawValue: Int(videoFormat & 0x03)) }
    var fullColor: Bool { videoFormat & 0x04 != 0 }
    var tenBit: Bool { videoFormat & 0x08 != 0 }
    /// ["4:4:4", "10-bit", "Balanced"] for status, the HUD and logs, which
    /// join them with commas; empty when the PC reports nothing.
    var formatSettings: [String] {
        [fullColor ? "4:4:4" : nil, tenBit ? "10-bit" : nil, quality?.title].compactMap { $0 }
    }
}
