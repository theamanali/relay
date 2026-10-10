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
        .defaultSize(width: 480, height: 540)
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

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Relay") { delegate.showAbout(nil) }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.settingsPresented = true }
                .keyboardShortcut(",").disabled(!model.pickerActive || !model.canConfigure)
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("PC") {
            Button(model.selected?.paired == true ? "Connect" : "Pair") { model.finishRename(); model.connect?() }
                .keyboardShortcut(.return).disabled(!model.pickerActive || model.selected == nil || model.connecting)
            Button("Rename…") { model.beginRename() }
                .keyboardShortcut("r").disabled(!model.pickerActive || model.selected?.host.publicKey == nil || model.connecting)
            Button("Revert Name") { model.revertName() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.pickerActive || model.selected?.nickname == nil)
            Button("Forget…") { model.forgetCandidate = model.selected }
                .keyboardShortcut(.delete).disabled(!model.pickerActive || model.selected?.paired != true || model.connecting)
            Divider()
            Button(model.prefs.forwardInput ? "Observe" : "Control") {
                var prefs = model.prefs; prefs.forwardInput.toggle(); model.setPrefs(prefs)
            }.keyboardShortcut("k", modifiers: [.control, .option, .command]).disabled(!model.pickerActive)
        }
        CommandGroup(before: .toolbar) {
            Menu("Resolution") {
                ForEach(StreamMode.scales, id: \.self) { scale in
                    let size = StreamMode.size(native: model.nativePixelSize, scale: scale)
                    Toggle("\(scale == 1 ? "Native" : "\(Int(scale * 100))%") (\(size.width) × \(size.height))",
                           isOn: Binding(get: { model.mode.scale == scale }, set: { _ in
                        model.setMode(StreamMode(scale: scale, refresh: model.mode.refresh))
                    }))
                }
            }.disabled(!model.pickerActive || !model.canConfigure)
            if model.refreshRates.count > 1 {
                Menu("Refresh Rate") {
                    ForEach(model.refreshRates, id: \.self) { rate in
                        Toggle("\(rate) Hz", isOn: Binding(get: { model.mode.refresh == rate }, set: { _ in
                            model.setMode(StreamMode(scale: model.mode.scale, refresh: rate))
                        }))
                    }
                }.disabled(!model.pickerActive || !model.canConfigure)
            }
            Menu("Bitrate") {
                ForEach(Array(Set([20, 50, 80, 120, 200, 400, 800, model.prefs.bitrateMbps])).sorted(), id: \.self) { bitrate in
                    Toggle("\(bitrate) Mbps", isOn: Binding(get: { model.prefs.bitrateMbps == bitrate }, set: { _ in
                        var prefs = model.prefs; prefs.bitrateMbps = bitrate; model.setPrefs(prefs)
                    }))
                }
                Button("Custom…") { model.settingsPresented = true }
            }.disabled(!model.pickerActive || !model.canConfigure)
            Divider()
            Toggle("Show Latency Stats", isOn: Binding(get: { model.prefs.showLatency }, set: {
                var prefs = model.prefs; prefs.showLatency = $0; model.setPrefs(prefs)
            })).keyboardShortcut("l", modifiers: [.control, .option, .command]).disabled(!model.pickerActive)
        }
        CommandGroup(replacing: .help) { Button("Relay Help") { delegate.openHelp(nil) } }
    }
}
