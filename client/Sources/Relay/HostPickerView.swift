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

// MARK: list

private struct HostList: View {
    @Bindable var model: PickerModel
    /// Glyph and name where the old table drew them; the inset list's own
    /// selection inset is fixed at 10 points from the window edge.
    static let rowInsets = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    var body: some View {
        List(selection: $model.selection) {
            // Plain rows rather than Section headers: the list's own headers
            // float with a band behind them.
            let paired = model.pairedRows
            if !paired.isEmpty {
                SectionHeaderRow(title: PickerSection.paired.title, first: true, searching: false)
                    .pickerListRow()
                    .selectionDisabled()
                ForEach(paired) { row in
                    HostRow(row: row, model: model).tag(row.id).pickerListRow()
                }
            }
            // Always listed: discovery never stops, and the spinner says so,
            // as System Settings' Bluetooth list does for nearby devices.
            SectionHeaderRow(title: PickerSection.available.title, first: paired.isEmpty, searching: true)
                .pickerListRow()
                .selectionDisabled()
            ForEach(model.availableRows) { row in
                HostRow(row: row, model: model).tag(row.id).pickerListRow()
            }
            if model.rows.isEmpty {
                FirstRunHintRow()
                    .pickerListRow()
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        // A list that fits its rows reserves no scroller gutter on the right.
        .scrollIndicators(model.listOverflows ? .automatic : .never)
        .accessibilityLabel("PCs")
        .onDeleteCommand { if model.selected?.paired == true { model.forgetCandidate = model.selected } }
        .animation(.easeInOut(duration: 0.2), value: model.rows.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: model.rows.map(\.paired))
    }
}

private extension View {
    func pickerListRow() -> some View {
        listRowInsets(HostList.rowInsets).listRowSeparator(.hidden)
    }
}

private struct SectionHeaderRow: View {
    let title: String
    let first: Bool
    let searching: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(Style.Font.section)
                .foregroundStyle(.secondary)
            if searching {
                ProgressView().controlSize(.mini).accessibilityLabel("Searching for PCs")
            }
        }
        .padding(.bottom, Style.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Room between one group's last host and the next group's title.
        .frame(height: Style.sectionRowHeight + (first ? 0 : Style.Space.l))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The empty state: no PC at all yet, paired or not. The spinner beside
/// Available already says Relay is searching; this says what to do on the PC.
private struct FirstRunHintRow: View {
    var body: some View {
        Text("Open Relay on the PC and connect it to this MacBook or the same network.")
            .font(Style.Font.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Style.rowHeight)
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
            model.connect?()
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
                model.connect?()
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
                    Picker("Refresh rate", selection: Binding(get: { model.mode.refresh }, set: {
                        model.setMode(StreamMode(scale: model.mode.scale, refresh: $0))
                    })) {
                        ForEach(model.refreshRates, id: \.self) { Text(verbatim: "\($0) Hz").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Refresh rate")
                }
                Button { model.settingsPresented = true } label: {
                    Image(systemName: "gearshape").frame(width: 24)
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .popover(isPresented: $model.settingsPresented, arrowEdge: .top) {
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
                Button { model.finishRename(); model.connect?() } label: {
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
            Text("Keyboard").font(Style.Font.section).foregroundStyle(.secondary)
                .padding(.top, Style.Space.l)
            Picker("Modifier keys", selection: preference(\.modifiers)) {
                Text("⌘ acts as Ctrl (Mac shortcuts work)").tag(ModifierMapping.mac)
                Text("Keys by physical position").tag(ModifierMapping.physical)
            }
            .labelsHidden()
            .fixedSize()
            .padding(.top, Style.Space.xs)
            // PC ▸ Control / Observe as radio buttons. Shortcuts belong in
            // the menu, not here.
            Picker("Input", selection: preference(\.forwardInput)) {
                Text("Control the PC").tag(true)
                Text("Observe only").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.top, Style.Space.s)
            Toggle("Show latency stats", isOn: preference(\.showLatency))
                .toggleStyle(.checkbox)
                .padding(.top, Style.Space.s)
        }
        .padding(Style.Space.l)
        .frame(width: 312, alignment: .leading)
    }
}

// MARK: PIN sheet

/// Shaped like Apple's verification-code sheet: six boxes that submit on the
/// last digit; Pair only as the Return fallback.
struct PINPromptView: View {
    @Bindable var prompt: PINPrompt

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
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
            VStack(spacing: Style.Space.s) {
                PINEntry(code: $prompt.code) { prompt.respond($0) }
                    .fixedSize()
                Text(verbatim: "Fingerprint \(prompt.fingerprint)")
                    .font(Style.Font.caption)
                    .foregroundStyle(.secondary)
            }
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
