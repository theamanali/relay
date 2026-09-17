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
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private let stateIcon = NSImageView()

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
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        fingerprintLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fingerprintLabel.textColor = .secondaryLabelColor
        fingerprintLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        fingerprintLabel.setContentHuggingPriority(.required, for: .horizontal)

        stateIcon.symbolConfiguration = .init(pointSize: 14, weight: .medium)

        let row = NSStackView(views: [pcIcon, text, fingerprintLabel, stateIcon])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            pcIcon.widthAnchor.constraint(equalToConstant: 32),
            stateIcon.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(host: DiscoveredHost, state: HostPairState) {
        nameLabel.stringValue = host.name
        var link = host.linkDescription
        if link.hasPrefix("via ") { link.removeFirst(4) }

        if let key = host.publicKey {
            let fp = fingerprint(key)
            fingerprintLabel.stringValue = fp
            fingerprintLabel.isHidden = false
            fingerprintLabel.setAccessibilityLabel("Fingerprint \(fp)")
        } else {
            fingerprintLabel.isHidden = true
        }

        let symbol: String
        let tint: NSColor
        let label: String
        var tip: String?
        switch state {
        case .paired:
            detailLabel.stringValue = link
            symbol = "checkmark.seal.fill"
            tint = .controlAccentColor
            label = "Paired"
        case .pairedByName:
            detailLabel.stringValue = link + " · Paired by name"
            symbol = "checkmark.seal"
            tint = .secondaryLabelColor
            label = "Paired by name"
            tip = "This PC didn't advertise its key, so it's matched by name. The key is verified when you connect."
        case .unpaired:
            detailLabel.stringValue = link + " · Not paired"
            symbol = "key"
            tint = .tertiaryLabelColor
            label = "Not paired"
            tip = "Pair with the PIN shown in the Relay window on this PC."
        }
        pcIcon.contentTintColor = state == .unpaired ? .secondaryLabelColor : .labelColor
        stateIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        stateIcon.contentTintColor = tint
        stateIcon.setAccessibilityLabel(label)
        toolTip = tip
    }
}
