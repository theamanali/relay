// Wires discovery, connection, decoding and input into one full-screen window.

import AppKit
import CoreMedia
import Network

/// Borderless windows must opt in to keyboard focus; ordering one in front
/// alone does not make AppKit deliver keyboard events to its content view.
final class StreamWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct LaunchOptions {
    var fixedHost: NWEndpoint? = nil
    var maxFPS = 120
    var scale = 1.0
    /// Whether --max-fps / --scale were given; they override the remembered mode.
    var maxFPSGiven = false
    var scaleGiven = false
    var modifiers: ModifierMapping = .mac
    var noInput = false
    var pin: String? = nil
    var showLatency = false
    var renderer = "metal"
    var metalVSync = false

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
                if let v = it.next(), let n = Int(v) { o.maxFPS = n; o.maxFPSGiven = true }
            case "--scale":
                if let v = it.next(), let s = Double(v) { o.scale = s; o.scaleGiven = true }
            case "--modifiers":
                if let v = it.next(), let m = ModifierMapping(rawValue: v) { o.modifiers = m }
            case "--no-input":
                o.noInput = true
            case "--pin":
                if let v = it.next() { o.pin = v }
            case "--latency-stats":
                o.showLatency = true
            case "--renderer":
                guard let value = it.next(), ["metal", "avsbdl"].contains(value) else {
                    print("--renderer requires metal or avsbdl")
                    exit(2)
                }
                o.renderer = value
            case "--metal-vsync":
                o.metalVSync = true
            case "--help", "-h":
                print("""
                Relay client
                  --host <addr[:port]>       connect directly instead of browsing Bonjour
                  --max-fps <n>              cap the requested refresh rate (default 120)
                  --scale <f>                request f x native pixel size (0.75 or 0.5 keep the aspect)
                                             (the picker offers both and remembers the last choice;
                                             these flags override it for this launch)
                  --modifiers mac|physical   mac: ⌘→Ctrl ⌥→Alt ⌃→Win (default); physical: by position
                  --no-input                 view only
                  --pin <digits>             pairing PIN shown by the host (asked for interactively otherwise)
                  --latency-stats            show live latency telemetry (toggle with ⌃⌥⌘L)
                  --renderer metal|avsbdl    presentation backend (default metal)
                  --metal-vsync              enable Metal VSync (default off; avoids tearing)
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

final class AppDelegate: NSObject, NSApplicationDelegate, HostConnectionDelegate, StreamViewDelegate, NSWindowDelegate, HostPickerDelegate {
    private let options: LaunchOptions
    private var window: NSWindow!
    private var view: StreamView!
    private let renderer: VideoRenderer
    private var connection: HostConnection?
    private let browser = HostBrowser()
    private var picker: HostPickerWindowController?
    /// The host of the current or last session, for reselecting it in the picker.
    private var currentHost: DiscoveredHost?
    private var kioskActive = false
    private var screenObserver: Any?
    private var cursorHidden = false
    private var exitMonitor: Any?
    private let latencyStats = LatencyStats()
    private var latencyTimer: Timer?
    /// In-flight "forget this host" request from the picker.
    private var unpairTask: UnpairTask?

    init(options: LaunchOptions) {
        self.options = options
        renderer = VideoRenderer(renderer: options.renderer, metalVSync: options.metalVSync)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        view = StreamView(frame: screen.frame)
        view.delegate = self
        view.keyMap = KeyMap(modifiers: options.modifiers)
        view.forwardInput = !options.noInput
        view.attach(videoLayer: renderer.layer)
        view.latencyVisible = options.showLatency
        // Decoded frames land on VideoToolbox threads; hop to main for the view.
        renderer.firstFrameHandler = { [weak self] in
            DispatchQueue.main.async { self?.view.status = "" }
        }
        renderer.frameSizeHandler = { [weak self] size in
            DispatchQueue.main.async { self?.view.streamSize = size }
        }
        renderer.frameDecodedHandler = { [weak self] sequence, milliseconds in
            self?.latencyStats.recordFrame(
                sequence: sequence,
                decodeMilliseconds: milliseconds
            )
        }

        window = StreamWindow(
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
        // Keep the escape hatch independent of which view (or PIN field) has
        // focus. All other key events follow AppKit's normal responder chain.
        exitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if StreamView.isLatencyHotkey(event) {
                self.view.latencyVisible.toggle()
                self.refreshLatencyOverlay()
                return nil
            }
            guard StreamView.isExitHotkey(event) else { return event }
            self.requestExit()
            return nil
        }
        latencyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLatencyOverlay()
        }

        if let fixed = options.fixedHost {
            // --host: no picker, dial directly and keep re-dialing on drops.
            let mode = initialMode(for: screen)
            enterKiosk(on: screen, mode: mode)
            startSession(.init(endpoint: fixed, reconnects: true), screen: screen, mode: mode)
        } else {
            showPicker()
            browser.onChange = { [weak self] hosts in self?.picker?.update(hosts: hosts) }
            browser.onStatus = { [weak self] s in self?.picker?.status = s }
            browser.start()
        }
    }

    // MARK: stream mode

    private static func nativePixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width * screen.backingScaleFactor,
               height: screen.frame.height * screen.backingScaleFactor)
    }

    private static func maxRefresh(of screen: NSScreen) -> Int {
        screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60
    }

    /// Command-line flags win, then the remembered choice, then native at the
    /// panel's highest rate. Always clamped to what this screen can do.
    private func initialMode(for screen: NSScreen) -> StreamMode {
        let max = Self.maxRefresh(of: screen)
        var mode = StreamMode.load() ?? StreamMode(scale: 1.0, refresh: max)
        if options.scaleGiven { mode.scale = options.scale }
        if options.maxFPSGiven { mode.refresh = min(options.maxFPS, max) }
        return mode.clamped(toMaxRefresh: max)
    }

    private func configurePicker(for screen: NSScreen, initial: StreamMode? = nil) {
        picker?.configure(nativePixelSize: Self.nativePixelSize(of: screen),
                          maxRefresh: Self.maxRefresh(of: screen), initial: initial)
    }

    // MARK: picker <-> kiosk

    private func showPicker() {
        if picker == nil {
            let p = HostPickerWindowController()
            p.pickerDelegate = self
            p.window?.delegate = self
            picker = p
            let screen = p.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
            configurePicker(for: screen, initial: initialMode(for: screen))
            p.onModeChange = { mode in mode.save() }
            // Display plugged/unplugged or the window dragged to another
            // screen: offer that screen's sizes and rates.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.pickerScreenChanged() }
        }
        picker?.showWindow(nil)
        picker?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickerScreenChanged() {
        guard let p = picker, !kioskActive else { return }
        configurePicker(for: p.window?.screen ?? NSScreen.main ?? NSScreen.screens[0])
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if (notification.object as? NSWindow) === picker?.window { pickerScreenChanged() }
    }

    func picker(_ p: HostPickerWindowController, didChoose host: DiscoveredHost) {
        currentHost = host
        let screen = p.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let mode = p.mode
        mode.save()
        p.window?.orderOut(nil)
        enterKiosk(on: screen, mode: mode)
        var connectionOptions = HostConnection.Options(
            endpoint: host.endpoint,
            interface: host.wiredInterface,
            serviceName: host.name
        )
        let known = ClientState.knownHosts()
        connectionOptions.expectedHostKey = PairingClassifier.expectedKey(for: host, known: known)
        startSession(connectionOptions, screen: screen, mode: mode)
    }

    func picker(_ p: HostPickerWindowController, forget host: DiscoveredHost) {
        guard unpairTask == nil, let window = p.window else { return }
        guard let key = PairingClassifier.expectedKey(for: host, known: ClientState.knownHosts()) else {
            p.status = "“\(host.name)” is not paired with this Mac"
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget “\(host.name)”?"
        alert.informativeText = "This Mac and the PC will both forget each other. To connect again you'll enter the PIN shown on the PC."
        alert.addButton(withTitle: "Forget").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.forget(host: host, key: key, picker: p)
        }
    }

    /// Tell the host to drop us, then drop it locally whatever the host said:
    /// the user asked for the pairing to go, and a PC that is off right now
    /// can be cleaned up with `relay-host paired --forget`.
    private func forget(host: DiscoveredHost, key: Data, picker p: HostPickerWindowController) {
        var opts = HostConnection.Options(
            endpoint: host.endpoint,
            interface: host.wiredInterface,
            serviceName: host.name
        )
        opts.expectedHostKey = key
        let task: UnpairTask
        do {
            task = try UnpairTask(options: opts)
        } catch {
            p.status = "Cannot read this Mac's identity key: \(error.localizedDescription)"
            return
        }
        unpairTask = task
        p.status = "Forgetting “\(host.name)”…"
        let myFingerprint = (try? ClientState.identity()).map { fingerprint($0.publicKey.rawRepresentation) } ?? "?"
        task.run(timeout: 6) { [weak self] confirmed in
            ClientState.forget(host: key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.unpairTask = nil
                p.reloadPairing()
                p.status = confirmed
                    ? "Forgot “\(host.name)” on this Mac and the PC"
                    : "Forgot “\(host.name)” here; the PC didn't answer — on it run: relay-host paired --forget \(myFingerprint)"
            }
        }
    }

    private func enterKiosk(on screen: NSScreen, mode: StreamMode) {
        kioskActive = true
        window.setFrame(screen.frame, display: false)
        view.status = "Starting \(mode.label(native: Self.nativePixelSize(of: screen)))…"
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        setCursorHidden(true)
    }

    /// Back to the host list (picker mode only): the stream window goes
    /// away, the menu bar and cursor come back, and the same host is selected
    /// so Return reconnects.
    private func leaveKiosk(reason: String) {
        kioskActive = false
        connection?.stop()
        connection = nil
        renderer.reset()
        view.releaseAllInput()
        view.streamSize = .zero
        window.orderOut(nil)
        NSApp.presentationOptions = []
        setCursorHidden(false)
        showPicker()
        pickerScreenChanged()
        picker?.status = reason
        if let h = currentHost { picker?.preselect(key: h.publicKey, name: h.name) }
    }

    private func startSession(_ base: HostConnection.Options, screen: NSScreen, mode: StreamMode) {
        var opts = base
        let (w, h) = StreamMode.size(native: Self.nativePixelSize(of: screen), scale: mode.scale)
        opts.requestedWidth = w
        opts.requestedHeight = h
        opts.requestedRefresh = min(mode.refresh, Self.maxRefresh(of: screen))
        opts.wantsInput = !options.noInput
        opts.clientName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        opts.pin = options.pin
        let c: HostConnection
        do {
            c = try HostConnection(options: opts)
        } catch {
            view.status = "Cannot create this Mac's identity key: \(error.localizedDescription)"
            return
        }
        c.delegate = self
        connection = c
        c.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let exitMonitor {
            NSEvent.removeMonitor(exitMonitor)
            self.exitMonitor = nil
        }
        latencyTimer?.invalidate()
        latencyTimer = nil
        view.releaseAllInput()
        connection?.stop()
        setCursorHidden(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: window focus -> cursor / stuck keys

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window.makeFirstResponder(view)
        setCursorHidden(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        setCursorHidden(false)
        view.releaseAllInput()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === picker?.window { NSApp.terminate(nil) }
        return true
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    // MARK: HostConnectionDelegate (called on the connection queue)

    func connection(_ c: HostConnection, didChangeStatus status: String) {
        DispatchQueue.main.async {
            guard self.connection === c else { return }
            self.view.status = status
        }
    }

    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard self.connection === c else {
                completion(nil)
                return
            }
            // runModal() pins the alert to the modal-panel level, which is below
            // our kiosk window, so step out of kiosk mode while it is up.
            let kioskLevel = self.window.level
            self.window.level = .normal
            NSApp.presentationOptions = []
            self.setCursorHidden(false)

            let alert = NSAlert()
            alert.messageText = "Pair with \(host)"
            alert.informativeText = "Enter the pairing PIN shown by Relay on the PC (host fingerprint \(fingerprint)). You only need to do this once per PC."
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            field.placeholderString = "6-digit PIN"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()

            self.window.level = kioskLevel
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.view)
            self.setCursorHidden(true)
            guard response == .alertFirstButtonReturn else {
                // Cancel means "let me out": the connection ends with
                // "pairing cancelled", which returns to the picker, or quits
                // in --host mode where there is no list to go back to.
                completion(nil)
                if self.options.fixedHost != nil { NSApp.terminate(nil) }
                return
            }
            completion(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {
        guard connection === c else { return }
        latencyStats.reset()
        renderer.streamDidStart(stream)
        DispatchQueue.main.async {
            guard self.connection === c else { return }
            self.view.streamSize = self.renderer.streamSize
            self.view.status = "Streaming \(stream.width)×\(stream.height) @ \(stream.fps) fps…"
        }
    }

    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {
        guard connection === c else { return }
        renderer.setParameterSets(parameterSets)
    }

    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime) {
        guard connection === c else { return }
        renderer.enqueue(
            frame: nalUnits,
            keyframe: keyframe,
            sequence: sequence,
            receivedAt: receivedAt
        )
    }

    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming) {
        guard connection === c else { return }
        latencyStats.record(timing)
    }

    func connectionDidEnd(_ c: HostConnection, reason: String) {
        DispatchQueue.main.async {
            guard self.connection === c else { return }
            self.renderer.reset()
            self.view.releaseAllInput()
            self.view.status = "Disconnected: \(reason)"
            if self.options.fixedHost == nil, self.kioskActive {
                self.leaveKiosk(reason: "Disconnected: \(reason)")
            }
        }
    }

    // MARK: StreamViewDelegate

    func streamView(_ v: StreamView, send data: Data) {
        connection?.send(data)
    }

    func streamViewRequestedExit(_ v: StreamView) {
        requestExit()
    }

    /// ⌃⌥⌘Q: leave the stream and return to the picker. Quits only where
    /// there is no picker to go back to (--host mode, or already in the picker).
    private func requestExit() {
        view.releaseAllInput()
        if NSApp.modalWindow != nil {
            // The pairing callback treats this as Cancel; the connection then
            // ends and the usual disconnect path runs.
            NSApp.abortModal()
        } else if kioskActive, options.fixedHost == nil {
            leaveKiosk(reason: "")
        } else {
            NSApp.terminate(nil)
        }
    }

    private func refreshLatencyOverlay() {
        renderer.loadPerformanceSnapshot { [weak self] performance in
            guard let self else { return }
            self.latencyStats.recordVideoPerformance(performance)
            let text = self.latencyStats.snapshot().overlayText
            DispatchQueue.main.async {
                if self.view.latencyVisible {
                    self.view.latencyText = text
                }
            }
        }
    }
}
