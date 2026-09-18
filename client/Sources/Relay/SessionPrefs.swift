// User-facing session options that used to be launch flags only. Remembered
// in UserDefaults; a flag given on the command line wins for that launch.

import Foundation

struct SessionPrefs: Equatable {
    var modifiers: ModifierMapping = .mac
    var forwardInput = true
    var showLatency = false
    var bitrateMbps = VideoBitrate.defaultValue

    private static let modifiersKey = "modifierMapping"
    private static let forwardInputKey = "forwardInput"
    private static let showLatencyKey = "showLatency"
    private static let bitrateKey = "videoBitrateMbps"

    static func load(from d: UserDefaults = .standard) -> SessionPrefs {
        var p = SessionPrefs()
        if let raw = d.string(forKey: modifiersKey), let m = ModifierMapping(rawValue: raw) { p.modifiers = m }
        if d.object(forKey: forwardInputKey) != nil { p.forwardInput = d.bool(forKey: forwardInputKey) }
        if d.object(forKey: showLatencyKey) != nil { p.showLatency = d.bool(forKey: showLatencyKey) }
        if d.object(forKey: bitrateKey) != nil {
            p.bitrateMbps = VideoBitrate.clamp(d.integer(forKey: bitrateKey))
        }
        return p
    }

    func save(to d: UserDefaults = .standard) {
        d.set(modifiers.rawValue, forKey: Self.modifiersKey)
        d.set(forwardInput, forKey: Self.forwardInputKey)
        d.set(showLatency, forKey: Self.showLatencyKey)
        d.set(VideoBitrate.clamp(bitrateMbps), forKey: Self.bitrateKey)
    }

    /// Command-line flags override the remembered values for this launch.
    func overridden(by o: LaunchOptions) -> SessionPrefs {
        var p = self
        if o.modifiersGiven { p.modifiers = o.modifiers }
        if o.noInput { p.forwardInput = false }
        if o.showLatency { p.showLatency = true }
        if o.bitrateGiven { p.bitrateMbps = o.bitrateMbps }
        return p
    }
}
