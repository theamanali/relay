// Turns HostConnection's internal reasons and statuses into the sentences the
// picker footer shows. The connection's own strings stay as they are (they
// are what --host mode and the logs print); this is the user-facing layer.

import Foundation

enum SessionText {
    /// The footer line after a session or attempt ends. `streamed` says
    /// whether a picture was ever shown, which decides "couldn't connect"
    /// against "disconnected".
    static func ended(_ reason: String, streamed: Bool) -> String {
        let r = reason.lowercased()
        func has(_ needle: String) -> Bool { r.contains(needle) }

        if has("rejected the pin") { return "Wrong PIN — try again" }
        if has("pairing cancelled") { return "Pairing cancelled" }
        if has("host identity changed") { return "This PC's identity has changed — forget it and pair again" }
        if has("does not know this macbook") || has("reason 4") { return "The PC doesn't know this MacBook — pair again" }
        if has("speaks protocol") || has("reason 3") { return "The PC runs a different version of Relay" }
        if has("reason 1") { return "The PC's video encoder failed" }
        if has("reason 2") { return "The PC lost its display" }
        if has("reason 0") || has("host closed the connection") || has("connection closed") {
            return streamed ? "The PC ended the session" : "The PC closed the connection"
        }
        if has("no output") || has("waiting") { return "The PC didn't answer" }
        if has("connection failed") || has("read error") || has("send failed") {
            return streamed ? "Lost the connection to the PC" : "Couldn't reach the PC"
        }
        if has("handshake failed") || has("secure channel") || has("encryption failed") {
            return "Couldn't secure the connection to the PC"
        }
        if has("protocol error") || has("malformed") { return "The PC sent something Relay didn't understand" }
        return streamed ? "Disconnected: \(reason)" : "Couldn't connect: \(reason)"
    }

    /// Whether a connection status deserves to replace the footer's
    /// "Connecting to…" line. Most handshake steps flash by in milliseconds
    /// and read like a debugger; only a stall is worth telling the user about.
    static func footerStatus(_ status: String, hostName: String) -> String? {
        if status.hasPrefix("Waiting for host") { return "Waiting for \(hostName)…" }
        return nil
    }
}
