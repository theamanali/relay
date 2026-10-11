import Foundation
import SwiftUI
import Observation

/// Main-thread presentation state. Video frames never enter this model.
@MainActor @Observable
final class PickerModel {
    struct Row: Identifiable {
        let host: DiscoveredHost
        let paired: Bool
        let nickname: String?
        var id: String { host.name }
        var name: String { nickname ?? host.name }
        /// How the PC will be reached: "via Ethernet", or "This MacBook".
        var detail: String {
            let link = host.connectLink
            return link == "This MacBook" ? link : "via \(link)"
        }
        /// Facts about the PC only: what it advertises, then how we see it.
        /// A renamed host's real name lives here, not in the row.
        var hoverRows: [(label: String, value: String)] {
            var rows: [(label: String, value: String)] = []
            if nickname != nil { rows.append(("Name:", host.name)) }
            rows += host.facts.rows
            // One line per way the PC can be reached from here; the row's
            // subtitle already says which of these the connection takes.
            let reachable = host.reachableAddresses
            for entry in reachable {
                // The link only needs naming when there is more than one to tell apart.
                rows.append(("Host IP:", reachable.count > 1 ? "\(entry.address) (\(entry.link))" : entry.address))
            }
            if let key = host.publicKey { rows.append(("Key:", fingerprint(key))) }
            return rows
        }
    }

    static let sections: [PickerSection] = [.paired, .available]
    /// Windows' own limit on a computer name (NetBIOS); a nickname stands in
    /// for one, so it gets the same room and the row never has to truncate.
    static let maxNameLength = 15

    var rows: [Row] = []
    var selection: String?
    var connecting = false
    var status = ""
    var prefs = SessionPrefs()
    var mode = StreamMode(scale: 1, refresh: 60)
    var nativePixelSize = CGSize(width: 2, height: 2)
    var maxRefresh = 60
    var settingsPresented = false
    /// Which side of the gear the settings popover opens on.
    var settingsEdge: Edge = .trailing
    var renamingID: String?
    var renameDraft = ""
    var pinPrompt: PINPrompt?
    var notice: Notice?
    var forgetCandidate: Row?
    /// A paired PC about to be connected over Wi-Fi: the picker asks first.
    var wifiCandidate: Row?
    var pickerActive = true

    @ObservationIgnored var connect: (() -> Void)?
    /// Whether the screen has room for the settings popover to the right of
    /// the gear; HostPickerWindowController measures the window's screen.
    @ObservationIgnored var settingsFitsRight: () -> Bool = { true }

    /// Open settings to the right of the gear, or below it when the window
    /// sits too close to the screen's right edge. Chosen here because
    /// AppKit's own fallback for a popover would try the left side next.
    func showSettings() {
        settingsEdge = settingsFitsRight() ? .trailing : .bottom
        settingsPresented = true
    }
    /// Replaced in tests; Wi-Fi is decided from the Mac's live interfaces.
    @ObservationIgnored var connectsOverWiFi: (DiscoveredHost) -> Bool = { $0.connectsOverWiFi }
    /// The Wi-Fi alert's "do not show this message again".
    static let wifiWarningSuppressedKey = "SuppressWiFiConnectionWarning"

    /// Every Connect goes through here (button, Return, double-click,
    /// menus). Streaming over Wi-Fi works but is not the best link, so a
    /// paired PC reached that way gets a warning first, unless the user has
    /// turned it off. Cancel and Pair pass straight through.
    func requestConnect() {
        finishRename()
        if !connecting, let row = selected, row.paired, connectsOverWiFi(row.host),
           !UserDefaults.standard.bool(forKey: Self.wifiWarningSuppressedKey) {
            wifiCandidate = row
            return
        }
        connect?()
    }
    @ObservationIgnored var forget: ((DiscoveredHost) -> Void)?
    @ObservationIgnored var rename: ((DiscoveredHost, String) -> Void)?
    @ObservationIgnored var prefsChanged: ((SessionPrefs) -> Void)?
    @ObservationIgnored var modeChanged: ((StreamMode) -> Void)?
    @ObservationIgnored private var wanted: (key: Data?, name: String)?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    var selected: Row? { rows.first { $0.id == selection } }
    var canConfigure: Bool { selected?.paired == true && !connecting }
    var refreshRates: [Int] { StreamMode.refreshRates(max: maxRefresh) }
    /// Pair only for a selected available PC; Connect otherwise, as before SwiftUI.
    var connectTitle: String { connecting ? "Cancel" : selected?.paired == false ? "Pair" : "Connect" }
    /// What the list shows, top to bottom. Plain rows rather than Section
    /// headers (the list's own headers float on a band). Once any PC is known
    /// both sections are listed, each collapsible; with none at all the list
    /// is empty and the picker shows a centered empty state over it instead.
    enum ListItem: Identifiable {
        case title(PickerSection, collapsed: Bool, collapsible: Bool)
        case host(Row)
        /// Under Paired while nothing is paired.
        case noPaired
        /// Under Available while nothing unpaired is around; discovery goes on.
        case searching

        var id: String {
            switch self {
            case let .title(section, _, _): "title.\(section == .paired ? "paired" : "available")"
            // The section is part of a PC's identity: pairing removes it from
            // Available and inserts it under Paired rather than moving it
            // through the rows in between. Selection uses the row's tag.
            case let .host(row): "host.\(row.paired ? "paired" : "available").\(row.id)"
            case .noPaired: "no-paired"
            case .searching: "searching"
            }
        }

        /// The row's height, for the list's own (PickerLayout).
        var height: CGFloat {
            switch self {
            // Paired is always first; Available gets room above its title.
            case let .title(section, _, _): Style.sectionRowHeight + (section == .paired ? 0 : Style.Space.l)
            case .host, .searching: Style.rowHeight
            case .noPaired: Style.noteRowHeight
            }
        }
    }

    /// Sections the user folded away by clicking their titles.
    var collapsed: Set<PickerSection> = []

    /// Paired folds only once something is paired: "No paired devices yet"
    /// is not worth hiding. Available always folds.
    func canCollapse(_ section: PickerSection) -> Bool {
        section == .available || !pairedRows.isEmpty
    }

    var listItems: [ListItem] {
        guard !rows.isEmpty else { return [] }
        var items: [ListItem] = [.title(.paired, collapsed: collapsed.contains(.paired), collapsible: canCollapse(.paired))]
        if !collapsed.contains(.paired) {
            items += pairedRows.isEmpty ? [.noPaired] : pairedRows.map(ListItem.host)
        }
        items.append(.title(.available, collapsed: collapsed.contains(.available), collapsible: true))
        if !collapsed.contains(.available) {
            items += availableRows.isEmpty ? [.searching] : availableRows.map(ListItem.host)
        }
        return items
    }

    /// The PCs a user can see and so select, top to bottom.
    private var visibleRowIDs: [String] {
        listItems.compactMap { if case let .host(row) = $0 { row.id } else { nil } }
    }

    /// Fold or unfold a section. A selection folded away moves to the first
    /// PC still shown, so Connect never acts on a hidden row; unfolding with
    /// nothing selected selects the first PC, as the list does elsewhere.
    func toggle(_ section: PickerSection) {
        guard canCollapse(section) else { return }
        if collapsed.remove(section) == nil { collapsed.insert(section) }
        if selection.map({ !visibleRowIDs.contains($0) }) ?? true { selection = visibleRowIDs.first }
    }

    var pairedRows: [Row] { rows.filter(\.paired) }
    var availableRows: [Row] { rows.filter { !$0.paired } }
    private var rowsHeight: CGFloat { listItems.reduce(0) { $0 + $1.height } }
    var listHeight: CGFloat { PickerLayout.listHeight(rows: rowsHeight) }
    var listOverflows: Bool { PickerLayout.overflows(rows: rowsHeight) }

    /// "Native (3024 × 1964)", "75% (2268 × 1474)": the footer popup and the
    /// View menu say the same thing. Built as a plain string so SwiftUI does
    /// not group the digits.
    func resolutionTitle(_ scale: Double) -> String {
        let size = StreamMode.size(native: nativePixelSize, scale: scale)
        return "\(scale == 1 ? "Native" : "\(Int(scale * 100))%") (\(size.width) × \(size.height))"
    }


    func update(hosts: [DiscoveredHost], known: [Data: String], nicknames: [Data: String]) {
        let next = PickerRows.build(hosts: hosts, known: known, nicknames: nicknames).compactMap { row -> Row? in
            guard case let .host(host, state, nickname) = row else { return nil }
            return Row(host: host, paired: state == .paired, nickname: nickname)
        }
        if let editing = renamingID, !next.contains(where: { $0.id == editing }) { finishRename() }
        rows = next
        if pairedRows.isEmpty { collapsed.remove(.paired) }
        if let wanted, let row = rows.first(where: { ($0.host.publicKey != nil && $0.host.publicKey == wanted.key) || $0.id == wanted.name }) {
            reveal(row)
            self.wanted = nil
        } else if let selection, !visibleRowIDs.contains(selection) {
            self.selection = visibleRowIDs.first
        } else if selection == nil {
            selection = visibleRowIDs.first
        }
    }

    func preselect(key: Data?, name: String) {
        wanted = (key, name)
        if let row = rows.first(where: { ($0.host.publicKey != nil && $0.host.publicKey == key) || $0.id == name }) {
            reveal(row)
            wanted = nil
        }
    }

    /// Select a row, unfolding its section if it was folded away.
    private func reveal(_ row: Row) {
        collapsed.remove(row.paired ? .paired : .available)
        selection = row.id
    }

    func configure(native: CGSize, maxRefresh: Int, initial: StreamMode?) {
        nativePixelSize = native
        self.maxRefresh = maxRefresh
        mode = (initial ?? mode).clamped(toMaxRefresh: maxRefresh)
    }

    func setMode(_ value: StreamMode) {
        mode = value.clamped(toMaxRefresh: maxRefresh)
        modeChanged?(mode)
    }

    func setPrefs(_ value: SessionPrefs) {
        prefs = value
        prefs.bitrateMbps = VideoBitrate.clamp(prefs.bitrateMbps)
        prefsChanged?(prefs)
    }

    func flash(_ message: String, seconds: TimeInterval = 8) {
        flashTask?.cancel()
        status = message
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.status == message else { return }
            self?.status = ""
        }
    }

    func beginRename(_ row: Row? = nil) {
        guard let row = row ?? selected, row.host.publicKey != nil, !connecting else { return }
        finishRename()
        selection = row.id
        renameDraft = row.name
        renamingID = row.id
    }

    func finishRename(cancel: Bool = false) {
        guard let id = renamingID else { return }
        let row = rows.first { $0.id == id }
        let draft = renameDraft
        renamingID = nil
        if !cancel, let row { rename?(row.host, draft) }
    }

    func revertName() {
        guard let row = selected, row.nickname != nil else { return }
        finishRename(cancel: true)
        rename?(row.host, row.host.name)
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}

/// Each prompt is a one-shot answer to one connection attempt.
@MainActor @Observable
final class PINPrompt: Identifiable {
    let id = UUID()
    let host: String
    let explanation: String
    var code = ""
    @ObservationIgnored private var answer: ((String?) -> Void)?

    init(host: String, explanation: String, answer: @escaping (String?) -> Void) {
        self.host = host
        self.explanation = explanation
        self.answer = answer
    }

    static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0 >= "0" && $0 <= "9" }.prefix(6))
    }

    func respond(_ value: String?) {
        guard let answer else { return }
        self.answer = nil
        answer(value)
    }

    /// The socket ended; dismissing the sheet must not cancel a newer attempt.
    func invalidate() { answer = nil }
}
