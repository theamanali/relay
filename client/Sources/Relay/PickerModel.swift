import Foundation
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
    }

    var rows: [Row] = []
    var selection: String?
    var connecting = false
    var status = ""
    var prefs = SessionPrefs()
    var mode = StreamMode(scale: 1, refresh: 60)
    var nativePixelSize = CGSize(width: 2, height: 2)
    var maxRefresh = 60
    var settingsPresented = false
    var renamingID: String?
    var renameDraft = ""
    var pinPrompt: PINPrompt?
    var notice: Notice?
    var forgetCandidate: Row?
    var pickerActive = true

    @ObservationIgnored var connect: (() -> Void)?
    @ObservationIgnored var forget: ((DiscoveredHost) -> Void)?
    @ObservationIgnored var rename: ((DiscoveredHost, String) -> Void)?
    @ObservationIgnored var prefsChanged: ((SessionPrefs) -> Void)?
    @ObservationIgnored var modeChanged: ((StreamMode) -> Void)?
    @ObservationIgnored private var wanted: (key: Data?, name: String)?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    var selected: Row? { rows.first { $0.id == selection } }
    var canConfigure: Bool { selected?.paired == true && !connecting }
    var refreshRates: [Int] { StreamMode.refreshRates(max: maxRefresh) }
    var connectTitle: String { connecting ? "Cancel" : selected?.paired == true ? "Connect" : "Pair" }
    var footer: String { status.isEmpty ? (rows.isEmpty ? "" : "\(rows.count) PC\(rows.count == 1 ? "" : "s") found") : status }

    func update(hosts: [DiscoveredHost], known: [Data: String], nicknames: [Data: String]) {
        let next = PickerRows.build(hosts: hosts, known: known, nicknames: nicknames).compactMap { row -> Row? in
            guard case let .host(host, state, nickname) = row else { return nil }
            return Row(host: host, paired: state == .paired, nickname: nickname)
        }
        if let editing = renamingID, !next.contains(where: { $0.id == editing }) { finishRename() }
        rows = next
        if let wanted, let row = rows.first(where: { ($0.host.publicKey != nil && $0.host.publicKey == wanted.key) || $0.id == wanted.name }) {
            selection = row.id
            self.wanted = nil
        } else if !rows.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        }
    }

    func preselect(key: Data?, name: String) {
        wanted = (key, name)
        if let row = rows.first(where: { ($0.host.publicKey != nil && $0.host.publicKey == key) || $0.id == name }) {
            selection = row.id
            wanted = nil
        }
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
    let fingerprint: String
    let explanation: String
    var code = ""
    @ObservationIgnored private var answer: ((String?) -> Void)?

    init(host: String, fingerprint: String, explanation: String, answer: @escaping (String?) -> Void) {
        self.host = host
        self.fingerprint = fingerprint
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
