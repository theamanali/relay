// User-facing session options that used to be launch flags only. Remembered
// in UserDefaults; a flag given on the command line wins for that launch.

import Foundation

/// How wheel and trackpad scrolling reaches the PC.
enum ScrollDirection: String, CaseIterable {
    /// Whatever this Mac's own Natural scrolling setting does.
    case system
    /// Content follows the fingers, as macOS Natural scrolling.
    case natural
    /// The traditional direction Windows uses by default.
    case standard

    /// Multiplier for a scroll event's deltas. AppKit's deltas already follow
    /// this Mac's setting; `invertedFromDevice` says whether that is Natural.
    func sign(invertedFromDevice: Bool) -> Double {
        switch self {
        case .system: 1
        case .natural: invertedFromDevice ? 1 : -1
        case .standard: invertedFromDevice ? -1 : 1
        }
    }
}

struct SessionPrefs: Equatable {
    var modifiers: ModifierMapping = .mac
    var forwardInput = true
    var showLatency = false
    var bitrateMbps = VideoBitrate.defaultValue
    /// Metal VSync: no tearing, up to a frame more delay.
    var preventTearing = false
    var scrollDirection: ScrollDirection = .system

    /// The settings checkbox: Natural scrolling on the PC. Until the user
    /// picks, it shows (and keeps) whatever this Mac itself does.
    func naturalScrolling(macNatural: Bool) -> Bool {
        switch scrollDirection {
        case .system: macNatural
        case .natural: true
        case .standard: false
        }
    }

    /// This Mac's own Natural scrolling setting (System Settings ▸ Trackpad),
    /// on by default.
    static var macNaturalScrolling: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    private static let modifiersKey = "modifierMapping"
    private static let forwardInputKey = "forwardInput"
    private static let showLatencyKey = "showLatency"
    private static let bitrateKey = "videoBitrateMbps"
    private static let preventTearingKey = "preventTearing"
    private static let scrollDirectionKey = "scrollDirection"

    static func load(from d: UserDefaults = .standard) -> SessionPrefs {
        var p = SessionPrefs()
        if let raw = d.string(forKey: modifiersKey), let m = ModifierMapping(rawValue: raw) { p.modifiers = m }
        if d.object(forKey: forwardInputKey) != nil { p.forwardInput = d.bool(forKey: forwardInputKey) }
        if d.object(forKey: showLatencyKey) != nil { p.showLatency = d.bool(forKey: showLatencyKey) }
        if d.object(forKey: bitrateKey) != nil {
            p.bitrateMbps = VideoBitrate.clamp(d.integer(forKey: bitrateKey))
        }
        if d.object(forKey: preventTearingKey) != nil { p.preventTearing = d.bool(forKey: preventTearingKey) }
        if let raw = d.string(forKey: scrollDirectionKey), let s = ScrollDirection(rawValue: raw) { p.scrollDirection = s }
        return p
    }

    func save(to d: UserDefaults = .standard) {
        d.set(modifiers.rawValue, forKey: Self.modifiersKey)
        d.set(forwardInput, forKey: Self.forwardInputKey)
        d.set(showLatency, forKey: Self.showLatencyKey)
        d.set(VideoBitrate.clamp(bitrateMbps), forKey: Self.bitrateKey)
        d.set(preventTearing, forKey: Self.preventTearingKey)
        d.set(scrollDirection.rawValue, forKey: Self.scrollDirectionKey)
    }

    /// Command-line flags override the remembered values for this launch.
    func overridden(by o: LaunchOptions) -> SessionPrefs {
        var p = self
        if o.modifiersGiven { p.modifiers = o.modifiers }
        if o.noInput { p.forwardInput = false }
        if o.showLatency { p.showLatency = true }
        if o.bitrateGiven { p.bitrateMbps = o.bitrateMbps }
        if o.metalVSync { p.preventTearing = true }
        return p
    }
}
