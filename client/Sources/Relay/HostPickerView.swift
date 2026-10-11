// The launch window: a compact utility panel listing discovered hosts under
// Paired / Available. Return / double-click / Connect starts a session;
// closing the window quits.

import AppKit
import SwiftUI

struct HostPickerView: View {
    @Bindable var model: PickerModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, Style.headerTopInset)
                .padding(.horizontal, Style.Space.margin)
            // The list's own darker background spans the window, edge to edge
            // between the header and the footer, and is as tall as its rows.
            HostList(model: model)
                .frame(height: model.listHeight)
                .padding(.top, Style.Space.margin)
            PickerFooter(model: model)
        }
        .frame(width: Style.windowWidth)
        .onChange(of: model.renamingID != nil || model.settingsPresented) { _, busy in
            HoverCard.shared.isSuspended = busy
        }
        .sheet(item: $model.pinPrompt) { prompt in
            PINPromptView(prompt: prompt)
                .onDisappear { prompt.respond(nil) }
                .interactiveDismissDisabled()
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(verbatim: notice.title), message: Text(verbatim: notice.message), dismissButton: .default(Text("OK")))
        }
        .alert(
            "Are you sure you want to forget “\(model.forgetCandidate?.name ?? "this PC")”?",
            isPresented: Binding(get: { model.forgetCandidate != nil }, set: { if !$0 { model.forgetCandidate = nil } }),
            presenting: model.forgetCandidate
        ) { row in
            Button("Forget", role: .destructive) {
                model.forgetCandidate = nil
                model.forget?(row.host)
            }
            Button("Cancel", role: .cancel) { model.forgetCandidate = nil }
        } message: { _ in
            Text("Your MacBook will no longer be paired with this PC. To connect again, you’ll need to enter its PIN.")
        }
        // Presented from its own view: the suppression toggle applies to every
        // dialog presented within the view it modifies, and Forget must not
        // offer "Don't ask again".
        .background { WiFiConnectAlert(model: model) }
    }

    /// Hero glyph, title, one-line purpose.
    private var header: some View {
        VStack(spacing: Style.Space.tight) {
            Image(nsImage: Glyphs.towerAndMacBook(pointSize: 44))
                .renderingMode(.template)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
                .padding(.bottom, Style.Space.s - Style.Space.tight)
            Text("Relay").font(Style.Font.title)
            Text("Use this MacBook as your PC’s display.")
                .font(Style.Font.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Connecting over Wi-Fi works, but a cable is the better link: say so once,
/// in the system's alert, with its own "Don't ask again".
private struct WiFiConnectAlert: View {
    @Bindable var model: PickerModel
    @AppStorage(PickerModel.wifiWarningSuppressedKey) private var suppressed = false

    var body: some View {
        Color.clear
            .alert(
                "Connect to “\(model.wifiCandidate?.name ?? "this PC")” over Wi-Fi?",
                isPresented: Binding(get: { model.wifiCandidate != nil }, set: { if !$0 { model.wifiCandidate = nil } }),
                presenting: model.wifiCandidate
            ) { _ in
                Button("Connect") {
                    model.wifiCandidate = nil
                    model.connect?()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { model.wifiCandidate = nil }
            } message: { _ in
                Text("Relay works over Wi-Fi, but the picture may lag or drop frames. For the best experience, connect your MacBook directly to your PC with an Ethernet cable.")
            }
            .dialogSuppressionToggle(isSuppressed: $suppressed)
    }
}

// MARK: list

private struct HostList: View {
    @Bindable var model: PickerModel
    /// Glyph and name where the old table drew them; the inset list's own
    /// selection inset is fixed at 10 points from the window edge.
    static let rowInsets = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    var body: some View {
        // One ForEach over stably identified items, so rows are never matched
        // by position (that cross-faded the Paired and Available titles).
        List(selection: $model.selection) {
            ForEach(model.listItems) { item in
                switch item {
                case let .title(section, collapsed, collapsible):
                    SectionHeaderRow(section: section, collapsed: collapsed, collapsible: collapsible,
                                     // The searching row has the spinner while it shows.
                                     searching: section == .available && (collapsed || !model.availableRows.isEmpty),
                                     height: item.height) {
                        // The window's height eases; the rows change in place.
                        withAnimation(.easeInOut(duration: 0.25)) { model.toggle(section) }
                    }
                    .pickerListRow()
                    .selectionDisabled()
                case let .host(row):
                    HostRow(row: row, model: model).tag(row.id).pickerListRow()
                case .noPaired:
                    Text("No paired devices yet")
                        .font(Style.Font.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: item.height, maxHeight: item.height, alignment: .leading)
                        .pickerListRow()
                        .selectionDisabled()
                case .searching:
                    SearchingRow()
                        .pickerListRow()
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.inset)
        // No PC at all: the list's background stays, with the empty state on it.
        .overlay { if model.rows.isEmpty { NoPCsFound() } }
        // Rows and titles update in place. The list's own insert, remove and
        // move animations slid rows over a fading one and through each other;
        // only the window's height animates (HostPickerWindowController).
        .transaction { $0.animation = nil }
        // A list that fits its rows reserves no scroller gutter on the right.
        .scrollIndicators(model.listOverflows ? .automatic : .never)
        .accessibilityLabel("PCs")
        .onDeleteCommand { if model.selected?.paired == true { model.forgetCandidate = model.selected } }
    }
}

private extension View {
    func pickerListRow() -> some View {
        listRowInsets(HostList.rowInsets).listRowSeparator(.hidden)
    }
}

/// A section's title. When the section can fold, clicking the title folds it
/// away or back, as the chevron at the right shows.
private struct SectionHeaderRow: View {
    let section: PickerSection
    let collapsed: Bool
    let collapsible: Bool
    let searching: Bool
    let height: CGFloat
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: section.title)
                .font(Style.Font.section)
                .foregroundStyle(.secondary)
            if searching {
                ProgressView().controlSize(.mini).accessibilityLabel("Searching for PCs")
            }
            Spacer(minLength: 0)
            if collapsible {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, Style.Space.xs)
        // Paired comes first; Available's taller row leaves room above it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { if collapsible { toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(collapsible ? [.isHeader, .isButton] : .isHeader)
        .accessibilityValue(collapsible ? (collapsed ? "Collapsed" : "Expanded") : "")
        .accessibilityAction { if collapsible { toggle() } }
    }
}

/// Stands in for PCs under Available while none is around: discovery keeps
/// going, with the spinner where a PC's glyph would be.
private struct SearchingRow: View {
    var body: some View {
        HStack(spacing: Style.Space.s) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text("Searching for PCs…")
                .font(Style.Font.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: Style.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// The empty state: no PC at all yet, paired or not. Discovery keeps
/// running, which the spinner says; the instruction says what to do on the PC.
private struct NoPCsFound: View {
    var body: some View {
        VStack(spacing: Style.Space.m) {
            Text("No PCs Found")
                .font(.title3.weight(.semibold))
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Searching for PCs")
            Text("Open Relay on the PC and connect it to this MacBook or the same network.")
                .font(Style.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .padding(.horizontal, Style.Space.margin)
        // The list starts Space.margin below the header; the same margin here
        // centers the block between the subtitle and the footer's rule, and
        // 2 more points even out the subtitle's descenders (44 pt both ways).
        .padding(.bottom, Style.Space.margin + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A PC glyph, the name and the link it will be reached over. The pairing
/// state is the section's; Rename and Forget live in the context menu (and
/// Delete forgets), details in the hover card.
private struct HostRow: View {
    let row: PickerModel.Row
    @Bindable var model: PickerModel
    @FocusState private var editing: Bool

    /// Where the name starts: glyph column plus its gap.
    private static let nameInset: CGFloat = 32 + Style.Space.s

    var body: some View {
        HStack(spacing: Style.Space.s) {
            Image(nsImage: Glyphs.tower(pointSize: 22))
                .renderingMode(.template)
                .foregroundStyle(row.paired ? .primary : .secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Style.Space.tight) {
                if model.renamingID == row.id {
                    renameField
                } else {
                    Text(verbatim: row.name).font(Style.Font.body).lineLimit(1).truncationMode(.tail)
                }
                Text(verbatim: row.detail)
                    .font(Style.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Style.rowHeight)
        .contentShape(Rectangle())
        .background(HoverCardAnchor(rows: row.hoverRows, leadingInset: Self.nameInset))
        .onTapGesture(count: 2) {
            guard !model.connecting else { return }
            model.selection = row.id
            model.requestConnect()
        }
        .simultaneousGesture(TapGesture().onEnded {
            if model.renamingID != row.id { model.finishRename() }
            model.selection = row.id
        })
        .contextMenu { contextMenu }
    }

    /// Finder-style: the name becomes a box sized to its text with the text
    /// selected. Return commits, Escape puts the old name back, and focus
    /// leaving any other way commits too, as Finder does.
    private var renameField: some View {
        TextField("", text: $model.renameDraft)
            .textFieldStyle(.squareBorder)
            .font(Style.Font.body)
            .frame(width: Self.fittedWidth(model.renameDraft))
            .focused($editing)
            .onAppear { editing = true }
            .onSubmit { model.finishRename() }
            .onExitCommand { model.finishRename(cancel: true) }
            .onChange(of: editing) { _, focused in if !focused { model.finishRename() } }
            .onChange(of: model.renameDraft) { _, text in
                if text.count > PickerModel.maxNameLength { model.renameDraft = String(text.prefix(PickerModel.maxNameLength)) }
            }
    }

    /// Text plus the bezel's own insets and room for the caret; an emptied
    /// box keeps enough width to be seen.
    private static func fittedWidth(_ text: String) -> CGFloat {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return max(48, ceil(width) + 12)
    }

    /// Three sections, like Finder's Open / edit / Move to Trash: Connect
    /// (paired) or Pair (available) alone at the top, as the footer button
    /// would; the name items; Forget alone at the bottom.
    @ViewBuilder private var contextMenu: some View {
        let named = row.host.publicKey != nil
        if !model.connecting {
            Button(row.paired ? "Connect" : "Pair", systemImage: row.paired ? "display" : "link") {
                model.selection = row.id
                model.requestConnect()
            }
            if named { Divider() }
        }
        if named {
            Button("Rename", systemImage: "pencil") { model.beginRename(row) }
                .disabled(model.connecting)
        }
        if row.nickname != nil {
            // Says what changes and what it becomes; "Revert to X" on a PC's
            // row reads as reverting the PC.
            Button("Revert Name to “\(row.host.name)”", systemImage: "arrow.counterclockwise") {
                model.selection = row.id
                model.revertName()
            }
        }
        if row.paired {
            Divider()
            Button("Forget", systemImage: "xmark.circle") { model.forgetCandidate = row }
                .disabled(model.connecting)
        }
    }
}

// MARK: footer

/// A separated band with the stream mode and settings on one line and
/// status · Connect on the next.
private struct PickerFooter: View {
    @Bindable var model: PickerModel

    var body: some View {
        VStack(spacing: Style.Space.m) {
            HStack(spacing: Style.Space.m) {
                Picker("Resolution", selection: Binding(get: { model.mode.scale }, set: {
                    model.setMode(StreamMode(scale: $0, refresh: model.mode.refresh))
                })) {
                    ForEach(StreamMode.scales, id: \.self) { scale in
                        Text(verbatim: model.resolutionTitle(scale)).tag(scale)
                    }
                }
                .labelsHidden()
                // Takes the row's slack, so every gap stays Space.m and the
                // gear lines up with Connect.
                .frame(maxWidth: .infinity)
                .help("Resolution to stream")
                if model.refreshRates.count > 1 {
                    // Disabled, no segment is selected: a selected one still
                    // draws in the accent color and looks live beside the
                    // dimmed popup and gear. The rate comes back with a PC.
                    Picker("Refresh rate", selection: Binding<Int?>(get: {
                        model.canConfigure ? model.mode.refresh : nil
                    }, set: {
                        if let rate = $0 { model.setMode(StreamMode(scale: model.mode.scale, refresh: rate)) }
                    })) {
                        ForEach(model.refreshRates, id: \.self) { Text(verbatim: "\($0) Hz").tag(Int?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Refresh rate")
                }
                Button { model.showSettings() } label: {
                    Image(systemName: "gearshape").frame(width: 24)
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .popover(isPresented: $model.settingsPresented, arrowEdge: model.settingsEdge) {
                    SessionSettingsView(model: model)
                }
            }
            // The mode and settings describe a session, and only a paired PC
            // can start one; until then the controls have nothing to apply to.
            .disabled(!model.canConfigure)
            HStack(spacing: Style.Space.m) {
                // One line, never wider than the space before Connect; the
                // full text is a hover away if it had to be clipped.
                let shown = SessionText.fit(model.status)
                Text(verbatim: shown)
                    .font(Style.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(shown == model.status ? "" : model.status)
                Spacer(minLength: 0)
                Button { model.requestConnect() } label: {
                    Text(model.connectTitle).frame(minWidth: 74)
                }
                // Return has to reach the rename box while it is open.
                .keyboardShortcut(model.renamingID == nil ? KeyboardShortcut.defaultAction : nil)
                .disabled(model.selected == nil && !model.connecting)
            }
        }
        .padding(.vertical, Style.Space.l)
        .padding(.horizontal, Style.Space.margin)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: settings popover

struct SessionSettingsView: View {
    @Bindable var model: PickerModel

    private func preference<Value>(_ key: WritableKeyPath<SessionPrefs, Value>) -> Binding<Value> {
        Binding(get: { model.prefs[keyPath: key] }, set: { value in
            var prefs = model.prefs
            prefs[keyPath: key] = value
            model.setPrefs(prefs)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Video").font(Style.Font.section).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Style.Space.tight) {
                Text("Bitrate")
                Text("Higher looks sharper but needs a faster connection.")
                    .font(Style.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, Style.Space.xs)
            HStack(spacing: Style.Space.s) {
                Slider(value: Binding(get: { VideoBitrate.sliderPosition(for: model.prefs.bitrateMbps) }, set: {
                    var prefs = model.prefs
                    prefs.bitrateMbps = VideoBitrate.bitrate(forSliderPosition: $0)
                    model.setPrefs(prefs)
                }), in: 0...1)
                .frame(width: 160)
                .accessibilityLabel("Video bitrate")
                .accessibilityValue("\(model.prefs.bitrateMbps) Mbps")
                .help("Video bitrate from 1 to 1,000 Mbps")
                TextField("", value: preference(\.bitrateMbps), format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
                    .accessibilityLabel("Video bitrate in megabits per second")
                Text("Mbps").font(Style.Font.body)
            }
            .padding(.top, Style.Space.xs)
            DescribedCheckbox("Enable VSync",
                              detail: "Prevents tearing but adds up to a frame of delay.",
                              isOn: preference(\.preventTearing))
                .padding(.top, Style.Space.s)
            Toggle("Show latency overlay", isOn: preference(\.showLatency))
                .toggleStyle(.checkbox)
                .padding(.top, Style.Space.s)
            // Keyboard and pointer: modifier keys, scrolling, and whether the
            // Mac controls the PC at all.
            Text("Input").font(Style.Font.section).foregroundStyle(.secondary)
                .padding(.top, Style.Space.l)
            // Also PC ▸ Control / Observe and ⌃⌥⌘K. The options under it only
            // matter while the Mac controls the PC; they keep their values.
            Toggle("Control the PC", isOn: preference(\.forwardInput))
                .toggleStyle(.checkbox)
                .padding(.top, Style.Space.xs)
            Group {
                // Off sends keys by their physical position instead. The note
                // describes the current mapping, in the same key order.
                DescribedCheckbox("Mac-style modifier keys",
                                  detail: model.prefs.modifiers == .mac
                                      ? "⌘ is Ctrl, ⌥ is Alt, ⌃ is the Windows key."
                                      : "⌘ is Alt, ⌥ is the Windows key, ⌃ is Ctrl.",
                                  isOn: Binding(get: { model.prefs.modifiers == .mac }, set: {
                                      var prefs = model.prefs; prefs.modifiers = $0 ? .mac : .physical; model.setPrefs(prefs)
                                  }))
                    .padding(.top, Style.Space.s)
                Toggle("Natural scrolling", isOn: Binding(get: {
                    model.prefs.naturalScrolling(macNatural: SessionPrefs.macNaturalScrolling)
                }, set: {
                    var prefs = model.prefs; prefs.scrollDirection = $0 ? .natural : .standard; model.setPrefs(prefs)
                }))
                .toggleStyle(.checkbox)
                .padding(.top, Style.Space.s)
            }
            .disabled(!model.prefs.forwardInput)
        }
        .padding(Style.Space.l)
        .frame(width: Style.settingsWidth, alignment: .leading)
        // The popover would otherwise make the bitrate field first responder,
        // and the first keystroke would change the bitrate. Click to edit it.
        .background(NoInitialFocus())
    }
}

/// A settings checkbox with a line of explanation under its title.
private struct DescribedCheckbox: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: Style.Space.tight) {
                Text(verbatim: title)
                // One line: the popover is narrow, so keep details short.
                Text(verbatim: detail)
                    .font(Style.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Clears the keyboard focus AppKit gives a popover's first control when it
/// opens, once; SwiftUI's focus state does not override that choice.
private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Clearer() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Clearer: NSView {
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window, !done else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(clear),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            DispatchQueue.main.async { [weak self] in self?.clear() }
        }

        @objc private func clear() {
            guard !done, let window, window.isKeyWindow else { return }
            done = true
            NotificationCenter.default.removeObserver(self)
            window.makeFirstResponder(nil)
        }
    }
}

// MARK: PIN sheet

/// Shaped like Apple's verification-code sheet: six boxes that submit on the
/// last digit; Pair only as the Return fallback.
struct PINPromptView: View {
    @Bindable var prompt: PINPrompt

    var body: some View {
        VStack(spacing: 0) {
            // The PC being paired, in the accent color like the window's hero.
            Image(nsImage: Glyphs.tower(pointSize: 44))
                .renderingMode(.template)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Enter the PIN for “\(prompt.host)”")
                .font(.system(size: 13, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, Style.Space.m)
            Text(verbatim: prompt.explanation)
                .font(Style.Font.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Style.Space.s)
            // No fingerprint here: CPace makes the PIN authenticate both
            // sides, and the PC's tray shows none to compare it with.
            PINEntry(code: $prompt.code) { prompt.respond($0) }
                .fixedSize()
                .padding(.top, Style.Space.l)
            HStack(spacing: Style.Space.s) {
                Button(role: .cancel) { prompt.respond(nil) } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button { prompt.respond(prompt.code) } label: {
                    Text("Pair").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.code.count != PINEntryView.length)
            }
            .controlSize(.large)
            .padding(.top, Style.Space.margin)
        }
        .padding(Style.Space.margin)
        .frame(width: 300)
    }
}
