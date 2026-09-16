// The mode the client asks the host for: a same-aspect scale of whichever
// screen the picker is on, and a refresh rate that screen can show. Nothing
// here is tied to one Mac; every number comes from NSScreen at runtime.

import Foundation

struct StreamMode: Equatable {
    var scale: Double
    var refresh: Int

    static let scales: [Double] = [1.0, 0.75, 0.5]
    static let refreshCandidates = [120, 60]

    /// Pixel size at `scale`, rounded to even numbers for 4:2:0 chroma.
    static func size(native: CGSize, scale: Double) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(native.width * scale), even(native.height * scale))
    }

    static func sizes(native: CGSize) -> [(scale: Double, width: Int, height: Int)] {
        scales.map { s in
            let (w, h) = size(native: native, scale: s)
            return (s, w, h)
        }
    }

    /// Refresh rates to offer on a panel whose maximum is `max`, highest first.
    static func refreshRates(max: Int) -> [Int] {
        let cap = max > 0 ? max : 60
        let offered = refreshCandidates.filter { $0 <= cap }
        return offered.isEmpty ? [cap] : offered
    }

    /// The nearest offered mode for a panel (a saved 120 on a 60 Hz Air becomes 60;
    /// an unknown scale becomes native).
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
