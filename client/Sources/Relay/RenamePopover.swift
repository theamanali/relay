// The rename popover: a nickname for a paired PC, anchored to the row's
// pencil. A popover rather than an in-place editor so the table can keep
// animating rows in and out while it is open, and so clearing a nickname is
// a button rather than "delete the text and press Return".

import AppKit

final class RenamePopover: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    /// Windows' own limit on a computer name (NetBIOS); a nickname stands in
    /// for one, so it gets the same room and the row never has to truncate.
    static let maxLength = 15

    private let hostName: String
    private let field = NSTextField(string: "")
    private let onSave: (String) -> Void
    private let onClose: () -> Void
    private var popover: NSPopover?

    /// Show over `anchor`. `onSave` gets the trimmed nickname, empty for "use
    /// the PC's own name"; closing the popover any other way changes nothing.
    /// `onClose` runs whichever way it went.
    @discardableResult
    static func show(from anchor: NSView, hostName: String, nickname: String?,
                     onSave: @escaping (String) -> Void, onClose: @escaping () -> Void = {}) -> NSPopover {
        let vc = RenamePopover(hostName: hostName, nickname: nickname, onSave: onSave, onClose: onClose)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.popover = popover
        popover.delegate = vc
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        return popover
    }

    private init(hostName: String, nickname: String?, onSave: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.hostName = hostName
        self.onSave = onSave
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        field.stringValue = nickname ?? ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Nickname")
        title.font = Style.Font.section
        title.textColor = .secondaryLabelColor

        // The PC's own name is what an empty field means, so it is the placeholder.
        field.placeholderString = hostName
        field.font = Style.Font.body
        field.formatter = LengthFormatter(limit: Self.maxLength)
        field.delegate = self
        // Return is handled in `control(_:textView:doCommandBy:)`, not through
        // the field's action: NSTextField also sends its action when editing
        // ends for any reason, and losing focus must not count as Save.

        // Same buttons as the footer's Connect and Advanced: regular, rounded.
        let clear = NSButton(title: "Use PC's name", target: self, action: #selector(clearNickname))
        clear.bezelStyle = .rounded
        clear.isEnabled = !field.stringValue.isEmpty
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [clear, spacer, save])
        buttons.orientation = .horizontal
        buttons.spacing = Style.Space.s

        let stack = NSStackView(views: [title, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.Space.s
        stack.setCustomSpacing(Style.Space.xs, after: title)
        stack.edgeInsets = NSEdgeInsets(top: Style.Space.l, left: Style.Space.l, bottom: Style.Space.l, right: Style.Space.l)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // An explicit width, like the Advanced popover: NSPopover sizes its
            // window from the view's frame, and left to a fitting size the
            // stack's insets get squeezed out.
            view.widthAnchor.constraint(equalToConstant: Self.fieldWidth + 2 * Style.Space.l),
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        clearButton = clear
    }

    private var clearButton: NSButton?

    /// Room for `maxLength` of the widest glyph plus the field's own inset.
    private static var fieldWidth: CGFloat {
        let widest = String(repeating: "W", count: maxLength) as NSString
        return ceil(widest.size(withAttributes: [.font: Style.Font.body]).width) + Style.Space.m
    }

    /// Start with the text selected. The popover usually makes the field
    /// first responder by itself when its window becomes key; asking again
    /// would end that editing session first (and end-of-editing is not Save).
    func popoverDidShow(_ notification: Notification) {
        if field.currentEditor() == nil {
            view.window?.makeFirstResponder(field)
        }
        field.currentEditor()?.selectAll(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }

    func controlTextDidChange(_ obj: Notification) {
        clearButton?.isEnabled = !field.stringValue.isEmpty
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            save()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.close()
            return true
        default:
            return false
        }
    }

    @objc private func save() {
        finish(with: field.stringValue)
    }

    @objc private func clearNickname() {
        finish(with: "")
    }

    private func finish(with name: String) {
        popover?.close()
        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Refuses the character that would exceed `limit`; a longer paste is cut.
private final class LengthFormatter: Formatter {
    let limit: Int

    init(limit: Int) {
        self.limit = limit
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                       proposedSelectedRange: NSRangePointer?,
                                       originalString: String, originalSelectedRange: NSRange,
                                       errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let proposed = partialStringPtr.pointee as String
        guard proposed.count > limit else { return true }
        let cut = String(proposed.prefix(limit))
        partialStringPtr.pointee = cut as NSString
        proposedSelectedRange?.pointee = NSRange(location: (cut as NSString).length, length: 0)
        return false
    }
}
