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

/// Settings subtitles that describe the current choice, so each row says
/// what it does now rather than what it can do.
enum SettingDetail {
    static func extraFrames(_ on: Bool, requestedRefresh: Int) -> String {
        on ? "Requests \(requestedRefresh) fps on the next connection." : "Uses the selected refresh rate."
    }
    static func automaticBitrate(_ on: Bool) -> String {
        on ? "Set for the resolution, refresh rate and connection." : "Uses the bitrate you choose below."
    }
    static func automaticScaling(_ on: Bool) -> String {
        on ? "Sizes the PC's desktop to match this Mac's screen." : "Uses the scale you choose below."
    }
    static func fullColor(_ on: Bool) -> String {
        on ? "Colored text stays sharp, but needs more bitrate." : "Colored text may look slightly soft."
    }
    static func tenBit(_ on: Bool) -> String {
        on ? "Smoother gradients with less banding." : "Gradients may show slight banding."
    }
    static func vsync(_ on: Bool) -> String {
        on ? "No tearing, but up to a frame of extra delay." : "Lowest delay, but fast motion may tear."
    }
    static func control(_ on: Bool) -> String {
        on ? "Keys, clicks and scrolling go to the PC." : "Watching only, no input is sent to the PC."
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
    /// Request 20% more frames than the selected refresh, up to 240 fps.
    /// Applied to the Windows virtual display and encoder on next connect.
    var extraFrames = false
    /// Metal VSync: no tearing, up to a frame more delay.
    var preventTearing = false
    var scrollDirection: ScrollDirection = .system
    /// Asked of PCs that offer them (TXT `enc`); others ignore them.
    var encoderQuality: EncoderQuality = .fastest
    var fullColor = false
    var tenBit = false
    /// Windows' scale for the virtual display: matched to this Mac's screen
    /// (`DisplayScale.automatic`) until the user picks a step.
    var displayScaleAutomatic = true
    var displayScale = DisplayScale.defaultChoice

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
    private static let extraFramesKey = "extraFrames"
    private static let preventTearingKey = "preventTearing"
    private static let scrollDirectionKey = "scrollDirection"
    private static let encoderQualityKey = "encoderQuality"
    private static let fullColorKey = "fullColor"
    private static let tenBitKey = "tenBit"
    private static let displayScaleAutomaticKey = "displayScaleAutomatic"
    private static let displayScaleKey = "displayScale"

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
        p.extraFrames = d.bool(forKey: extraFramesKey)
        if let raw = d.string(forKey: scrollDirectionKey), let s = ScrollDirection(rawValue: raw) { p.scrollDirection = s }
        if let q = EncoderQuality(rawValue: d.integer(forKey: encoderQualityKey)) { p.encoderQuality = q }
        p.fullColor = d.bool(forKey: fullColorKey)
        p.tenBit = d.bool(forKey: tenBitKey)
        if d.object(forKey: displayScaleAutomaticKey) != nil {
            p.displayScaleAutomatic = d.bool(forKey: displayScaleAutomaticKey)
        }
        if d.object(forKey: displayScaleKey) != nil {
            p.displayScale = DisplayScale.nearestStep(d.integer(forKey: displayScaleKey))
        }
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
        d.set(extraFrames, forKey: Self.extraFramesKey)
        d.set(preventTearing, forKey: Self.preventTearingKey)
        d.set(scrollDirection.rawValue, forKey: Self.scrollDirectionKey)
        d.set(encoderQuality.rawValue, forKey: Self.encoderQualityKey)
        d.set(fullColor, forKey: Self.fullColorKey)
        d.set(tenBit, forKey: Self.tenBitKey)
        d.set(displayScaleAutomatic, forKey: Self.displayScaleAutomaticKey)
        d.set(displayScale, forKey: Self.displayScaleKey)
    }

    /// What CLIENT_HELLO's `display_scale` asks for, streaming `pixelWidth`
    /// to a screen `pointWidth` points wide.
    func requestedDisplayScale(pixelWidth: Int, pointWidth: Double) -> Int {
        displayScaleAutomatic ? DisplayScale.automatic(pixelWidth: pixelWidth, pointWidth: pointWidth) : displayScale
    }

    /// Existing CLIENT_HELLO refresh field; host preflight checks the actual
    /// requested mode. An explicit --max-fps remains a cap with extra frames.
    func requestedRefresh(displayRefresh: Int, maxFPS: Int = 240) -> Int {
        let cap = min(240, max(1, maxFPS))
        let base = min(cap, max(1, displayRefresh))
        return extraFrames ? min(cap, (base * 6 + 4) / 5) : base
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
