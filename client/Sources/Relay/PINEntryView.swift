// The pairing PIN field, in the shape of Apple's verification-code entry:
// one box per digit in two groups of three (the PC shows the PIN as
// "123 456"), typing fills the next box, Delete empties the previous one, a
// paste fills as many as it can, and the sixth digit submits on its own.

import AppKit

final class PINEntryView: NSView {
    static let length = 6

    /// Every change, with the digits typed so far.
    var onChange: ((String) -> Void)?
    /// The last box just got its digit.
    var onComplete: ((String) -> Void)?

    private(set) var code = "" {
        didSet {
            needsDisplay = true
            onChange?(code)
            if code.count == Self.length { onComplete?(code) }
        }
    }

    private let box = NSSize(width: 34, height: 42)
    private let gap: CGFloat = Style.Space.xs + 2
    private let groupGap: CGFloat = Style.Space.l
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular)

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(Self.length)
        return NSSize(width: n * box.width + (n - 2) * gap + groupGap, height: box.height)
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: input

    override func keyDown(with event: NSEvent) {
        // ⌘V here: there is no Edit menu to route it through.
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v" { paste(nil) } else { super.keyDown(with: event) }
            return
        }
        // Return and Escape belong to the sheet's buttons, Tab to the window.
        switch event.keyCode {
        case 36, 76, 53, 48: super.keyDown(with: event)
        default: interpretKeyEvents([event])
        }
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        insert(text)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !code.isEmpty else { return NSSound.beep() }
        code.removeLast()
    }

    override func doCommand(by selector: Selector) {
        // Delete is the one command that means something here; arrows and the
        // rest are ignored quietly rather than passed up to beep.
        if selector == #selector(deleteBackward(_:)) { deleteBackward(nil) }
    }

    @objc func paste(_ sender: Any?) {
        insert(NSPasteboard.general.string(forType: .string) ?? "")
    }

    private func insert(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return NSSound.beep() }
        let room = Self.length - code.count
        guard room > 0 else { return NSSound.beep() }
        code += digits.prefix(room)
    }

    // MARK: drawing

    private func frame(ofBox i: Int) -> NSRect {
        var x = CGFloat(i) * (box.width + gap)
        if i >= Self.length / 2 { x += groupGap - gap }
        return NSRect(x: x, y: 0, width: box.width, height: box.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        let digits = Array(code)
        let active = min(code.count, Self.length - 1)
        for i in 0..<Self.length {
            let rect = frame(ofBox: i)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            if focused && i == active {
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 2
            } else {
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
            }
            path.stroke()
            if i < digits.count {
                let s = String(digits[i]) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                let size = s.size(withAttributes: attributes)
                s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}
