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
    /// The latency HUD; ⌃⌥⌘L cycles it.
    var hudMode: HUDMode = .off
    /// Open the session report when a session ends, HUD or not (latency is
    /// measured either way). Off by default: a window after every session is
    /// for people who asked for it.
    var showSessionReport = false
    var bitrateMbps = VideoBitrate.defaultValue
    /// Follow the stream mode and link (`VideoBitrate.automatic`) until the
    /// user picks a bitrate.
    var bitrateAutomatic = true
    /// Metal VSync: no tearing, up to a frame more delay.
    var preventTearing = false
    var scrollDirection: ScrollDirection = .system
    /// Connect to the last PC used once it is found after launch.
    var connectAtLaunch = false
    /// Asked of PCs that offer them (TXT `enc`); others ignore them.
    var encoderQuality: EncoderQuality = .fastest
    var fullColor = false
    var tenBit = false

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
    private static let latencyDetailedKey = "latencyDetailed"
    private static let showSessionReportKey = "showSessionReport"
    private static let bitrateKey = "videoBitrateMbps"
    private static let bitrateAutomaticKey = "bitrateAutomatic"
    private static let preventTearingKey = "preventTearing"
    private static let scrollDirectionKey = "scrollDirection"
    private static let connectAtLaunchKey = "connectAtLaunch"
    private static let encoderQualityKey = "encoderQuality"
    private static let fullColorKey = "fullColor"
    private static let tenBitKey = "tenBit"

    static func load(from d: UserDefaults = .standard) -> SessionPrefs {
        var p = SessionPrefs()
        if let raw = d.string(forKey: modifiersKey), let m = ModifierMapping(rawValue: raw) { p.modifiers = m }
        if d.object(forKey: forwardInputKey) != nil { p.forwardInput = d.bool(forKey: forwardInputKey) }
        if d.bool(forKey: showLatencyKey) { p.hudMode = d.bool(forKey: latencyDetailedKey) ? .detailed : .compact }
        if d.object(forKey: showSessionReportKey) != nil { p.showSessionReport = d.bool(forKey: showSessionReportKey) }
        if d.object(forKey: bitrateKey) != nil {
            p.bitrateMbps = VideoBitrate.clamp(d.integer(forKey: bitrateKey))
        }
        if d.object(forKey: bitrateAutomaticKey) != nil {
            p.bitrateAutomatic = d.bool(forKey: bitrateAutomaticKey)
        } else {
            // Before Automatic every save wrote the bitrate, so only a value
            // other than the old fixed default was a choice worth keeping.
            p.bitrateAutomatic = p.bitrateMbps == VideoBitrate.defaultValue
        }
        if d.object(forKey: preventTearingKey) != nil { p.preventTearing = d.bool(forKey: preventTearingKey) }
        if let raw = d.string(forKey: scrollDirectionKey), let s = ScrollDirection(rawValue: raw) { p.scrollDirection = s }
        if d.object(forKey: connectAtLaunchKey) != nil { p.connectAtLaunch = d.bool(forKey: connectAtLaunchKey) }
        if let q = EncoderQuality(rawValue: d.integer(forKey: encoderQualityKey)) { p.encoderQuality = q }
        p.fullColor = d.bool(forKey: fullColorKey)
        p.tenBit = d.bool(forKey: tenBitKey)
        return p
    }

    func save(to d: UserDefaults = .standard) {
        d.set(modifiers.rawValue, forKey: Self.modifiersKey)
        d.set(forwardInput, forKey: Self.forwardInputKey)
        d.set(hudMode != .off, forKey: Self.showLatencyKey)
        d.set(hudMode == .detailed, forKey: Self.latencyDetailedKey)
        d.set(showSessionReport, forKey: Self.showSessionReportKey)
        d.set(VideoBitrate.clamp(bitrateMbps), forKey: Self.bitrateKey)
        d.set(bitrateAutomatic, forKey: Self.bitrateAutomaticKey)
        d.set(preventTearing, forKey: Self.preventTearingKey)
        d.set(scrollDirection.rawValue, forKey: Self.scrollDirectionKey)
        d.set(connectAtLaunch, forKey: Self.connectAtLaunchKey)
        d.set(encoderQuality.rawValue, forKey: Self.encoderQualityKey)
        d.set(fullColor, forKey: Self.fullColorKey)
        d.set(tenBit, forKey: Self.tenBitKey)
    }

    /// Command-line flags override the remembered values for this launch.
    func overridden(by o: LaunchOptions) -> SessionPrefs {
        var p = self
        if o.modifiersGiven { p.modifiers = o.modifiers }
        if o.noInput { p.forwardInput = false }
        if o.showLatency, p.hudMode == .off { p.hudMode = .compact }
        if o.bitrateGiven { p.bitrateMbps = o.bitrateMbps; p.bitrateAutomatic = false }
        if o.metalVSync { p.preventTearing = true }
        return p
    }
}
