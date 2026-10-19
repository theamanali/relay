// The mode the client asks the host for: a same-aspect scale of whichever
// screen the picker is on, and a refresh rate that screen can show. Nothing
// here is tied to one Mac; every number comes from NSScreen at runtime.

import Foundation

struct StreamMode: Equatable {
    var scale: Double
    var refresh: Int

    static let scales: [Double] = [1.0, 0.75, 0.5]

    /// Pixel size at `scale`, rounded to even numbers for 4:2:0 chroma.
    static func size(native: CGSize, scale: Double) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(native.width * scale), even(native.height * scale))
    }

    /// Windows' scale for the virtual display, in percent: the requested
    /// pixel width over the screen's width in points (what the user sees),
    /// rounded. Native Retina sends 200, 0.75 of it 150, a 1× screen 100;
    /// the PC snaps it to the steps Windows offers. Never under 100, Windows'
    /// smallest step: a reduced mode on a 1× screen (50, 75) would otherwise
    /// be ignored and keep whatever scale Windows had. 0 when unknown.
    static func displayScale(pixelWidth: Int, pointWidth: Double) -> UInt16 {
        guard pixelWidth > 0, pointWidth > 0 else { return 0 }
        return UInt16(clamping: max(100, Int((Double(pixelWidth) / pointWidth * 100).rounded())))
    }

    static func sizes(native: CGSize) -> [(scale: Double, width: Int, height: Int)] {
        scales.map { s in
            let (w, h) = size(native: native, scale: s)
            return (s, w, h)
        }
    }

    /// Refresh rates to offer on a screen whose maximum is `max`, highest
    /// first: its top rate and 60 Hz (165/60 on a 165 Hz monitor, 120/60 on
    /// a ProMotion panel). Two, so the footer's segmented control always
    /// fits; rates in between are not offered (user decision).
    static func refreshRates(max: Int) -> [Int] {
        let cap = max > 0 ? max : 60
        return cap > 60 ? [cap, 60] : [cap]
    }

    /// The nearest offered mode for a screen (a saved 120 on a 60 Hz Air
    /// becomes 60, on a 144 Hz monitor 144; an unknown scale becomes native).
    func clamped(toMaxRefresh max: Int) -> StreamMode {
        let rates = Self.refreshRates(max: max)
        let refresh = rates.contains(refresh) ? refresh : rates.first!
        let scale = Self.scales.contains(scale) ? scale : 1.0
        return StreamMode(scale: scale, refresh: refresh)
    }

    func label(native: CGSize) -> String {
        let (w, h) = Self.size(native: native, scale: scale)
        return "\(w)×\(h) @ \(refresh) Hz"
    }

    // MARK: persistence

    private static let scaleKey = "streamScale"
    private static let refreshKey = "streamRefresh"

    static func load() -> StreamMode? {
        let d = UserDefaults.standard
        guard d.object(forKey: scaleKey) != nil, d.object(forKey: refreshKey) != nil else { return nil }
        return StreamMode(scale: d.double(forKey: scaleKey), refresh: d.integer(forKey: refreshKey))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(scale, forKey: Self.scaleKey)
        d.set(refresh, forKey: Self.refreshKey)
    }
}
