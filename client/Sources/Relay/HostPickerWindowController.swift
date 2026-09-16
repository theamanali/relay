// The launch window: discovered hosts in two sections, paired and not.
// Return / double-click / Connect starts a session; closing the window quits.

import AppKit

protocol HostPickerDelegate: AnyObject {
    func picker(_ p: HostPickerWindowController, didChoose host: DiscoveredHost)
}

final class HostPickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var pickerDelegate: HostPickerDelegate?

    private enum Row {
        case header(String)
        case paired(PairingClassifier.Entry)
        case unpaired(DiscoveredHost)
        case empty(String)

        var host: DiscoveredHost? {
            switch self {
            case .paired(let e): return e.host
            case .unpaired(let h): return h
            default: return nil
            }
        }
    }

    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Looking for hosts…")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var nativePixelSize = CGSize(width: 2, height: 2)
    private var maxRefresh = 60
    /// Called when the user changes either popup.
    var onModeChange: ((StreamMode) -> Void)?
    private var rows: [Row] = []
    private var hosts: [DiscoveredHost] = []
    /// Name (or key) to select when the list next changes, e.g. after a disconnect.
    private var wanted: (key: Data?, name: String)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Relay"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: .init("host"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 44
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.doubleAction = #selector(connect)
        table.target = self
        table.allowsEmptySelection = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        connectButton.isEnabled = false
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        resolutionPopup.target = self
        resolutionPopup.action = #selector(modeChanged)
        refreshPopup.target = self
        refreshPopup.action = #selector(modeChanged)
        let modeRow = NSStackView(views: [
            NSTextField(labelWithString: "Resolution"), resolutionPopup,
            NSTextField(labelWithString: "Refresh"), refreshPopup,
        ])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        modeRow.setCustomSpacing(20, after: resolutionPopup)
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(modeRow)
        content.addSubview(statusLabel)
        content.addSubview(connectButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: modeRow.topAnchor, constant: -12),
            modeRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            modeRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            modeRow.bottomAnchor.constraint(equalTo: connectButton.topAnchor, constant: -14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: connectButton.leadingAnchor, constant: -12),
            connectButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            connectButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        reload()
    }

    // MARK: stream mode

    /// Rebuild the popups for a screen. Keeps the current choice when it is
    /// still offered, otherwise falls back to native / the highest rate.
    func configure(nativePixelSize: CGSize, maxRefresh: Int, initial: StreamMode? = nil) {
        let keep = (initial ?? mode).clamped(toMaxRefresh: maxRefresh)
        self.nativePixelSize = nativePixelSize
        self.maxRefresh = maxRefresh
        resolutionPopup.removeAllItems()
        for (i, entry) in StreamMode.sizes(native: nativePixelSize).enumerated() {
            let pct = entry.scale == 1 ? "native" : "\(Int(entry.scale * 100))%"
            resolutionPopup.addItem(withTitle: "\(entry.width) × \(entry.height) (\(pct))")
            resolutionPopup.lastItem?.tag = i
        }
        refreshPopup.removeAllItems()
        for hz in StreamMode.refreshRates(max: maxRefresh) {
            refreshPopup.addItem(withTitle: "\(hz) Hz")
            refreshPopup.lastItem?.tag = hz
        }
        mode = keep
    }

    var mode: StreamMode {
        get {
            let scale = StreamMode.scales[max(0, min(StreamMode.scales.count - 1, resolutionPopup.selectedTag()))]
            let refresh = refreshPopup.selectedTag() > 0 ? refreshPopup.selectedTag() : maxRefresh
            return StreamMode(scale: scale, refresh: refresh)
        }
        set {
            let m = newValue.clamped(toMaxRefresh: maxRefresh)
            resolutionPopup.selectItem(withTag: StreamMode.scales.firstIndex(of: m.scale) ?? 0)
            refreshPopup.selectItem(withTag: m.refresh)
        }
    }

    @objc private func modeChanged() {
        onModeChange?(mode)
    }

    // MARK: input from the app

    /// A message that outranks the host count (a disconnect reason, a
    /// browse error) until the list next changes.
    var status: String = "" {
        didSet { refreshStatus() }
    }

    func update(hosts: [DiscoveredHost]) {
        if hosts.map(\.name) != self.hosts.map(\.name) { status = "" }
        self.hosts = hosts
        reload()
        refreshStatus()
    }

    private func refreshStatus() {
        if !status.isEmpty {
            statusLabel.stringValue = status
        } else if hosts.isEmpty {
            statusLabel.stringValue = "Looking for hosts…"
        } else {
            statusLabel.stringValue = hosts.count == 1 ? "1 host found" : "\(hosts.count) hosts found"
        }
    }

    /// Select this host when it (re)appears; used after a session ends.
    func preselect(key: Data?, name: String) {
        wanted = (key, name)
        applyPreselection()
    }

    private func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].host : nil
        let (paired, unpaired) = PairingClassifier.classify(hosts, known: ClientState.knownHosts())
        rows = [.header("Paired")]
        rows += paired.isEmpty ? [.empty("No paired hosts in range")] : paired.map(Row.paired)
        rows.append(.header("Not paired"))
        rows += unpaired.isEmpty ? [.empty(hosts.isEmpty ? "Looking for hosts…" : "None")] : unpaired.map(Row.unpaired)
        table.reloadData()
        if let selected, let i = rows.firstIndex(where: { $0.host?.name == selected.name }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            applyPreselection()
        }
        if table.selectedRow < 0, let first = rows.firstIndex(where: { $0.host != nil }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        connectButton.isEnabled = table.selectedRow >= 0 && rows[table.selectedRow].host != nil
    }

    private func applyPreselection() {
        guard let wanted else { return }
        let i = rows.firstIndex { row in
            guard let h = row.host else { return false }
            if let key = wanted.key, let hk = h.publicKey { return key == hk }
            return h.name == wanted.name
        }
        if let i {
            table.selectRowIndexes([i], byExtendingSelection: false)
            self.wanted = nil
        }
    }

    @objc private func connect() {
        let i = table.selectedRow
        guard i >= 0, i < rows.count, let host = rows[i].host else { return }
        pickerDelegate?.picker(self, didChoose: host)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].host != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 24
        case .empty: return 28
        default: return 44
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        connectButton.isEnabled = table.selectedRow >= 0 && rows[table.selectedRow].host != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .empty(let text):
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .tertiaryLabelColor
            return label
        case .paired(let entry):
            var detail = entry.host.linkDescription
            if let key = entry.host.publicKey {
                detail += " · " + fingerprint(key)
            } else if entry.byNameOnly {
                detail += " · name match, key not advertised"
            }
            return hostCell(name: entry.host.name, detail: detail)
        case .unpaired(let host):
            var detail = host.linkDescription + " · needs the PIN shown on the PC"
            if let key = host.publicKey { detail += " · " + fingerprint(key) }
            return hostCell(name: host.name, detail: detail)
        }
    }

    private func hostCell(name: String, detail: String) -> NSView {
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return stack
    }
}
