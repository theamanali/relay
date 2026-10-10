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
    var modifiersGiven = false
    var noInput = false
    var pin: String? = nil
    var showLatency = false
    var renderer = "metal"
    var metalVSync = false
    var bitrateMbps = VideoBitrate.defaultValue
    var bitrateGiven = false

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
                if let v = it.next(), let m = ModifierMapping(rawValue: v) {
                    o.modifiers = m
                    o.modifiersGiven = true
                }
            case "--no-input":
                o.noInput = true
            case "--pin":
                if let v = it.next() { o.pin = v }
            case "--latency-stats":
                o.showLatency = true
            case "--bitrate":
                guard let value = it.next(), let bitrate = Int(value),
                      (VideoBitrate.minimum...VideoBitrate.maximum).contains(bitrate) else {
                    print("--bitrate requires a whole number from 1 through 1000 Mbps")
                    exit(2)
                }
                o.bitrateMbps = bitrate
                o.bitrateGiven = true
            case "--renderer":
                guard let value = it.next(), ["metal", "avsbdl"].contains(value) else {
                    print("--renderer requires metal or avsbdl")
                    exit(2)
                }
                o.renderer = value
            case "--metal-vsync":
                o.metalVSync = true
            case "--render-icons":
                // Host tray icons from the picker's glyph; see host/assets/README.md.
                guard let dir = it.next() else {
                    print("--render-icons requires a directory")
                    exit(2)
                }
                exit(IconExport.run(into: dir))
            case "--render-app-icon":
                // AppIcon.icon and Relay.icns for bundle.sh; see client/Assets.
                guard let dir = it.next() else {
                    print("--render-app-icon requires a directory")
                    exit(2)
                }
                exit(IconExport.renderAppIcon(into: dir))
            case "--help", "-h":
                print("""
                Relay client
                  --host <addr[:port]>       connect directly instead of browsing Bonjour
                  --max-fps <n>              cap the requested refresh rate (default 120)
                  --scale <f>                request f x native pixel size (0.75 or 0.5 keep the aspect)
                                             (the picker offers both and remembers the last choice;
                                             these flags override it for this launch)
                  --modifiers mac|physical   mac: ⌘→Ctrl ⌥→Alt ⌃→Win (default); physical: by position
                  --no-input                 view only (toggle control with ⌃⌥⌘K)
                  --pin <digits>             pairing PIN shown by the host (asked for interactively otherwise)
                  --latency-stats            show live latency telemetry (toggle with ⌃⌥⌘L)
                  --bitrate <1...1000>       request this video bitrate in Mbps (default 120)
                  --renderer metal|avsbdl    presentation backend (default metal)
                  --metal-vsync              enable Metal VSync (default off; avoids tearing)
                  --render-icons <dir>       write the host's tray icons (relay-{light,dark}.ico) and exit
                  --render-app-icon <dir>    write the Mac app icon (AppIcon.icon, Relay.icns) and exit
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
    /// Set when the host refused a PIN from the picker: the re-dial's PIN
    /// sheet opens with this line instead of the usual explanation.
    private var pinError: String?
    /// The PIN prompt in front of the user and the connection it answers.
    /// If that connection ends first (including an older host reporting BUSY
    /// before PAIR, or giving up waiting) the prompt is closed: a PIN typed
    /// into it would go nowhere.
    private var pinPrompt: (alert: NSAlert, connection: HostConnection)?
    /// The modal (--host) prompt was closed by the connection, not the user.
    private var pinPromptEndedByConnection = false
    private var kioskActive = false
    /// Held while the stream window is up: without it the Mac's display
    /// sleeps and the screen saver starts on top of the picture as soon as
    /// the user stops touching the keyboard and trackpad (view-only mode, or
    /// watching something on the PC). System sleep from the lid is unaffected.
    private var keepAwake: NSObjectProtocol?
    private var screenObserver: Any?
    private var cursorHidden = false
    private var exitMonitor: Any?
    private let latencyStats = LatencyStats()
    private var latencyTimer: Timer?
    /// In-flight "forget this host" request from the picker.
    private var unpairTask: UnpairTask?
    /// What Bonjour last showed, for the pairing check below.
    private var latestHosts: [DiscoveredHost] = []
    /// Which known host to ask whether it still knows this Mac, and the
    /// one such connection in flight. See `checkPairings`.
    private var verifier = PairingVerifier()
    private var verifyTask: VerifyTask?
    /// Session started from the picker that has not shown a frame yet: the
    /// kiosk window opens on the first decoded picture, not before.
    private var pendingSession: (screen: NSScreen, mode: StreamMode)?
    /// Remembered options, with this launch's flags applied on top.
    private var prefs = SessionPrefs()

    init(options: LaunchOptions) {
        self.options = options
        renderer = VideoRenderer(renderer: options.renderer, metalVSync: options.metalVSync)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        // A `swift run` has no bundle and so no icon: give the Dock the
        // flattened drawing. Never for Relay.app — setting this overrides
        // the tile, and the bundle's icon is what the system renders for the
        // light, dark and tinted styles.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") == nil,
           Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = IconExport.appIcon()
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        view = StreamView(frame: screen.frame)
        view.delegate = self
        prefs = SessionPrefs.load().overridden(by: options)
        applyPrefs()
        view.attach(videoLayer: renderer.layer)
        // Decoded frames land on VideoToolbox threads; hop to main for the view.
        renderer.firstFrameHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.view.status = ""
                if let pending = self.pendingSession, !self.kioskActive {
                    self.pendingSession = nil
                    self.picker?.connecting = false
                    self.picker?.status = ""
                    self.picker?.window?.orderOut(nil)
                    self.enterKiosk(on: pending.screen, mode: pending.mode)
                }
            }
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
            if StreamView.isControlHotkey(event) {
                self.toggleControl()
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
            browser.onChange = { [weak self] hosts in
                guard let self else { return }
                self.latestHosts = hosts
                self.picker?.update(hosts: hosts)
                self.checkPairings()
            }
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
            p.prefs = prefs
            p.onPrefsChange = { [weak self] prefs in
                guard let self else { return }
                self.prefs = prefs
                prefs.save()
                self.applyPrefs()
            }
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
        let shown = SessionText.shortName(host.publicKey.flatMap { ClientState.nicknames()[$0] } ?? host.name)
        var connectionOptions = HostConnection.Options(
            endpoint: host.endpoint,
            interface: host.wiredInterface,
            serviceName: host.name
        )
        connectionOptions.expectedHostKey = PairingClassifier.expectedKey(for: host, known: ClientState.knownHosts())
        p.connecting = true
        if connectionOptions.expectedHostKey == nil {
            // Available host: pair only. It moves to Paired; connecting is a
            // separate, deliberate step.
            connectionOptions.pairOnly = true
            p.status = "Pairing with \(shown)…"
        } else {
            // Stay in the list while connecting; the footer shows progress and
            // the kiosk window appears with the first frame.
            pendingSession = (screen, mode)
            p.status = "Connecting to \(shown)…"
        }
        startSession(connectionOptions, screen: screen, mode: mode)
    }

    func picker(_ p: HostPickerWindowController, forget host: DiscoveredHost) {
        guard unpairTask == nil, let window = p.window else { return }
        guard let key = PairingClassifier.expectedKey(for: host, known: ClientState.knownHosts()) else {
            p.flash("\(SessionText.shortName(host.name)) isn't paired")
            return
        }
        let shown = ClientState.nicknames()[key] ?? host.name
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to forget “\(shown)”?"
        alert.informativeText = "Your MacBook will no longer be paired with this PC. To connect again, you’ll need to enter its PIN."
        alert.addButton(withTitle: "Forget").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.forget(host: host, key: key, picker: p)
        }
    }

    private func applyPrefs() {
        view.keyMap = KeyMap(modifiers: prefs.modifiers)
        view.setForwardInput(prefs.forwardInput)
        view.latencyVisible = prefs.showLatency
        refreshLatencyOverlay()
    }

    /// ⌃⌥⌘K anywhere: the same setting as the Advanced checkbox and View ▸
    /// Control the PC, so it persists and the picker shows it; mid-session
    /// it takes effect at once and the stream says which way it went.
    private func toggleControl() {
        prefs.forwardInput.toggle()
        prefs.save()
        applyPrefs()
        picker?.prefs = prefs
        if kioskActive {
            flashStatus(prefs.forwardInput ? "Controlling \(currentHostLabel)" : "Observing \(currentHostLabel)")
        }
    }

    /// A line over the stream that clears itself, unless something else
    /// (a connection state) replaced it first.
    private func flashStatus(_ text: String) {
        view.status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.view.status == text else { return }
            self.view.status = ""
        }
    }

    /// Nickname if the user gave one, else the PC's own name, clipped to fit a sentence.
    private var currentHostLabel: String {
        guard let host = currentHost else { return "the PC" }
        return SessionText.shortName(host.publicKey.flatMap { ClientState.nicknames()[$0] } ?? host.name)
    }

    func pickerDidCancelConnect(_ p: HostPickerWindowController) {
        connection?.stop()
        connection = nil
        pendingSession = nil
        renderer.reset()
        p.connecting = false
        p.status = ""
        checkPairings()
    }

    func picker(_ p: HostPickerWindowController, rename host: DiscoveredHost, to name: String) {
        guard let key = host.publicKey else { return }
        // Typing the PC's own name back is the same as clearing the nickname.
        ClientState.setNickname(name == host.name ? nil : name, for: key)
        p.reloadPairing()
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
            p.flash("Can't read this MacBook's identity key")
            return
        }
        unpairTask = task
        let shown = SessionText.shortName(ClientState.nicknames()[key] ?? host.name)
        p.status = "Forgetting \(shown)…"
        let myFingerprint = (try? ClientState.identity()).map { fingerprint($0.publicKey.rawRepresentation) } ?? "?"
        task.run(timeout: 6) { [weak self] outcome in
            ClientState.forget(host: key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.unpairTask = nil
                p.reloadPairing()
                self.checkPairings()
                switch outcome {
                case .confirmed:
                    p.flash("Forgot \(shown)")
                case .busy:
                    p.flash("Forgot \(shown) on this MacBook only")
                    self.explainHostSideForget(host: shown, because: "is in another session", fingerprint: myFingerprint, on: p)
                case .localNetworkDenied:
                    p.flash("Forgot \(shown) on this MacBook only")
                    self.explainHostSideForget(host: shown, because: "couldn’t be asked to forget this MacBook",
                                              detail: SessionText.localNetworkHelp, fingerprint: myFingerprint, on: p)
                case .unreachable(let reason):
                    p.flash("Forgot \(shown) on this MacBook only")
                    self.explainHostSideForget(host: shown, because: "didn’t confirm forgetting this MacBook",
                                              detail: SessionText.ended(reason, streamed: false), fingerprint: myFingerprint, on: p)
                }
            }
        }
    }

    /// No success reply: the request or its reply may have been lost, so
    /// the PC's remaining pairing state is unknown.
    private func explainHostSideForget(host: String, because: String, detail: String? = nil,
                                       fingerprint: String, on p: HostPickerWindowController) {
        guard let window = p.window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(host)” \(because)."
        alert.informativeText = SessionText.hostSideForgetHelp(detail: detail, fingerprint: fingerprint)
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Ask one known host at a time whether it still has this Mac paired,
    /// when the pairing digest it advertises is not the one last verified
    /// (or none was yet, as at the first launch after an update). The PC's
    /// tray Forget is how a pairing goes away without the Mac's say; without
    /// this the row would sit under Paired until a Connect found out. Runs
    /// between sessions only: the verify never touches the display, but its
    /// answer must not race a Connect, Pair or Forget of the same host.
    private func checkPairings() {
        guard verifyTask == nil, connection == nil, unpairTask == nil, options.fixedHost == nil else { return }
        guard let (host, key, digest) = verifier.next(
            among: latestHosts, known: ClientState.knownHosts(), verified: ClientState.verifiedDigests()
        ) else { return }
        var opts = HostConnection.Options(
            endpoint: host.endpoint,
            interface: host.wiredInterface,
            serviceName: host.name
        )
        opts.expectedHostKey = key
        guard let task = try? VerifyTask(options: opts) else { return }
        verifyTask = task
        NSLog("Relay: checking the pairing with %@ (pg %@)", host.name, digest)
        task.run(timeout: 6) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.verifyTask = nil
                if self.connection != nil || self.unpairTask != nil {
                    // Something started for this host meanwhile owns the
                    // answer; ask again once it is over.
                    self.verifier.retract(key)
                } else {
                    switch outcome {
                    case .paired:
                        ClientState.setVerifiedDigest(digest, for: key)
                    case .forgotten:
                        NSLog("Relay: %@ forgot this MacBook", host.name)
                        ClientState.forget(host: key)
                        self.picker?.reloadPairing()
                        self.picker?.flash(SessionText.ended("the PC forgot this MacBook", streamed: false))
                    case .unreachable:
                        break
                    }
                }
                self.checkPairings()
            }
        }
    }

    private func enterKiosk(on screen: NSScreen, mode: StreamMode) {
        kioskActive = true
        window.setFrame(screen.frame, display: false)
        view.status = pendingSession == nil && options.fixedHost != nil
            ? "Starting \(mode.label(native: Self.nativePixelSize(of: screen)))…"
            : ""
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        setCursorHidden(true)
        if keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Showing a PC's display"
            )
        }
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
        if let token = keepAwake {
            ProcessInfo.processInfo.endActivity(token)
            keepAwake = nil
        }
        showPicker()
        pickerScreenChanged()
        picker?.reloadPairing()
        if reason.isEmpty { picker?.status = "" } else { picker?.flash(reason) }
        if let h = currentHost { picker?.preselect(key: h.publicKey, name: h.name) }
        checkPairings()
    }

    /// How long a Connect or Pair from the picker waits for the PC to take
    /// the socket at all: a pinned attempt on the cable plus its unpinned
    /// retry, each with a 5 s SYN timeout, and some room for resolution.
    static let pickerDialTimeout: TimeInterval = 12

    private func startSession(_ base: HostConnection.Options, screen: NSScreen, mode: StreamMode) {
        var opts = base
        if options.fixedHost == nil { opts.dialTimeout = Self.pickerDialTimeout }
        let (w, h) = StreamMode.size(native: Self.nativePixelSize(of: screen), scale: mode.scale)
        opts.requestedWidth = w
        opts.requestedHeight = h
        opts.requestedRefresh = min(mode.refresh, Self.maxRefresh(of: screen))
        opts.wantsInput = prefs.forwardInput
        opts.requestedBitrateMbps = prefs.bitrateMbps
        opts.clientName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        opts.pin = options.pin
        let c: HostConnection
        do {
            c = try HostConnection(options: opts)
        } catch {
            view.status = "Cannot create this MacBook's identity key: \(error.localizedDescription)"
            return
        }
        c.delegate = self
        connection = c
        c.start()
    }

    /// Relay ▸ About Relay: the standard panel (icon, name, version and build
    /// from the bundle, the copyright line) plus the repository as credits.
    /// A bundle-less `swift run` has none of the bundle parts to show.
    @objc func showAbout(_ sender: Any?) {
        let url = URL(string: "https://github.com/theamanali/relay")!
        let credits = NSAttributedString(string: "github.com/theamanali/relay", attributes: [
            .link: url,
            .font: NSFont.systemFont(ofSize: 11),
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// PC ▸ Close Window ⌘W, for whichever window is key.
    @objc func closeKeyWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    /// Help ▸ Relay Help: the README is the manual.
    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/theamanali/relay#readme")!)
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
            if self.kioskActive {
                self.view.status = status
            } else if let shown = SessionText.footerStatus(status, hostName: self.currentHostLabel) {
                self.picker?.status = shown
            }
        }
    }

    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard self.connection === c else {
                completion(nil)
                return
            }
            // Shaped like Apple's verification-code sheet: six boxes that
            // submit on the last digit; Pair only as the Return fallback.
            let alert = NSAlert()
            alert.messageText = "Enter the PIN for “\(host)”"
            alert.informativeText = self.pinError ?? "A pairing PIN is shown by Relay on the PC. Enter it to continue."
            self.pinError = nil
            let pair = alert.addButton(withTitle: "Pair")
            pair.isEnabled = false
            alert.addButton(withTitle: "Cancel")

            let field = PINEntryView()
            field.onChange = { pair.isEnabled = $0.count == PINEntryView.length }
            field.onComplete = { _ in pair.performClick(nil) }
            let check = NSTextField(labelWithString: "Fingerprint \(fingerprint)")
            check.font = Style.Font.caption
            check.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [field, check])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = Style.Space.s
            stack.edgeInsets = NSEdgeInsets(top: Style.Space.xs, left: 0, bottom: 0, right: 0)
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            alert.window.initialFirstResponder = field

            self.pinPrompt = (alert, c)
            if !self.kioskActive, let pickerWindow = self.picker?.window, pickerWindow.isVisible {
                // Connecting from the list: ask as a sheet on it.
                alert.beginSheetModal(for: pickerWindow) { response in
                    if self.pinPrompt?.alert === alert { self.pinPrompt = nil }
                    guard self.connection === c else { return completion(nil) }
                    guard response == .alertFirstButtonReturn else { return completion(nil) }
                    completion(field.code)
                }
                return
            }

            // --host mode: runModal() pins the alert to the modal-panel level,
            // which is below our kiosk window, so step out of kiosk while it is up.
            let kioskLevel = self.window.level
            self.window.level = .normal
            NSApp.presentationOptions = []
            self.setCursorHidden(false)
            NSApp.activate(ignoringOtherApps: true)
            self.pinPromptEndedByConnection = false
            let response = alert.runModal()
            let endedByConnection = self.pinPromptEndedByConnection
            if self.pinPrompt?.alert === alert { self.pinPrompt = nil }

            self.window.level = kioskLevel
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.view)
            self.setCursorHidden(true)
            guard response == .alertFirstButtonReturn else {
                // Cancel means "let me out": the connection ends with
                // "pairing cancelled", which returns to the picker, or quits
                // in --host mode where there is no list to go back to. A
                // prompt the connection closed under the user is neither;
                // --host mode re-dials and asks again.
                completion(nil)
                if self.options.fixedHost != nil, !endedByConnection { NSApp.terminate(nil) }
                return
            }
            completion(field.code)
        }
    }

    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {
        guard connection === c else { return }
        latencyStats.reset()
        renderer.streamDidStart(stream)
        DispatchQueue.main.async {
            guard self.connection === c else { return }
            if let pending = self.pendingSession, !self.kioskActive {
                self.window.setFrame(pending.screen.frame, display: false)
                self.picker?.status = "Starting \(stream.width)×\(stream.height) @ \(stream.fps) fps…"
            } else {
                self.view.status = "Streaming \(stream.width)×\(stream.height) @ \(stream.fps) fps…"
            }
            self.view.streamSize = self.renderer.streamSize
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

    /// Close the PIN prompt that belongs to `c`, whose connection is gone:
    /// the sheet's handler sees Cancel and the answer is dropped as stale.
    private func dismissPINPrompt(for c: HostConnection) {
        guard let prompt = pinPrompt, prompt.connection === c else { return }
        pinPrompt = nil
        let sheet = prompt.alert.window
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .cancel)
        } else if NSApp.modalWindow === sheet {
            pinPromptEndedByConnection = true
            NSApp.abortModal()
        }
    }

    func connectionDidEnd(_ c: HostConnection, reason: String) {
        DispatchQueue.main.async {
            guard self.connection === c else { return }
            self.dismissPINPrompt(for: c)
            self.renderer.reset()
            self.view.releaseAllInput()
            self.view.status = "Disconnected: \(reason)"
            guard self.options.fixedHost == nil else { return }
            if self.kioskActive {
                self.leaveKiosk(reason: SessionText.ended(
                    reason,
                    streamed: true,
                    bitrateMbps: c.activeBitrateMbps
                ))
            } else if let p = self.picker {
                // The attempt is over: nothing below sends on `c` again.
                self.connection = nil
                self.pendingSession = nil
                p.connecting = false
                if !c.everConnected, let host = self.currentHost {
                    // Nobody took the socket: the row may be a stale Bonjour
                    // entry for a PC that went away without a goodbye. Have
                    // mDNSResponder re-check it, so it leaves the list now
                    // rather than when its TTL runs out.
                    BonjourReconfirm.reconfirm(host)
                }
                if c.pinRejected, self.options.pin == nil, let host = self.currentHost {
                    // The host closes after a refusal, so trying again is a new
                    // connection; keep the sheet's flow, not the footer's.
                    self.pinError = c.pairRetryAfter.map {
                        "Too many wrong PINs. Try again in \(SessionText.retryWait(seconds: $0))."
                    } ?? "That PIN wasn’t correct. Check the PIN shown by Relay on the PC and try again."
                    self.picker(p, didChoose: host)
                    return
                }
                if c.pairingCompleted {
                    p.flash("Paired with \(self.currentHostLabel)")
                    if let host = self.currentHost { p.preselect(key: host.publicKey, name: host.name) }
                } else {
                    p.flash(SessionText.ended(reason, streamed: false, bitrateMbps: c.activeBitrateMbps))
                }
                // Pairing, or a host that forgot us, changes the split.
                p.reloadPairing()
                self.checkPairings()
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
