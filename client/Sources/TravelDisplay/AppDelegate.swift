// Wires discovery, connection, decoding and input into one full-screen window.

import AppKit
import Network

struct LaunchOptions {
    var fixedHost: NWEndpoint? = nil
    var maxFPS = 120
    var scale = 1.0
    var modifiers: ModifierMapping = .mac
    var noInput = false
    var pin: String? = nil

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--host":
                // host:port or [v6]:port; skips Bonjour.
                if let v = it.next() {
                    let (host, port) = splitHostPort(v)
                    o.fixedHost = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .init(rawValue: Proto.defaultPort)!)
                }
            case "--max-fps":
                if let v = it.next(), let n = Int(v) { o.maxFPS = n }
            case "--scale":
                if let v = it.next(), let s = Double(v) { o.scale = s }
            case "--modifiers":
                if let v = it.next(), let m = ModifierMapping(rawValue: v) { o.modifiers = m }
            case "--no-input":
                o.noInput = true
            case "--pin":
                if let v = it.next() { o.pin = v }
            case "--help", "-h":
                print("""
                TravelDisplay client
                  --host <addr[:port]>       connect directly instead of browsing Bonjour
                  --max-fps <n>              cap the requested refresh rate (default 120)
                  --scale <f>                request f x native pixel size (0.75 or 0.5 keep the aspect)
                  --modifiers mac|physical   mac: ⌘→Ctrl ⌥→Alt ⌃→Win (default); physical: by position
                  --no-input                 view only
                  --pin <digits>             pairing PIN shown by the host (asked for interactively otherwise)
                Exit with ⌃⌥⌘Q.
                """)
                exit(0)
            default:
                break
            }
        }
        return o
    }

    private static func splitHostPort(_ s: String) -> (String, UInt16) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? Proto.defaultPort : Proto.defaultPort
            return (host, port)
        }
        let parts = s.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) {
            return (String(parts[0]), port)
        }
        return (s, Proto.defaultPort)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, HostConnectionDelegate, StreamViewDelegate, NSWindowDelegate {
    private let options: LaunchOptions
    private var window: NSWindow!
    private var view: StreamView!
    private let renderer = VideoRenderer()
    private var connection: HostConnection?
    private var cursorHidden = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pixelSize = CGSize(
            width: screen.frame.width * screen.backingScaleFactor * options.scale,
            height: screen.frame.height * screen.backingScaleFactor * options.scale
        )
        let refresh = min(options.maxFPS, screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60)

        view = StreamView(frame: screen.frame)
        view.delegate = self
        view.keyMap = KeyMap(modifiers: options.modifiers)
        view.forwardInput = !options.noInput
        view.attach(videoLayer: renderer.layer)
        view.status = "Starting…"

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) // covers the menu bar: kiosk while streaming
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        setCursorHidden(true)

        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let c: HostConnection
        do {
            c = try HostConnection(options: .init(
                fixedHost: options.fixedHost,
                requestedWidth: Int(pixelSize.width.rounded()),
                requestedHeight: Int(pixelSize.height.rounded()),
                requestedRefresh: refresh,
                wantsInput: !options.noInput,
                clientName: name,
                pin: options.pin
            ))
        } catch {
            view.status = "Cannot create this Mac's identity key: \(error.localizedDescription)"
            return
        }
        c.delegate = self
        connection = c
        c.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        view.releaseAllKeys()
        connection?.stop()
        setCursorHidden(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: window focus -> cursor / stuck keys

    func windowDidBecomeKey(_ notification: Notification) {
        setCursorHidden(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        setCursorHidden(false)
        view.releaseAllKeys()
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    // MARK: HostConnectionDelegate (called on the connection queue)

    func connection(_ c: HostConnection, didChangeStatus status: String) {
        DispatchQueue.main.async { self.view.status = status }
    }

    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Pair with \(host)"
            alert.informativeText = "Enter the pairing PIN shown by TravelDisplay on the PC (host fingerprint \(fingerprint)). You only need to do this once per PC."
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            field.placeholderString = "6-digit PIN"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            // Our kiosk window sits above the menu bar; the alert must sit above it.
            alert.window.level = NSWindow.Level(rawValue: self.window.level.rawValue + 1)
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil)
        }
    }

    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {
        renderer.streamDidStart(stream)
        DispatchQueue.main.async {
            self.view.streamSize = self.renderer.streamSize
            self.view.status = "Streaming \(stream.width)×\(stream.height) @ \(stream.fps) fps…"
        }
    }

    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {
        renderer.setParameterSets(parameterSets)
    }

    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool) {
        let first = renderer.framesDisplayed == 0
        renderer.enqueue(frame: nalUnits, keyframe: keyframe)
        if first, renderer.framesDisplayed > 0 {
            DispatchQueue.main.async { self.view.status = "" }
        }
    }

    func connectionDidEnd(_ c: HostConnection, reason: String) {
        renderer.reset()
        DispatchQueue.main.async {
            self.view.releaseAllKeys()
            self.view.status = "Disconnected: \(reason)"
        }
    }

    // MARK: StreamViewDelegate

    func streamView(_ v: StreamView, send data: Data) {
        connection?.send(data)
    }

    func streamViewRequestedExit(_ v: StreamView) {
        NSApp.terminate(nil)
    }
}
