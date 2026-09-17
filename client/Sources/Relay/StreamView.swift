// Full-screen view that shows the video layer and turns trackpad/keyboard
// events into protocol messages.

import AppKit
import Foundation
import QuartzCore

protocol StreamViewDelegate: AnyObject {
    func streamView(_ v: StreamView, send data: Data)
    func streamViewRequestedExit(_ v: StreamView)
}

final class StreamView: NSView {
    weak var delegate: StreamViewDelegate?
    var keyMap = KeyMap()
    var forwardInput = true

    /// Aspect ratio of the incoming stream; used to map pointer positions onto
    /// the letterboxed video rectangle.
    var streamSize = CGSize.zero {
        didSet { needsLayout = true }
    }

    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<UInt8>()
    private var wheelRemainderX = 0.0
    private var wheelRemainderY = 0.0
    private var trackingArea: NSTrackingArea?
    private let statusLabel = NSTextField(labelWithString: "")
    private let latencyLabel = NSTextField(labelWithString: "")

    var status: String = "" {
        didSet {
            statusLabel.stringValue = status
            statusLabel.isHidden = status.isEmpty
        }
    }

    var latencyVisible = false {
        didSet { latencyLabel.isHidden = !latencyVisible }
    }

    var latencyText: String = "" {
        didSet { latencyLabel.stringValue = latencyText }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 18, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        latencyLabel.textColor = .white
        latencyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        latencyLabel.maximumNumberOfLines = 0
        latencyLabel.lineBreakMode = .byClipping
        latencyLabel.drawsBackground = true
        latencyLabel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        latencyLabel.translatesAutoresizingMaskIntoConstraints = false
        latencyLabel.isHidden = true
        addSubview(latencyLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            latencyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            latencyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(videoLayer: CALayer) {
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.insertSublayer(videoLayer, at: 0)
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.first?.frame = bounds
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metal = layer?.sublayers?.first as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    // MARK: focus & tracking

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// Release every key we told the host is down (connection dropped, app
    /// resigned, etc.) so nothing stays stuck on the Windows side.
    func releaseAllInput() {
        for usage in heldKeys {
            delegate?.streamView(self, send: Proto.key(hidUsage: usage, down: false))
        }
        heldKeys.removeAll()
        for button in heldButtons {
            delegate?.streamView(self, send: Proto.mouseButton(button, down: false))
        }
        heldButtons.removeAll()
    }

    // MARK: mouse

    /// Map a point in this view to 0...1 across the displayed video rectangle.
    private func normalized(_ p: NSPoint) -> (Double, Double)? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var rect = bounds
        if streamSize.width > 0, streamSize.height > 0 {
            let scale = min(bounds.width / streamSize.width, bounds.height / streamSize.height)
            let size = CGSize(width: streamSize.width * scale, height: streamSize.height * scale)
            rect = CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
        let x = (p.x - rect.minX) / rect.width
        // AppKit's origin is bottom-left; the stream's is top-left.
        let y = 1 - (p.y - rect.minY) / rect.height
        return (Double(x), Double(y))
    }

    private func sendMove(_ event: NSEvent) {
        guard forwardInput, let (x, y) = normalized(convert(event.locationInWindow, from: nil)) else { return }
        delegate?.streamView(self, send: Proto.mouseMove(x: x, y: y))
    }

    private func sendButton(_ event: NSEvent, down: Bool) {
        guard forwardInput else { return }
        sendMove(event)
        // NSEvent: 0 left, 1 right, 2 middle, 3/4 extra. Same order as the protocol.
        let button = UInt8(clamping: event.buttonNumber)
        guard button <= 4 else { return }
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        delegate?.streamView(self, send: Proto.mouseButton(button, down: down))
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }
    override func mouseDown(with event: NSEvent) { sendButton(event, down: true) }
    override func mouseUp(with event: NSEvent) { sendButton(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { sendButton(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { sendButton(event, down: false) }

    override func scrollWheel(with event: NSEvent) {
        guard forwardInput else { return }
        // Windows: 120 units per notch, ~3 lines or ~48 px of content.
        let perPixel = 2.5
        let perLine = 40.0
        let factor = event.hasPreciseScrollingDeltas ? perPixel : perLine
        wheelRemainderX += Double(event.scrollingDeltaX) * factor
        wheelRemainderY += Double(event.scrollingDeltaY) * factor
        let dx = wheelRemainderX.rounded(.towardZero)
        let dy = wheelRemainderY.rounded(.towardZero)
        wheelRemainderX -= dx
        wheelRemainderY -= dy
        guard dx != 0 || dy != 0 else { return }
        delegate?.streamView(
            self,
            send: Proto.mouseWheel(dx: Int16(clamping: Int(dx)), dy: Int16(clamping: Int(dy)))
        )
    }

    // MARK: keyboard

    private static let exitHotkeyKeyCode: UInt16 = 12 // Q
    private static let latencyHotkeyKeyCode: UInt16 = 37 // L
    private static let exitHotkeyFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    static func isExitHotkey(_ event: NSEvent) -> Bool {
        event.keyCode == StreamView.exitHotkeyKeyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isSuperset(of: StreamView.exitHotkeyFlags)
    }

    static func isLatencyHotkey(_ event: NSEvent) -> Bool {
        event.keyCode == latencyHotkeyKeyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isSuperset(of: exitHotkeyFlags)
    }

    private func sendKey(code: UInt16, down: Bool) {
        guard forwardInput, let usage = keyMap.hidUsage(forKeyCode: code) else { return }
        if down { heldKeys.insert(usage) } else { heldKeys.remove(usage) }
        delegate?.streamView(self, send: Proto.key(hidUsage: usage, down: down))
    }

    override func keyDown(with event: NSEvent) {
        if Self.isExitHotkey(event) {
            releaseAllInput()
            delegate?.streamViewRequestedExit(self)
            return
        }
        // Auto-repeat is handled by Windows itself once the key is down.
        guard !event.isARepeat else { return }
        sendKey(code: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(code: event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        guard KeyMap.modifierKeyCodes.contains(code), let usage = keyMap.hidUsage(forKeyCode: code) else { return }
        if code == 57 {
            // macOS reports Caps Lock as a toggle; Windows toggles on key-down, so send a full tap.
            sendKey(code: code, down: true)
            sendKey(code: code, down: false)
            return
        }
        // flagsChanged fires once per physical modifier press or release; toggle
        // against our own record so left/right pairs are tracked independently.
        let down = !heldKeys.contains(usage)
        sendKey(code: code, down: down)
    }

    /// Swallow ⌘-shortcuts so AppKit's menu handling doesn't eat them; they were
    /// already forwarded by keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
