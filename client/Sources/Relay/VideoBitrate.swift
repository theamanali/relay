import Foundation

/// User-facing CBR bitrate and its logarithmic slider mapping.
enum VideoBitrate {
    static let minimum = 1
    static let maximum = 1_000
    static let defaultValue = 120

    static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    /// Bits per pixel of the old fixed default, 120 Mbps at 3024 × 1964 and
    /// 120 Hz: the automatic bitrate keeps each frame's share, so a smaller
    /// or slower mode asks for less (over the cable every 120 Mbps costs
    /// about 1 ms of transfer per frame).
    static let automaticBitsPerPixel = 120e6 / (3024 * 1964 * 120)
    static let automaticRange = 20...200
    /// Wi-Fi rarely sustains more; the PC ends a stream the link can't carry.
    static let automaticWiFiCap = 80

    static func automatic(width: Int, height: Int, refresh: Int, overWiFi: Bool) -> Int {
        let raw = Double(width * height * max(refresh, 1)) * automaticBitsPerPixel / 1e6
        let rounded = Int((raw / 10).rounded()) * 10
        let clamped = min(automaticRange.upperBound, max(automaticRange.lowerBound, rounded))
        return overWiFi ? min(clamped, automaticWiFiCap) : clamped
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
