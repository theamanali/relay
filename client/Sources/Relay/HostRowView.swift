// Table cells for the host picker: a section header and a host row with a
// PC glyph, name, link and pairing state. Rename and Forget live in the
// row's context menu (and Delete forgets), not in buttons on the row.

import AppKit

final class SectionHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section-header")

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.font = Style.Font.section
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Style.Space.xs),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(section: PickerSection) {
        label.stringValue = section.title
    }
}

final class HostRowView: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("host-row")

    /// Windows' own limit on a computer name (NetBIOS); a nickname stands in
    /// for one, so it gets the same room and the row never has to truncate.
    static let maxNameLength = 15

    private let pcIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// Rename in progress: the name is a live text field until it ends.
    private(set) var isRenaming = false
    private var nameBeforeRename = ""
    private var renameCancelled = false
    /// The name fills the column so it can truncate; while it is being
    /// edited it is sized to its text and grows with the typing, as Finder's
    /// box does. Sized by measuring: an NSTextField that truncates or scrolls
    /// reports no intrinsic width, so hugging has nothing to hold on to.
    private var nameFillsColumn: NSLayoutConstraint!
    private var nameHugsText: [NSLayoutConstraint] = []
    private var nameWidth: NSLayoutConstraint!
    /// The rename ended: the new name, or nil when it was cancelled or left
    /// unchanged. Set by the controller before `beginRename`.
    var onRenameEnd: ((String?) -> Void)?
    private var hoverRows: [(label: String, value: String)] = []
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        pcIcon.image = Glyphs.tower(pointSize: 22)
        pcIcon.setAccessibilityElement(false)

        nameLabel.font = Style.Font.body
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .left
        nameLabel.focusRingType = .none
        nameLabel.formatter = LengthFormatter(limit: Self.maxNameLength)
        nameLabel.delegate = self
        detailLabel.font = Style.Font.caption
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.alignment = .left
        // Name over detail, both spanning the column so truncation uses the full width.
        let text = NSView()
        for label in [nameLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addSubview(label)
        }
        nameFillsColumn = nameLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor)
        nameWidth = nameLabel.widthAnchor.constraint(equalToConstant: 0)
        nameWidth.priority = .defaultHigh // the column edge wins for a name that would not fit
        nameHugsText = [nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: text.trailingAnchor), nameWidth]
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: text.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            nameFillsColumn,
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: Style.Space.tight),
            detailLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: text.bottomAnchor),
        ])

        for v in [pcIcon, text] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            pcIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            pcIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pcIcon.widthAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: pcIcon.trailingAnchor, constant: Style.Space.s),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: rename

    /// Finder-style: the name becomes a text field with its text selected,
    /// so the first keystroke replaces it. Return commits, Escape puts the
    /// old name back, and editing ending any other way (a click elsewhere,
    /// the row being reloaded) commits too, as Finder does.
    func beginRename() {
        guard !isRenaming, let window else { return }
        isRenaming = true
        renameCancelled = false
        nameBeforeRename = nameLabel.stringValue
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBezeled = true
        nameLabel.bezelStyle = .squareBezel
        nameLabel.focusRingType = .default
        nameLabel.lineBreakMode = .byClipping
        nameFillsColumn.isActive = false
        fitNameBox()
        NSLayoutConstraint.activate(nameHugsText)
        window.makeFirstResponder(nameLabel)
        if let editor = nameLabel.currentEditor() as? NSTextView {
            // The field editor keeps drawing the row's emphasised (white)
            // text over the edit box otherwise.
            editor.textColor = .textColor
            editor.insertionPointColor = .textColor
            editor.selectAll(nil)
        }
    }

    /// Commit the edit in progress (the controller calls this before it
    /// reloads the row from under the field editor).
    func endRename() {
        guard isRenaming, let window, window.firstResponder === nameLabel.currentEditor() else { return }
        window.makeFirstResponder(nil)
    }

    private func finishRename() {
        guard isRenaming else { return }
        isRenaming = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false // bezeling turned it on and does not turn it off
        nameLabel.focusRingType = .none
        nameLabel.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.deactivate(nameHugsText)
        nameFillsColumn.isActive = true
        let typed = nameLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = !renameCancelled && typed != nameBeforeRename
        // An emptied name means "use the PC's own"; the reload fills it in.
        nameLabel.stringValue = changed && !typed.isEmpty ? typed : nameBeforeRename
        onRenameEnd?(changed ? typed : nil)
    }

    /// Text plus the bezel's own insets, and room for the caret; an emptied
    /// box keeps enough width to be seen.
    private func fitNameBox() {
        let text = (nameLabel.stringValue as NSString).size(withAttributes: [.font: nameLabel.font ?? Style.Font.body]).width
        nameWidth.constant = max(48, ceil(text) + 12)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameLabel else { return }
        fitNameBox()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === nameLabel else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            renameCancelled = true
            nameLabel.abortEditing()
            finishRename()
            return true
        default:
            return false
        }
    }

    /// NSTextField ends editing for any reason (focus moving away included),
    /// and Finder treats every one of those as a commit; only Escape is not.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameLabel else { return }
        finishRename()
    }

    // MARK: hover card

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        HoverCard.shared.schedule(rows: hoverRows, for: self, alignedTo: nameLabel)
    }

    override func mouseExited(with event: NSEvent) {
        HoverCard.shared.hide()
    }

    override func mouseDown(with event: NSEvent) {
        HoverCard.shared.hide()
        super.mouseDown(with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(host: DiscoveredHost, state: HostPairState, nickname: String?) {
        // A reload mid-rename (the controller commits first, but a reused
        // view can still be reconfigured) must not overwrite the typing.
        if !isRenaming { nameLabel.stringValue = nickname ?? host.name }
        // A renamed host's real name lives in the hover card, not the row.
        let link = host.connectLink

        // The section header carries the pairing state; the row only says
        // what differs per host.
        detailLabel.stringValue = link == "This MacBook" ? link : "via \(link)"
        pcIcon.contentTintColor = state == .paired ? .labelColor : .secondaryLabelColor

        // Hover card: facts about the PC only — what it advertises, then how we see it.
        var rows: [(label: String, value: String)] = []
        if nickname != nil { rows.append(("Name:", host.name)) }
        rows += host.facts.rows
        // One line per way the PC can be reached from here; the row's
        // subtitle already says which of these the connection takes.
        let reachable = host.reachableAddresses
        for entry in reachable {
            // The link only needs naming when there is more than one to tell apart.
            rows.append(("Host IP:", reachable.count > 1 ? "\(entry.address) (\(entry.link))" : entry.address))
        }
        if let key = host.publicKey { rows.append(("Key:", fingerprint(key))) }
        hoverRows = rows
        toolTip = nil
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
