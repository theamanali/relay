// Table cells for the host picker: a section header and a host row with a
// PC glyph, name, link and pairing state.

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

final class HostRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("host-row")

    private let pcIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton()
    private let forgetButton = NSButton()
    private let actions = NSStackView()
    /// Row actions, set by the controller on each configure.
    var onRename: (() -> Void)?
    var onForget: (() -> Void)?
    /// Where the rename popover attaches.
    var renameAnchor: NSView { renameButton }
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
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: text.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: Style.Space.tight),
            detailLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: text.bottomAnchor),
        ])

        Self.style(renameButton, symbol: "pencil", label: "Rename", action: #selector(renameTapped))
        Self.style(forgetButton, symbol: "xmark.circle", label: "Forget", action: #selector(forgetTapped))
        renameButton.target = self
        forgetButton.target = self
        actions.addArrangedSubview(renameButton)
        actions.addArrangedSubview(forgetButton)
        actions.orientation = .horizontal
        actions.spacing = Style.Space.tight
        actions.setHuggingPriority(.required, for: .horizontal)

        for v in [pcIcon, text, actions] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            pcIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            pcIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pcIcon.widthAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: pcIcon.trailingAnchor, constant: Style.Space.s),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -Style.Space.s),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
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

    // MARK: hover card

    /// The card is about the PC, so it belongs to the glyph and text, not to
    /// the buttons on the right: those have tooltips of their own.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        var rect = bounds
        rect.size.width = max(0, actions.frame.minX - Style.Space.xs)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
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

    @objc private func renameTapped() { onRename?() }
    @objc private func forgetTapped() { onForget?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(host: DiscoveredHost, state: HostPairState, nickname: String?) {
        nameLabel.stringValue = nickname ?? host.name
        // A renamed host's real name lives in the hover card, not the row.
        let link = host.connectLink

        // The section header carries the pairing state; the row only says
        // what differs per host.
        detailLabel.stringValue = link == "This MacBook" ? link : "via \(link)"
        pcIcon.contentTintColor = state == .paired ? .labelColor : .secondaryLabelColor
        renameButton.isHidden = host.publicKey == nil
        forgetButton.isHidden = state != .paired

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
