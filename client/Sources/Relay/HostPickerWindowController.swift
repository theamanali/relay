import AppKit
import SwiftUI

@MainActor
protocol HostPickerDelegate: AnyObject {
    func picker(_ p: HostPickerWindowController, didChoose host: DiscoveredHost)
    /// The user wants to drop the pairing with this host (context menu / Delete).
    func picker(_ p: HostPickerWindowController, forget host: DiscoveredHost)
    /// The user gave this host a nickname; empty means "use the PC's own name".
    func picker(_ p: HostPickerWindowController, rename host: DiscoveredHost, to name: String)
    /// Cancel pressed while a connection started from this picker is still in progress.
    func pickerDidCancelConnect(_ p: HostPickerWindowController)
}

/// Window/responder adapter; all picker content and state belong to SwiftUI.
@MainActor
final class HostPickerWindowController: NSWindowController {
    let model: PickerModel
    weak var pickerDelegate: HostPickerDelegate?
    private var hosts: [DiscoveredHost] = []
    var onPrefsChange: ((SessionPrefs) -> Void)?
    var onModeChange: ((StreamMode) -> Void)?
    var prefs: SessionPrefs { get { model.prefs } set { model.prefs = newValue } }
    var mode: StreamMode { get { model.mode } set { model.mode = newValue } }
    var connecting: Bool { get { model.connecting } set { model.connecting = newValue } }
    var status: String { get { model.status } set { model.status = newValue } }
    var offeredRefreshRates: [Int] { model.refreshRates }

    init(window: NSWindow, model: PickerModel) {
        self.model = model
        super.init(window: window)
        model.connect = { [weak self] in self?.connectSelected(nil) }
        model.forget = { [weak self] host in
            guard let self else { return }
            self.pickerDelegate?.picker(self, forget: host)
        }
        model.rename = { [weak self] host, name in
            guard let self else { return }
            self.pickerDelegate?.picker(self, rename: host, to: name)
        }
        model.prefsChanged = { [weak self] prefs in self?.onPrefsChange?(prefs) }
        model.modeChanged = { [weak self] mode in self?.onModeChange?(mode) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(nativePixelSize: CGSize, maxRefresh: Int, initial: StreamMode? = nil) {
        model.configure(native: nativePixelSize, maxRefresh: maxRefresh, initial: initial)
    }
    func update(hosts: [DiscoveredHost]) {
        // A result in the footer gives way once the list of PCs changes.
        if hosts.map(\.name) != self.hosts.map(\.name) { status = "" }
        self.hosts = hosts
        reloadPairing()
    }
    /// Animated so the list's height, and with it the window's, eases to the
    /// new size; the rows themselves update in place (HostList).
    func reloadPairing() {
        let (known, nicknames) = (ClientState.knownHosts(), ClientState.nicknames())
        withAnimation(.easeInOut(duration: 0.25)) {
            model.update(hosts: hosts, known: known, nicknames: nicknames)
        }
    }
    func preselect(key: Data?, name: String) { model.preselect(key: key, name: name) }
    func flash(_ message: String, for seconds: TimeInterval = 8) { model.flash(message, seconds: seconds) }

    @objc func connectSelected(_ sender: Any?) {
        if connecting { pickerDelegate?.pickerDidCancelConnect(self) }
        else if let row = model.selected { pickerDelegate?.picker(self, didChoose: row.host) }
    }
}
