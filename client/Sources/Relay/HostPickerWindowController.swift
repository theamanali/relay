// The launch window: a compact utility panel listing discovered hosts under
// Paired / Available. Return / double-click / Connect starts a session;
// closing the window quits.

import AppKit

protocol HostPickerDelegate: AnyObject {
    func picker(_ p: HostPickerWindowController, didChoose host: DiscoveredHost)
    /// The user wants to drop the pairing with this host (context menu / Delete).
    func picker(_ p: HostPickerWindowController, forget host: DiscoveredHost)
    /// The user gave this host a nickname; empty means "use the PC's own name".
    func picker(_ p: HostPickerWindowController, rename host: DiscoveredHost, to name: String)
    /// Cancel pressed while a connection started from this picker is still in progress.
    func pickerDidCancelConnect(_ p: HostPickerWindowController)
}

/// Lets Delete / Backspace on a selected row reach the controller.
private final class PickerTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, selectedRow >= 0 { // Backspace, Forward Delete
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

final class HostPickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    weak var pickerDelegate: HostPickerDelegate?

    private let table = PickerTableView()
    private let scroll = NSScrollView()
    private let emptyState = NSStackView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let optionsButton = NSButton(title: "", target: nil, action: nil)
    private weak var bitrateSlider: NSSlider?
    private weak var bitrateField: NSTextField?
    /// The row whose name is being edited in place, if any.
    private weak var renamingRow: HostRowView?
    /// Session options shown in the gear popover; set by the app, saved by it.
    var prefs = SessionPrefs()
    var onPrefsChange: ((SessionPrefs) -> Void)?
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshSegment = NSSegmentedControl()
    private var nativePixelSize = CGSize(width: 2, height: 2)
    private var maxRefresh = 60
    /// Called when the user changes either control.
    var onModeChange: ((StreamMode) -> Void)?
    private var rows: [PickerRow] = []
    private var hosts: [DiscoveredHost] = []
    /// Name (or key) to select when the list next changes, e.g. after a disconnect.
    private var wanted: (key: Data?, name: String)?
    private var listVisible = false
    /// A session is being set up from this window: Connect reads Cancel and
    /// the footer shows the connection's progress.
    var connecting = false {
        didSet { updateConnectButton() }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Relay"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func build() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true

        // Header: hero glyph, title, one-line purpose.
        let hero = NSImageView()
        hero.image = Glyphs.towerAndMacBook(pointSize: 44)
        hero.contentTintColor = .controlAccentColor
        hero.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: "Relay")
        title.font = Style.Font.title
        let subtitle = NSTextField(labelWithString: "Use this MacBook as your PC's display.")
        subtitle.font = Style.Font.body
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [hero, title, subtitle])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = Style.Space.tight
        header.setCustomSpacing(Style.Space.s, after: hero)
        header.translatesAutoresizingMaskIntoConstraints = false

        // List.
        let column = NSTableColumn(identifier: .init("host"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Style.rowHeight
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("PCs")
        table.onDelete = { [weak self] in self?.forgetSelected() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alphaValue = 0
        scroll.isHidden = true

        // Empty state, shown until the first host appears.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let looking = NSTextField(labelWithString: "Looking for your PC…")
        looking.font = Style.Font.body
        looking.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: "Open Relay on the PC and connect it to this MacBook or the same network.")
        hint.font = Style.Font.caption
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 300
        emptyState.setViews([spinner, looking, hint], in: .center)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = Style.Space.s
        emptyState.setCustomSpacing(Style.Space.xs, after: looking)
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scroll)
        listContainer.addSubview(emptyState)

        // Footer: a separated band with the stream mode on one line and
        // gear · status · Connect on the next.
        let footer = NSVisualEffectView()
        footer.material = .headerView
        footer.blendingMode = .withinWindow
        footer.state = .active
        footer.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        resolutionPopup.target = self
        resolutionPopup.action = #selector(modeChanged)
        resolutionPopup.setAccessibilityLabel("Resolution")
        resolutionPopup.toolTip = "Resolution to stream"
        refreshSegment.target = self
        refreshSegment.action = #selector(modeChanged)
        refreshSegment.trackingMode = .selectOne
        refreshSegment.segmentStyle = .rounded
        refreshSegment.setAccessibilityLabel("Refresh rate")
        refreshSegment.toolTip = "Refresh rate"
        let modeRow = NSStackView(views: [resolutionPopup, refreshSegment, optionsButton])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = Style.Space.m
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        optionsButton.title = "Advanced"
        optionsButton.bezelStyle = .rounded
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Style.Font.caption
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // Long messages truncate (full text in the tooltip) rather than widen the window.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        connectButton.isEnabled = false
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(listContainer)
        content.addSubview(footer)
        footer.addSubview(separator)
        footer.addSubview(modeRow)
        footer.addSubview(statusLabel)
        footer.addSubview(connectButton)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: Style.titleBarClearance),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Style.Space.margin),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Style.Space.margin),

            listContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Style.Space.margin),
            listContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            listContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            listContainer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Style.Space.m),
            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: listContainer.widthAnchor, constant: -2 * Style.Space.margin),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            modeRow.topAnchor.constraint(equalTo: footer.topAnchor, constant: Style.Space.l),
            modeRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Style.Space.margin),
            optionsButton.trailingAnchor.constraint(equalTo: connectButton.trailingAnchor),

            // Gear at the end of the Stream line; the status line then reads
            // straight from the left edge.
            optionsButton.widthAnchor.constraint(equalTo: connectButton.widthAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Style.Space.margin),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: connectButton.leadingAnchor, constant: -Style.Space.m),
            statusLabel.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
            connectButton.topAnchor.constraint(equalTo: modeRow.bottomAnchor, constant: Style.Space.m),
            connectButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Style.Space.margin),
            connectButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -Style.Space.l),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        window.initialFirstResponder = table
        updateConnectButton()
        spinner.startAnimation(nil)
    }

    // MARK: stream mode

    /// Offer this screen's sizes and rates. Keeps the current choice when it
    /// is still available, otherwise the closest.
    func configure(nativePixelSize: CGSize, maxRefresh: Int, initial: StreamMode? = nil) {
        let keep = initial ?? mode
        self.nativePixelSize = nativePixelSize
        self.maxRefresh = maxRefresh

        resolutionPopup.removeAllItems()
        for (i, s) in StreamMode.sizes(native: nativePixelSize).enumerated() {
            resolutionPopup.addItem(withTitle: Self.resolutionTitle(s))
            resolutionPopup.lastItem?.tag = i
        }

        let rates = StreamMode.refreshRates(max: maxRefresh)
        refreshSegment.segmentCount = rates.count
        for (i, hz) in rates.enumerated() {
            refreshSegment.setLabel("\(hz) Hz", forSegment: i)
            refreshSegment.setTag(hz, forSegment: i)
        }
        refreshSegment.isHidden = rates.count < 2

        mode = keep.clamped(toMaxRefresh: maxRefresh)
    }

    /// "Native (3024 × 1964)", "75% (2268 × 1474)": the footer popup and the
    /// View menu say the same thing.
    private static func resolutionTitle(_ s: (scale: Double, width: Int, height: Int)) -> String {
        let name = s.scale == 1.0 ? "Native" : "\(Int(s.scale * 100))%"
        return "\(name) (\(s.width) × \(s.height))"
    }

    /// The rates this screen can show, highest first (one on a 60 Hz panel).
    var offeredRefreshRates: [Int] { StreamMode.refreshRates(max: maxRefresh) }

    var mode: StreamMode {
        get {
            let scaleIndex = resolutionPopup.selectedItem?.tag ?? 0
            let scale = StreamMode.scales.indices.contains(scaleIndex) ? StreamMode.scales[scaleIndex] : 1.0
            let seg = refreshSegment.selectedSegment
            let refresh = seg >= 0 ? refreshSegment.tag(forSegment: seg) : maxRefresh
            return StreamMode(scale: scale, refresh: refresh)
        }
        set {
            let scaleIndex = StreamMode.scales.firstIndex(of: newValue.scale) ?? 0
            resolutionPopup.selectItem(withTag: scaleIndex)
            for i in 0..<refreshSegment.segmentCount where refreshSegment.tag(forSegment: i) == newValue.refresh {
                refreshSegment.selectedSegment = i
            }
            if refreshSegment.selectedSegment < 0, refreshSegment.segmentCount > 0 {
                refreshSegment.selectedSegment = 0
            }
        }
    }

    @objc private func modeChanged() {
        onModeChange?(mode)
    }

    // MARK: hosts + status

    /// Footer text that overrides the host count until the list changes,
    /// e.g. the reason a session ended.
    var status: String = "" {
        didSet {
            flashTimer?.invalidate()
            flashTimer = nil
            refreshStatus()
        }
    }
    private var flashTimer: Timer?

    /// A result ("Paired with…", "Forgot…", why a session ended): shown for a
    /// while, then the footer returns to the host count. Anything that sets
    /// `status` in the meantime cancels the fade.
    func flash(_ message: String, for seconds: TimeInterval = 8) {
        status = message
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.status == message else { return }
            self.status = ""
        }
    }

    func update(hosts: [DiscoveredHost]) {
        if hosts.map(\.name) != self.hosts.map(\.name) { status = "" }
        self.hosts = hosts
        apply(currentRows())
        refreshStatus()
    }

    private func refreshStatus() {
        if !status.isEmpty {
            // One line, never wider than the space between ? and Connect;
            // the full text is a hover away if it had to be clipped.
            statusLabel.stringValue = SessionText.fit(status)
            statusLabel.toolTip = statusLabel.stringValue == status ? nil : status
        } else {
            statusLabel.stringValue = hosts.isEmpty ? "" : (hosts.count == 1 ? "1 PC found" : "\(hosts.count) PCs found")
            statusLabel.toolTip = nil
        }
    }

    /// Select this host when it (re)appears; used after a session ends.
    func preselect(key: Data?, name: String) {
        wanted = (key, name)
        applyPreselection()
        updateConnectButton()
    }

    private var selectedHost: DiscoveredHost? {
        let i = table.selectedRow
        return i >= 0 && i < rows.count ? rows[i].host : nil
    }

    private func apply(_ newRows: [PickerRow]) {
        let selectedName = selectedHost?.name
        let diff = PickerRows.diff(old: rows, new: newRows)
        let visible = window?.isVisible ?? false
        let wasListVisible = listVisible
        // A reload would pull the field editor out from under an in-place
        // rename; Finder commits in that case, so do the same. Rows animating
        // in and out around the edit leave it alone.
        if let editing = renamingRow {
            let index = table.row(for: editing)
            if diff.needsFullReload || !visible || !wasListVisible
                || diff.removed.contains(index) || diff.reloaded.contains(index) {
                editing.endRename()
            }
        }
        if diff.needsFullReload || !visible || !wasListVisible {
            // `reloadData` removes row views without a mouse-exited event.
            HoverCard.shared.hide()
        } else {
            // Hide a card whose host is about to animate out; cards belonging
            // to surviving rows stay visible.
            for index in diff.removed {
                if let row = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? HostRowView {
                    HoverCard.shared.hide(ifAnchoredTo: row)
                }
            }
        }
        rows = newRows
        setListVisible(!newRows.isEmpty, animated: visible)
        if diff.needsFullReload || !visible || !wasListVisible {
            table.reloadData()
        } else {
            table.beginUpdates()
            table.removeRows(at: diff.removed, withAnimation: .effectFade)
            table.insertRows(at: diff.inserted, withAnimation: .slideDown)
            table.endUpdates()
            if !diff.reloaded.isEmpty {
                table.reloadData(forRowIndexes: diff.reloaded, columnIndexes: [0])
            }
        }
        if let selectedName, let i = rows.firstIndex(where: { $0.host?.name == selectedName }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            applyPreselection()
        }
        if table.selectedRow < 0, let first = rows.firstIndex(where: { $0.host != nil }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        updateConnectButton()
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

    /// Connect for a paired host, Pair for an available one, Cancel while busy.
    private func updateConnectButton() {
        let selected = hostRow(at: table.selectedRow)
        connectButton.title = connecting ? "Cancel" : (selected?.state == .unpaired ? "Pair" : "Connect")
        connectButton.isEnabled = connecting || selected != nil
        // The mode and options describe a session, and only a paired PC can
        // start one; until then the controls have nothing to apply to.
        let paired = selected?.state == .paired
        resolutionPopup.isEnabled = paired
        refreshSegment.isEnabled = paired
        optionsButton.isEnabled = paired
    }

    /// Crossfade between the list and the "looking" placeholder.
    private func setListVisible(_ show: Bool, animated: Bool) {
        guard show != listVisible else { return }
        listVisible = show
        let incoming: NSView = show ? scroll : emptyState
        let outgoing: NSView = show ? emptyState : scroll
        if show { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        incoming.isHidden = false
        guard animated else {
            incoming.alphaValue = 1
            outgoing.alphaValue = 0
            outgoing.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.listVisible == show else { return }
            outgoing.isHidden = true
        })
    }

    @objc private func rowDoubleClicked() {
        guard !connecting else { return }
        connect()
    }

    @objc private func connect() {
        if connecting {
            pickerDelegate?.pickerDidCancelConnect(self)
            return
        }
        guard let host = selectedHost else { return }
        pickerDelegate?.picker(self, didChoose: host)
    }

    /// Re-run the paired / available split after hosts.txt or nicknames changed.
    func reloadPairing() {
        apply(currentRows())
    }

    private func currentRows() -> [PickerRow] {
        PickerRows.build(hosts: hosts, known: ClientState.knownHosts(), nicknames: ClientState.nicknames())
    }

    private func hostRow(at row: Int) -> (host: DiscoveredHost, state: HostPairState, nickname: String?)? {
        guard row >= 0, row < rows.count, case .host(let h, let state, let nickname) = rows[row] else { return nil }
        return (h, state, nickname)
    }

    private func forget(row: Int) {
        guard let r = hostRow(at: row), r.state == .paired else { return }
        pickerDelegate?.picker(self, forget: r.host)
    }

    /// The PC's own name is what "no nickname" shows, so this is a rename to it.
    private func revertName(row: Int) {
        guard let r = hostRow(at: row), r.nickname != nil else { return }
        pickerDelegate?.picker(self, rename: r.host, to: r.host.name)
    }

    private func forgetSelected() { forget(row: table.selectedRow) }
    @objc private func forgetClicked() { forget(row: table.clickedRow) }
    @objc private func renameClicked() { beginRename(row: table.clickedRow) }
    @objc private func revertNameClicked() { revertName(row: table.clickedRow) }

    // MARK: menu bar (File / View / Settings…), reached through the responder
    // chain while this window is key; validated per selection below.

    @objc func connectSelected(_ sender: Any?) { connect() }
    @objc func renameSelected(_ sender: Any?) { beginRename(row: table.selectedRow) }
    @objc func revertNameSelected(_ sender: Any?) { revertName(row: table.selectedRow) }
    @objc func forgetSelected(_ sender: Any?) { forgetSelected() }
    @objc func showSettings(_ sender: Any?) { showOptions() }

    @objc func toggleLatencyStats(_ sender: Any?) {
        prefs.showLatency.toggle()
        onPrefsChange?(prefs)
    }

    @objc func toggleControl(_ sender: Any?) {
        prefs.forwardInput.toggle()
        onPrefsChange?(prefs)
    }

    @objc func selectResolution(_ sender: NSMenuItem) {
        guard StreamMode.scales.indices.contains(sender.tag) else { return }
        var m = mode
        m.scale = StreamMode.scales[sender.tag]
        mode = m
        modeChanged()
    }

    @objc func selectBitrate(_ sender: NSMenuItem) {
        prefs.bitrateMbps = VideoBitrate.clamp(sender.tag)
        syncBitrateControls() // the Advanced popover, if it is open
        onPrefsChange?(prefs)
    }

    @objc func selectRefresh(_ sender: NSMenuItem) {
        var m = mode
        m.refresh = sender.tag
        mode = m
        modeChanged()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = hostRow(at: table.selectedRow)
        switch item.action {
        case #selector(connectSelected(_:)):
            let unpaired = selected?.state == .unpaired
            item.title = unpaired ? "Pair" : "Connect"
            item.image = NSImage(systemSymbolName: unpaired ? "link" : "display", accessibilityDescription: nil)
            return selected != nil && !connecting
        case #selector(renameSelected(_:)):
            return selected?.host.publicKey != nil && renamingRow == nil
        case #selector(revertNameSelected(_:)):
            if let r = selected, let _ = r.nickname {
                item.title = "Revert Name to “\(r.host.name)”"
                // Not mid-edit: the edit's own commit would land after the revert.
                return renamingRow == nil
            }
            item.title = "Revert Name"
            return false
        case #selector(forgetSelected(_:)):
            return selected?.state == .paired
        case #selector(showSettings(_:)):
            return selected?.state == .paired // like the footer's Advanced button
        case #selector(toggleLatencyStats(_:)):
            item.state = prefs.showLatency ? .on : .off
            return true
        case #selector(toggleControl(_:)):
            item.state = prefs.forwardInput ? .on : .off
            return true
        // The mode items mirror the footer: shown always, usable once a
        // paired PC is selected (the mode describes its session).
        case #selector(selectResolution(_:)):
            let sizes = StreamMode.sizes(native: nativePixelSize)
            guard sizes.indices.contains(item.tag) else { return false }
            item.title = Self.resolutionTitle(sizes[item.tag])
            item.state = mode.scale == sizes[item.tag].scale ? .on : .off
            return selected?.state == .paired
        case #selector(selectRefresh(_:)):
            item.state = mode.refresh == item.tag ? .on : .off
            return selected?.state == .paired && offeredRefreshRates.contains(item.tag)
        case #selector(selectBitrate(_:)):
            return selected?.state == .paired
        default:
            return true
        }
    }

    /// Finder-style in-place rename of the row's name. Return has to reach
    /// the field editor, so the footer's default button gives up its key
    /// equivalent for the duration.
    private func beginRename(row: Int) {
        guard renamingRow == nil, let r = hostRow(at: row), r.host.publicKey != nil,
              let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostRowView else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        renamingRow = view
        HoverCard.shared.isSuspended = true
        connectButton.keyEquivalent = ""
        let host = r.host
        view.onRenameEnd = { [weak self, weak view] name in
            guard let self else { return }
            view?.onRenameEnd = nil
            self.renamingRow = nil
            self.connectButton.keyEquivalent = "\r"
            HoverCard.shared.isSuspended = false
            // This runs while the field editor is still resigning, so the
            // window's first responder is decided only afterwards: give the
            // list keyboard focus back unless a click took it somewhere.
            DispatchQueue.main.async {
                guard let window = self.window, window.firstResponder === window || window.firstResponder == nil else { return }
                window.makeFirstResponder(self.table)
            }
            guard let name else { return }
            // `apply` commits a rename before reloading; the delegate's
            // reload must not run inside that `apply`.
            DispatchQueue.main.async { self.pickerDelegate?.picker(self, rename: host, to: name) }
        }
        view.beginRename()
    }

    // MARK: context menu

    /// The hover card is scheduled on mouse-enter and a right-click does not
    /// cancel it, so it would open over the menu half a second later.
    func menuWillOpen(_ menu: NSMenu) {
        HoverCard.shared.isSuspended = true
    }

    func menuDidClose(_ menu: NSMenu) {
        // A rename in progress keeps the card suspended until it ends.
        if renamingRow == nil { HoverCard.shared.isSuspended = false }
    }

    /// Symbol images on menu items are the system's own: AppKit sizes and
    /// places them the way Finder's context menu does, so no configuration.
    private func menuItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self
        return item
    }

    /// Three sections, like Finder's Open / edit / Move to Trash: Connect
    /// (paired) or Pair (available) alone at the top, as the footer button
    /// would; the name items; Forget alone at the bottom.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let r = hostRow(at: table.clickedRow) else { return }
        if !connecting {
            menu.addItem(r.state == .paired
                ? menuItem("Connect", symbol: "display", action: #selector(connectClicked))
                : menuItem("Pair", symbol: "link", action: #selector(connectClicked)))
            if r.host.publicKey != nil { menu.addItem(.separator()) }
        }
        if r.host.publicKey != nil {
            menu.addItem(menuItem("Rename", symbol: "pencil", action: #selector(renameClicked)))
        }
        if r.nickname != nil {
            // Says what changes and what it becomes; "Revert to X" on a PC's
            // row reads as reverting the PC.
            menu.addItem(menuItem("Revert Name to “\(r.host.name)”", symbol: "arrow.counterclockwise", action: #selector(revertNameClicked)))
        }
        if r.state == .paired {
            menu.addItem(.separator())
            menu.addItem(menuItem("Forget", symbol: "xmark.circle", action: #selector(forgetClicked)))
        }
    }

    /// The clicked row becomes the selection first so the footer and status
    /// line describe the host being dialled.
    @objc private func connectClicked() {
        guard !connecting, let r = hostRow(at: table.clickedRow) else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        pickerDelegate?.picker(self, didChoose: r.host)
    }

    @objc private func showOptions() {
        let popover = NSPopover()
        popover.behavior = .transient

        let videoLabel = NSTextField(labelWithString: "Video")
        videoLabel.font = Style.Font.section
        videoLabel.textColor = .secondaryLabelColor

        let slider = NSSlider(
            value: VideoBitrate.sliderPosition(for: prefs.bitrateMbps),
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(optionChanged(_:))
        )
        slider.identifier = .init("bitrateSlider")
        slider.isContinuous = true
        slider.setAccessibilityLabel("Video bitrate")
        slider.toolTip = "Video bitrate from 1 to 1,000 Mbps"
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let bitrate = NSTextField(string: String(prefs.bitrateMbps))
        bitrate.identifier = .init("bitrateField")
        bitrate.alignment = .right
        bitrate.delegate = self
        bitrate.target = self
        bitrate.action = #selector(optionChanged(_:))
        bitrate.setAccessibilityLabel("Video bitrate in megabits per second")
        bitrate.translatesAutoresizingMaskIntoConstraints = false
        bitrate.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        bitrate.formatter = formatter

        let unit = NSTextField(labelWithString: "Mbps")
        unit.font = Style.Font.body
        let bitrateRow = NSStackView(views: [slider, bitrate, unit])
        bitrateRow.orientation = .horizontal
        bitrateRow.alignment = .centerY
        bitrateRow.spacing = Style.Space.s
        bitrateSlider = slider
        bitrateField = bitrate
        syncBitrateControls()

        let modifiers = NSPopUpButton(frame: .zero, pullsDown: false)
        modifiers.addItem(withTitle: "⌘ acts as Ctrl (Mac shortcuts work)")
        modifiers.lastItem?.representedObject = ModifierMapping.mac.rawValue
        modifiers.addItem(withTitle: "Keys by physical position")
        modifiers.lastItem?.representedObject = ModifierMapping.physical.rawValue
        modifiers.selectItem(at: prefs.modifiers == .mac ? 0 : 1)
        modifiers.target = self
        modifiers.action = #selector(optionChanged(_:))
        modifiers.identifier = .init("modifiers")

        // Same words as View ▸ Native Keyboard and Pointer Control, in the
        // sentence case checkboxes use; shortcuts belong in the menu, not here.
        let input = NSButton(checkboxWithTitle: "Native keyboard and pointer control", target: self, action: #selector(optionChanged(_:)))
        input.state = prefs.forwardInput ? .on : .off
        input.identifier = .init("input")
        let latency = NSButton(checkboxWithTitle: "Show latency stats", target: self, action: #selector(optionChanged(_:)))
        latency.state = prefs.showLatency ? .on : .off
        latency.identifier = .init("latency")

        let keyboardLabel = NSTextField(labelWithString: "Keyboard")
        keyboardLabel.font = Style.Font.section
        keyboardLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [videoLabel, bitrateRow, keyboardLabel, modifiers, input, latency])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.Space.s
        stack.setCustomSpacing(Style.Space.xs, after: videoLabel)
        stack.setCustomSpacing(Style.Space.l, after: bitrateRow)
        stack.setCustomSpacing(Style.Space.xs, after: keyboardLabel)
        stack.edgeInsets = NSEdgeInsets(top: Style.Space.l, left: Style.Space.l, bottom: Style.Space.l, right: Style.Space.l)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let vc = NSViewController()
        vc.view = NSView()
        vc.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: vc.view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            vc.view.widthAnchor.constraint(equalToConstant: 312),
        ])
        popover.contentViewController = vc
        popover.show(relativeTo: optionsButton.bounds, of: optionsButton, preferredEdge: .maxY)
    }

    @objc private func optionChanged(_ sender: NSControl) {
        switch sender.identifier?.rawValue {
        case "bitrateSlider":
            prefs.bitrateMbps = VideoBitrate.bitrate(forSliderPosition: (sender as? NSSlider)?.doubleValue ?? 0)
            syncBitrateControls()
        case "bitrateField":
            commitBitrateField(sender as? NSTextField)
        case "modifiers":
            if let raw = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String,
               let m = ModifierMapping(rawValue: raw) {
                prefs.modifiers = m
            }
        case "input": prefs.forwardInput = (sender as? NSButton)?.state == .on
        case "latency": prefs.showLatency = (sender as? NSButton)?.state == .on
        default: return
        }
        onPrefsChange?(prefs)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field.identifier?.rawValue == "bitrateField" else { return }
        commitBitrateField(field)
        onPrefsChange?(prefs)
    }

    private func commitBitrateField(_ field: NSTextField?) {
        let entered = Int(field?.stringValue ?? "") ?? prefs.bitrateMbps
        prefs.bitrateMbps = VideoBitrate.clamp(entered)
        syncBitrateControls()
    }

    private func syncBitrateControls() {
        bitrateSlider?.doubleValue = VideoBitrate.sliderPosition(for: prefs.bitrateMbps)
        bitrateField?.stringValue = String(prefs.bitrateMbps)
        bitrateSlider?.setAccessibilityValue("\(prefs.bitrateMbps) Mbps")
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].host != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].isHeader ? Style.sectionRowHeight : Style.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateConnectButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let section):
            let view = tableView.makeView(withIdentifier: SectionHeaderView.identifier, owner: nil) as? SectionHeaderView
                ?? SectionHeaderView(frame: .zero)
            view.configure(section: section)
            return view
        case .host(let host, let state, let nickname):
            let view = tableView.makeView(withIdentifier: HostRowView.identifier, owner: nil) as? HostRowView
                ?? HostRowView(frame: .zero)
            view.configure(host: host, state: state, nickname: nickname)
            return view
        }
    }
}
