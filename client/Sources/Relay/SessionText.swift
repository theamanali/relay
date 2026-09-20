// Turns HostConnection's internal reasons and statuses into the sentences the
// picker footer shows. The connection's own strings stay as they are (they
// are what --host mode and the logs print); this is the user-facing layer.

import Foundation

enum SessionText {
    /// The footer is one line; anything longer than this is clipped there.
    static let footerLimit = 45
    /// Room a PC's name may take inside a footer sentence.
    static let nameLimit = 16

    /// Clip to `limit` characters with an ellipsis.
    static func fit(_ text: String, limit: Int = footerLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A PC name short enough to sit inside a sentence.
    static func shortName(_ name: String) -> String {
        fit(name, limit: nameLimit)
    }

    /// The footer line after a session or attempt ends. `streamed` says
    /// whether a picture was ever shown, which decides "couldn't connect"
    /// against "disconnected". The picker clips longer actionable messages
    /// to `footerLimit` while preserving the full text in its tooltip.
    static func ended(_ reason: String, streamed: Bool, bitrateMbps: Int? = nil) -> String {
        let r = reason.lowercased()
        func has(_ needle: String) -> Bool { r.contains(needle) }

        if has("too many wrong pins") { return "Too many wrong PINs — try again later" }
        if has("rejected the pin") { return "Wrong PIN — try again" }
        if has("pairing cancelled") { return "Pairing cancelled" }
        if has("another session") || has("reason 6") { return "The PC is in another session" }
        if has("couldn't sustain") || has("reason 7") {
            if let bitrateMbps {
                return "Connection couldn't sustain \(bitrateMbps) Mbps — choose a lower bitrate."
            }
            return "Connection couldn't sustain the selected bitrate — choose a lower bitrate."
        }
        if has("host identity changed") { return "PC identity changed — forget it, pair again" }
        if has("forgot this macbook") { return "PC forgot this MacBook" }
        if has("does not know this macbook") || has("reason 4") { return "PC doesn't know this MacBook — pair again" }
        if has("speaks protocol") || has("reason 3") { return "The PC runs a different Relay version" }
        if has("reason 1") { return "The PC's video encoder failed" }
        if has("reason 2") { return "The PC lost its display" }
        if has("reason 0") || has("host closed the connection") || has("connection closed") {
            return streamed ? "The PC ended the session" : "The PC closed the connection"
        }
        if has("no output") || has("waiting") || has("didn't answer") { return "The PC didn't answer" }
        if has("connection failed") || has("couldn't reach") || has("read error") || has("send failed") {
            if streamed, let bitrateMbps {
                return "Lost connection at \(bitrateMbps) Mbps — try a lower bitrate."
            }
            return streamed ? "Lost the connection to the PC" : "Couldn't reach the PC"
        }
        if has("handshake failed") || has("secure channel") || has("encryption failed") {
            return "Couldn't secure the connection to the PC"
        }
        if has("protocol error") || has("malformed") { return "The PC sent something unexpected" }
        return fit((streamed ? "Disconnected: " : "Couldn't connect: ") + reason)
    }

    /// The pairing lock-out as a wait a person would plan around: whole
    /// minutes, rounded up, never "0 min".
    static func retryWait(seconds: Int) -> String {
        "\(max(1, (seconds + 59) / 60)) min"
    }

    /// Whether a connection status deserves to replace the footer's
    /// "Connecting to…" line. Most handshake steps flash by in milliseconds
    /// and read like a debugger; only a stall is worth telling the user about.
    static func footerStatus(_ status: String, hostName: String) -> String? {
        if status.hasPrefix("Waiting for host") { return "Waiting for \(shortName(hostName))…" }
        return nil
    }
}
