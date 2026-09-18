import Foundation

/// User-facing CBR bitrate and its logarithmic slider mapping.
enum VideoBitrate {
    static let minimum = 1
    static let maximum = 1_000
    static let defaultValue = 120

    static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    /// Maps 1...1000 Mbps to 0...1 so the useful low range gets enough space.
    static func sliderPosition(for bitrate: Int) -> Double {
        log(Double(clamp(bitrate))) / log(Double(maximum))
    }

    static func bitrate(forSliderPosition position: Double) -> Int {
        let position = min(1, max(0, position))
        return clamp(Int(pow(Double(maximum), position).rounded()))
    }
}
