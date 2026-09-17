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

final class HostRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("host-row")

    private let pcIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton()
    private let forgetButton = NSButton()
    /// Row actions, set by the controller on each configure.
    var onRename: (() -> Void)?
    var onForget: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        pcIcon.image = NSImage(systemSymbolName: "pc", accessibilityDescription: nil)
        pcIcon.symbolConfiguration = .init(pointSize: 24, weight: .regular)
        pcIcon.setAccessibilityElement(false)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        Self.style(renameButton, symbol: "pencil", label: "Rename", action: #selector(renameTapped))
        Self.style(forgetButton, symbol: "xmark.circle", label: "Forget", action: #selector(forgetTapped))
        renameButton.target = self
        forgetButton.target = self
        let actions = NSStackView(views: [renameButton, forgetButton])
        actions.orientation = .horizontal
        actions.spacing = 2

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
            text.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(host: DiscoveredHost, state: HostPairState, nickname: String?) {
        nameLabel.stringValue = nickname ?? host.name
        var linkOnly = host.linkDescription
        if linkOnly.hasPrefix("via ") { linkOnly.removeFirst(4) }
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
        facts.append("Reachable over " + linkOnly)
        if let key = host.publicKey { facts.append("Key fingerprint \(fingerprint(key))") }
        facts.append(state == .paired ? "Paired with this Mac" : "Not paired yet")
        toolTip = facts.joined(separator: "\n")
    }
}
