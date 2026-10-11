import AppKit
import SwiftUI

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    }

    var body: some Scene {
        Window("Relay", id: "picker") {
            HostPickerView(model: delegate.pickerModel)
                .background(PickerWindowReader { delegate.attachPickerWindow($0) })
        }
        // The compact utility panel: no title text over a transparent title
        // bar, a fixed size, no full screen (AppDelegate.attachPickerWindow).
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { RelayCommands(model: delegate.pickerModel, delegate: delegate) }
    }
}

/// SwiftUI owns the picker window and layout; the adapter observes its screen
/// and lifecycle so the requested Windows mode follows the selected Mac screen.
private struct PickerWindowReader: NSViewRepresentable {
    let attached: @MainActor (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(attached: attached) }
    func updateNSView(_ view: WindowProbe, context: Context) {}

    final class WindowProbe: NSView {
        let attached: @MainActor (NSWindow) -> Void
        init(attached: @escaping @MainActor (NSWindow) -> Void) {
            self.attached = attached
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Task { @MainActor [weak self, weak window] in
                if let self, let window { attached(window) }
            }
        }
    }
}

struct RelayCommands: Commands {
    @Bindable var model: PickerModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    /// The items below act on the picker's selection and mode; while a
    /// session's kiosk window is key the stream swallows ⌘-shortcuts anyway.
    private var paired: Bool { model.pickerActive && model.canConfigure }

    var body: some Commands {
        // Commands exist from launch, windows or not, so they are where the
        // delegate gets a way to open the picker itself (see showPicker).
        let _ = delegate.registerPickerOpener { openWindow(id: "picker") }
        CommandGroup(replacing: .appInfo) {
            Button("About Relay") { delegate.showAbout(nil) }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",").disabled(!paired)
        }
        // Relay has no documents; the PC menu takes File's place.
        CommandGroup(replacing: .newItem) {}
        CommandMenu("PC") {
            let selected = model.selected
            Button(selected?.paired == false ? "Pair" : "Connect",
                   systemImage: selected?.paired == false ? "link" : "display") {
                model.requestConnect()
            }
            .keyboardShortcut(.return)
            // Not mid-rename: Return there commits the name.
            .disabled(!model.pickerActive || selected == nil || model.connecting || model.renamingID != nil)
            Divider()
            // Return is Connect, so Finder's rename key is not available.
            Button("Rename", systemImage: "pencil") { model.beginRename() }
                .keyboardShortcut("r")
                .disabled(!model.pickerActive || selected?.host.publicKey == nil || model.connecting || model.renamingID != nil)
            Button(selected?.nickname != nil ? "Revert Name to “\(selected?.host.name ?? "")”" : "Revert Name",
                   systemImage: "arrow.counterclockwise") { model.revertName() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                // Not mid-edit: the edit's own commit would land after the revert.
                .disabled(!model.pickerActive || selected?.nickname == nil || model.renamingID != nil)
            Divider()
            Button("Forget", systemImage: "xmark.circle") { model.forgetCandidate = selected }
                .keyboardShortcut(.delete)
                .disabled(!model.pickerActive || selected?.paired != true || model.connecting)
            Divider()
            // How the PC is used, not something done to one row. Screen
            // Sharing's two modes, as a radio pair; ⌃⌥⌘K sits on whichever
            // is not current, so the key always switches modes.
            controlMode("Control", systemImage: "keyboard", forwardInput: true)
            controlMode("Observe", systemImage: "eye", forwardInput: false)
            Divider()
            // Not performClose: AppKit pairs that with an automatic "Close All".
            Button("Close Window", systemImage: "xmark") { delegate.closeKeyWindow(nil) }
                .keyboardShortcut("w")
        }
        // The stream mode, as the footer offers it: sizes, rates and bitrate
        // as submenus of checkmarks, usable once a paired PC is selected.
        // Refresh Rate disappears on a panel with one rate, as the footer's
        // control does.
        CommandGroup(before: .toolbar) {
            Menu {
                ForEach(StreamMode.scales, id: \.self) { scale in
                    Toggle(isOn: Binding(get: { model.mode.scale == scale }, set: { _ in
                        model.setMode(StreamMode(scale: scale, refresh: model.mode.refresh))
                    })) { Text(verbatim: model.resolutionTitle(scale)) }
                }
            } label: {
                Label("Resolution", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!paired)
            if model.refreshRates.count > 1 {
                Menu {
                    ForEach(model.refreshRates, id: \.self) { rate in
                        Toggle(isOn: Binding(get: { model.mode.refresh == rate }, set: { _ in
                            model.setMode(StreamMode(scale: model.mode.scale, refresh: rate))
                        })) { Text(verbatim: "\(rate) Hz") }
                    }
                } label: {
                    Label("Refresh Rate", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!paired)
            }
            Menu {
                // The presets, plus the current value in its sorted place when
                // the slider set something in between, so the checkmark is
                // never missing.
                ForEach(Array(Set(Self.bitratePresets + [model.prefs.bitrateMbps])).sorted(), id: \.self) { bitrate in
                    Toggle(isOn: Binding(get: { model.prefs.bitrateMbps == bitrate }, set: { _ in
                        var prefs = model.prefs; prefs.bitrateMbps = bitrate; model.setPrefs(prefs)
                    })) { Text(verbatim: "\(bitrate) Mbps") }
                }
                Divider()
                Button("Custom…") { model.showSettings() }
            } label: {
                Label("Bitrate", systemImage: "speedometer")
            }
            .disabled(!paired)
            Divider()
            Toggle(isOn: Binding(get: { model.prefs.showLatency }, set: {
                var prefs = model.prefs; prefs.showLatency = $0; model.setPrefs(prefs)
            })) {
                Label("Show Latency Overlay", systemImage: "chart.xyaxis.line")
            }
            .keyboardShortcut("l", modifiers: [.control, .option, .command])
            .disabled(!model.pickerActive)
        }
        CommandGroup(replacing: .help) {
            Button("Relay Help") { delegate.openHelp(nil) }
                .keyboardShortcut("?")
        }
    }

    private static let bitratePresets = [20, 50, 80, 120, 200, 400, 800]

    private func controlMode(_ title: String, systemImage: String, forwardInput: Bool) -> some View {
        let current = model.prefs.forwardInput == forwardInput
        return Toggle(isOn: Binding(get: { current }, set: { _ in
            guard !current else { return }
            var prefs = model.prefs; prefs.forwardInput = forwardInput; model.setPrefs(prefs)
        })) {
            Label(title, systemImage: systemImage)
        }
        .keyboardShortcut(current ? nil : KeyboardShortcut("k", modifiers: [.control, .option, .command]))
        .disabled(!model.pickerActive)
    }
}
