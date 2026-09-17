// Table cells for the host picker: a section header and a host row with a
// PC glyph, name, link and pairing state.

import AppKit

final class SectionHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section-header")

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
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

    private let pcIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton()
    private let forgetButton = NSButton()
    /// Row actions, set by the controller on each configure.
    var onRename: (() -> Void)?
    var onForget: (() -> Void)?
    /// In-place rename finished: the new text (empty = use the PC's own name), or nil if cancelled.
    var onRenameEnded: ((String?) -> Void)?
    private var hostName = ""
    private var displayedName = ""
    private(set) var isEditingName = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        pcIcon.image = Glyphs.tower(pointSize: 22)
        pcIcon.setAccessibilityElement(false)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .left
        nameLabel.delegate = self
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.focusRingType = .default
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.alignment = .left
        // Name over detail, both spanning the column so truncation and the
        // in-place editor use the full width.
        let text = NSView()
        for label in [nameLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addSubview(label)
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: text.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: text.bottomAnchor),
        ])

        Self.style(renameButton, symbol: "pencil", label: "Rename", action: #selector(renameTapped))
        Self.style(forgetButton, symbol: "xmark.circle", label: "Forget", action: #selector(forgetTapped))
        renameButton.target = self
        forgetButton.target = self
        let actions = NSStackView(views: [renameButton, forgetButton])
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.setHuggingPriority(.required, for: .horizontal)

        for v in [pcIcon, text, actions] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            pcIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pcIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pcIcon.widthAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: pcIcon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -10),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static func style(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func renameTapped() { onRename?() }
    @objc private func forgetTapped() { onForget?() }

    // MARK: in-place rename

    /// Turn the name into an editor, Finder-style: white field, text selected.
    func beginEditingName() {
        guard !isEditingName, let window else { return }
        isEditingName = true
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = .textBackgroundColor
        nameLabel.textColor = .labelColor
        nameLabel.placeholderString = hostName
        // Editing the nickname, not the PC's own name: start from an empty
        // field when no nickname is set so the placeholder shows the default.
        if displayedName == hostName { nameLabel.stringValue = "" }
        window.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }

    /// Finish a pending edit as if Return were pressed (e.g. Connect was clicked).
    func commitEditingName() { endEditingName(commit: true) }

    private func endEditingName(commit: Bool) {
        guard isEditingName else { return }
        isEditingName = false
        let typed = nameLabel.stringValue
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.drawsBackground = false
        nameLabel.placeholderString = nil
        nameLabel.stringValue = displayedName
        window?.makeFirstResponder(superview) // back to the table
        onRenameEnded?(commit ? typed : nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endEditingName(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditingName(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Return commits the name only; it must not also press Connect.
            endEditingName(commit: true)
            return true
        }
        return false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(host: DiscoveredHost, state: HostPairState, nickname: String?) {
        hostName = host.name
        displayedName = nickname ?? host.name
        nameLabel.stringValue = displayedName
        let linkOnly = host.preferredLink
        // A renamed host keeps its real name in the detail line.
        let link = nickname != nil && !host.name.isEmpty ? host.name + " · " + linkOnly : linkOnly

        // The section header carries the pairing state; the row only says
        // what differs per host.
        detailLabel.stringValue = link
        pcIcon.contentTintColor = state == .paired ? .labelColor : .secondaryLabelColor
        renameButton.isHidden = host.publicKey == nil
        forgetButton.isHidden = state != .paired

        // Tooltip: facts about the device only.
        var facts: [String] = []
        if nickname != nil { facts.append(host.name) }
        facts.append("Reachable over " + host.allLinks)
        if let key = host.publicKey { facts.append("Key fingerprint \(fingerprint(key))") }
        facts.append(state == .paired ? "Paired with this MacBook" : "Not paired yet")
        toolTip = facts.joined(separator: "\n")
    }
}
