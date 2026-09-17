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

        fingerprintLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fingerprintLabel.textColor = .secondaryLabelColor
        fingerprintLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Explicit constraints rather than a horizontal stack: the text must
        // absorb all slack so the fingerprint sits at the trailing edge.
        for v in [pcIcon, text, fingerprintLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            pcIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pcIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pcIcon.widthAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: pcIcon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: fingerprintLabel.leadingAnchor, constant: -10),
            fingerprintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            fingerprintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(host: DiscoveredHost, state: HostPairState, nickname: String?) {
        nameLabel.stringValue = nickname ?? host.name
        var link = host.linkDescription
        if link.hasPrefix("via ") { link.removeFirst(4) }
        // A renamed host keeps its real name in the detail line.
        if nickname != nil, !host.name.isEmpty { link = host.name + " · " + link }

        if let key = host.publicKey {
            let fp = fingerprint(key)
            fingerprintLabel.stringValue = fp
            fingerprintLabel.isHidden = false
            fingerprintLabel.setAccessibilityLabel("Fingerprint \(fp)")
        } else {
            fingerprintLabel.stringValue = ""
            fingerprintLabel.isHidden = true
        }

        // The section header carries the pairing state; the row only says
        // what differs per host.
        switch state {
        case .paired:
            detailLabel.stringValue = link
            pcIcon.contentTintColor = .labelColor
            toolTip = "Right-click to rename or forget this PC."
        case .unpaired:
            detailLabel.stringValue = link
            pcIcon.contentTintColor = .secondaryLabelColor
            toolTip = "Pair with the PIN shown in the Relay window on this PC."
        }
    }
}
