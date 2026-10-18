// Turns HostConnection's internal reasons and statuses into the sentences the
// picker footer shows. The connection's own strings stay as they are (they
// are what --host mode and the logs print); this is the user-facing layer.

import AppKit

enum SessionText {
    static let localNetworkHelp = "macOS blocked Relay’s local network access. Enable Relay in System Settings → Privacy & Security → Local Network. If it is already enabled, quit and reopen Relay."

    static func hostSideForgetHelp(detail: String?, fingerprint: String) -> String {
        let explanation = detail.map { $0 + "\n\n" } ?? ""
        return explanation + "Your MacBook has forgotten this PC. The PC may still remember your MacBook because Relay did not receive confirmation. To remove the pairing there, use the PC’s tray menu or run:\n\nrelay-host paired --forget \(fingerprint)"
    }
    /// The footer's room for its one line, in points of `Style.Font.caption`:
    /// the window, less its margins, the gap and the Connect button (a 74 pt
    /// label in a push button's bezel), with a little to spare. Every message
    /// below is written to fit whole; `fit` only clips text that comes from
    /// outside (an unrecognised reason, a PC's name).
    static let footerWidth: CGFloat = Style.windowWidth - 2 * Style.Space.margin - Style.Space.m - 99 - 4
    /// Room a PC's name may take inside a footer sentence.
    static let nameWidth: CGFloat = 105

    /// Measured in the footer's font (`Style.Font.caption`, 11 pt system).
    static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
    }

    /// Clip to `maxWidth` with an ellipsis.
    static func fit(_ text: String, width maxWidth: CGFloat = footerWidth) -> String {
        guard width(text) > maxWidth else { return text }
        var kept = text
        while !kept.isEmpty {
            kept.removeLast()
            let candidate = kept.trimmingCharacters(in: .whitespaces) + "…"
            if width(candidate) <= maxWidth { return candidate }
        }
        return "…"
    }

    /// A PC name short enough to sit inside a sentence.
    static func shortName(_ name: String) -> String {
        fit(name, width: nameWidth)
    }

    /// "Starting 3024×1964 @ 120 fps, 4:4:4, 10-bit, Balanced…": as many
    /// of the picture settings as fit, from the right, so the line is never clipped.
    static func starting(width w: Int, height h: Int, fps: Int, settings: [String]) -> String {
        var shown = settings
        while true {
            let text = "Starting \(w)×\(h) @ \(fps) fps" + shown.map { ", " + $0 }.joined() + "…"
            if shown.isEmpty || width(text) <= footerWidth { return text }
            shown.removeLast()
        }
    }

    /// The footer line after a session or attempt ends. `streamed` says
    /// whether a picture was ever shown, which decides "couldn't connect"
    /// against "disconnected". The picker clips longer actionable messages
    /// to `footerWidth` while preserving the full text in its tooltip.
    static func ended(_ reason: String, streamed: Bool, bitrateMbps: Int? = nil) -> String {
        let r = reason.lowercased()
        func has(_ needle: String) -> Bool { r.contains(needle) }

        if has("local network access") { return "Local network access blocked — reopen Relay" }
        if has("too many wrong pins") { return "Too many wrong PINs — try again later" }
        if has("rejected the pin") { return "Wrong PIN — try again" }
        if has("pairing cancelled") { return "Pairing cancelled" }
        if has("another session") || has("reason 6") { return "The PC is in another session" }
        if has("couldn't sustain") || has("reason 7") {
            if let bitrateMbps {
                return "Couldn't sustain \(bitrateMbps) Mbps — lower the bitrate"
            }
            return "Couldn't sustain the bitrate — lower it"
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
        if has("didn't start the stream") { return "The PC didn't start the stream — try again" }
        if has("sent no picture") { return "The PC sent no picture — wake it and try again" }
        if has("no output") || has("waiting") || has("didn't answer") { return "The PC didn't answer" }
        if has("connection failed") || has("couldn't reach") || has("read error") || has("send failed") {
            if streamed, let bitrateMbps {
                return "Lost connection at \(bitrateMbps) Mbps — lower bitrate"
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
