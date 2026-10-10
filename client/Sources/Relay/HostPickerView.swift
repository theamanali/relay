import AppKit
import SwiftUI

struct HostPickerView: View {
    @Bindable var model: PickerModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: Glyphs.towerAndMacBook(pointSize: 44))
                    .foregroundStyle(.tint).accessibilityHidden(true)
                Text("Relay").font(.title2.weight(.semibold))
                Text("Use this Mac as your PC’s display.").foregroundStyle(.secondary)
            }
            .padding(.top, 24).padding(.bottom, 20)
            if model.rows.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your PC…")
                    Text("Open Relay on the PC and connect it to this Mac or the same network.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach([PickerSection.paired, .available], id: \.self) { section in
                        let rows = model.rows.filter { $0.paired == (section == .paired) }
                        if !rows.isEmpty {
                            Section(section.title) {
                                ForEach(rows) { row in
                                    HostPickerRow(row: row, model: model).tag(row.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset).accessibilityLabel("PCs")
                .onDeleteCommand { if model.selected?.paired == true { model.forgetCandidate = model.selected } }
                .animation(.easeInOut(duration: 0.2), value: model.rows.map(\.id))
                .animation(.easeInOut(duration: 0.2), value: model.rows.map(\.paired))
            }
            Divider()
            VStack(spacing: 12) {
                HStack {
                    Picker("Resolution", selection: Binding(get: { model.mode.scale }, set: {
                        model.setMode(StreamMode(scale: $0, refresh: model.mode.refresh))
                    })) {
                        ForEach(StreamMode.scales, id: \.self) { scale in
                            let size = StreamMode.size(native: model.nativePixelSize, scale: scale)
                            Text("\(scale == 1 ? "Native" : "\(Int(scale * 100))%") (\(size.width) × \(size.height))").tag(scale)
                        }
                    }.labelsHidden()
                    if model.refreshRates.count > 1 {
                        Picker("Refresh rate", selection: Binding(get: { model.mode.refresh }, set: {
                            model.setMode(StreamMode(scale: model.mode.scale, refresh: $0))
                        })) {
                            ForEach(model.refreshRates, id: \.self) { Text("\($0) Hz").tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    }
                }.disabled(!model.canConfigure)
                HStack {
                    Button { model.settingsPresented = true } label: { Image(systemName: "gearshape") }
                        .help("Settings").accessibilityLabel("Settings").disabled(!model.canConfigure)
                        .popover(isPresented: $model.settingsPresented) { SessionSettingsView(model: model).padding(20).frame(width: 340) }
                    Text(SessionText.fit(model.footer)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(model.footer)
                    Spacer(minLength: 4)
                    Button(model.connectTitle) { model.finishRename(); model.connect?() }
                        .keyboardShortcut(model.renamingID == nil ? KeyboardShortcut.defaultAction : nil)
                        .disabled(model.selected == nil && !model.connecting)
                }
            }.padding(16)
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 500, idealHeight: 540)
        .sheet(item: $model.pinPrompt, onDismiss: {}) { prompt in
            PINPromptView(prompt: prompt)
                .onDisappear { prompt.respond(nil) }
                .interactiveDismissDisabled()
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Forget “\(model.forgetCandidate?.name ?? "this PC")”?", isPresented: Binding(
            get: { model.forgetCandidate != nil }, set: { if !$0 { model.forgetCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let row = model.forgetCandidate { model.forget?(row.host) }
                model.forgetCandidate = nil
            }
        } message: { Text("To connect again, you’ll need to enter its PIN.") }
    }
}

private struct HostPickerRow: View {
    let row: PickerModel.Row
    @Bindable var model: PickerModel
    @FocusState private var editing: Bool
    @State private var details = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pc").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if model.renamingID == row.id {
                    TextField("PC name", text: $model.renameDraft).textFieldStyle(.roundedBorder)
                        .focused($editing).onAppear { editing = true }
                        .onSubmit { model.finishRename() }
                        .onExitCommand { model.finishRename(cancel: true) }
                        .onChange(of: editing) { _, focused in if !focused { model.finishRename() } }
                } else { Text(row.name).lineLimit(1) }
                Text(row.host.connectLink).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { details.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).accessibilityLabel("About \(row.name)")
                .popover(isPresented: $details) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(row.name).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(row.host.facts.rows, id: \.label) { fact in
                                GridRow { Text(fact.label).foregroundStyle(.secondary); Text(fact.value) }
                            }
                            ForEach(row.host.reachableAddresses, id: \.address) { address in
                                GridRow { Text(address.link).foregroundStyle(.secondary); Text(address.address).textSelection(.enabled) }
                            }
                        }.font(.caption)
                        if let key = row.host.publicKey { Text("Fingerprint \(fingerprint(key))").font(.caption).foregroundStyle(.secondary) }
                    }.padding(16).frame(maxWidth: 400)
                }
        }
        .padding(.vertical, 5).contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !model.connecting else { return }
            model.selection = row.id; model.connect?()
        }
        .simultaneousGesture(TapGesture().onEnded {
            if model.renamingID != row.id { model.finishRename() }
            model.selection = row.id
        })
        .contextMenu {
            Button(row.paired ? "Connect" : "Pair", systemImage: row.paired ? "display" : "link") {
                model.selection = row.id; model.connect?()
            }.disabled(model.connecting)
            Button("Rename…", systemImage: "pencil") { model.beginRename(row) }
                .disabled(row.host.publicKey == nil || model.connecting)
            if row.nickname != nil {
                Button("Revert Name", systemImage: "arrow.uturn.backward") { model.selection = row.id; model.revertName() }
            }
            if row.paired {
                Divider()
                Button("Forget…", systemImage: "link.badge.plus", role: .destructive) { model.forgetCandidate = row }
                    .disabled(model.connecting)
            }
        }
    }
}

struct SessionSettingsView: View {
    @Bindable var model: PickerModel
    private func preference<Value>(_ key: WritableKeyPath<SessionPrefs, Value>) -> Binding<Value> {
        Binding(get: { model.prefs[keyPath: key] }, set: { value in
            var prefs = model.prefs; prefs[keyPath: key] = value; model.setPrefs(prefs)
        })
    }
    var body: some View {
        Form {
            Section("Video") {
                HStack {
                    TextField("Bitrate", value: preference(\.bitrateMbps), format: .number).frame(width: 130)
                    Text("Mbps").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { VideoBitrate.sliderPosition(for: model.prefs.bitrateMbps) }, set: {
                    var prefs = model.prefs; prefs.bitrateMbps = VideoBitrate.bitrate(forSliderPosition: $0); model.setPrefs(prefs)
                }), in: 0...1).accessibilityLabel("Video bitrate")
                Toggle("Show latency stats", isOn: preference(\.showLatency))
            }
            Section("Input") {
                Picker("Modifier keys", selection: preference(\.modifiers)) {
                    Text("⌘ acts as Ctrl").tag(ModifierMapping.mac)
                    Text("Physical positions").tag(ModifierMapping.physical)
                }
                Toggle("Control the PC", isOn: preference(\.forwardInput))
            }
        }.formStyle(.grouped)
    }
}

struct PINPromptView: View {
    @Bindable var prompt: PINPrompt
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter the PIN for “\(prompt.host)”").font(.headline)
            Text(prompt.explanation).foregroundStyle(.secondary)
            TextField("Six-digit PIN", text: $prompt.code)
                .textFieldStyle(.roundedBorder).font(.system(.title, design: .monospaced))
                .focused($focused).accessibilityLabel("Six-digit pairing PIN")
                .onChange(of: prompt.code) { _, value in
                    let digits = PINPrompt.digits(value)
                    if digits != value { prompt.code = digits }
                    if digits.count == 6 { prompt.respond(digits) }
                }
            Text("Fingerprint \(prompt.fingerprint)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { prompt.respond(nil) }.keyboardShortcut(.cancelAction)
                Button("Pair") { prompt.respond(prompt.code) }.keyboardShortcut(.defaultAction)
                    .disabled(prompt.code.count != 6)
            }
        }.padding(24).frame(width: 360).onAppear { focused = true }
    }
}
