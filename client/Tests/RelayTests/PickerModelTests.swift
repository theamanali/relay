import Network
import XCTest
@testable import Relay

final class PickerModelTests: XCTestCase {
    private func host(_ name: String, key: UInt8) -> DiscoveredHost {
        DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                       interfaces: [], publicKey: Data(repeating: key, count: 32))
    }

    @MainActor func testSelectionSurvivesPairingAndDiscoveryChanges() async {
        let model = PickerModel()
        let a = host("A", key: 1), b = host("B", key: 2)
        model.preselect(key: b.publicKey, name: b.name)
        model.update(hosts: [a, b], known: [:], nicknames: [:])
        XCTAssertEqual(model.selection, "B")
        XCTAssertEqual(model.connectTitle, "Pair")
        model.update(hosts: [b, a], known: [b.publicKey!: "B"], nicknames: [:])
        XCTAssertEqual(model.selection, "B")
        XCTAssertEqual(model.connectTitle, "Connect")
        model.connecting = true
        XCTAssertEqual(model.connectTitle, "Cancel")
        XCTAssertFalse(model.canConfigure)
        model.update(hosts: [a], known: [:], nicknames: [:])
        XCTAssertEqual(model.selection, "A")
    }

    @MainActor func testRenameSurvivesUpdatesAndCommitsOnlyOnce() async {
        let model = PickerModel(), pc = host("PC", key: 1)
        var edits: [String] = []
        model.rename = { _, name in edits.append(name) }
        model.update(hosts: [pc], known: [:], nicknames: [:])
        model.beginRename()
        model.renameDraft = "My PC"
        model.update(hosts: [pc], known: [:], nicknames: [:])
        XCTAssertEqual(model.renameDraft, "My PC")
        model.finishRename()
        model.finishRename() // field-focus callback after Return
        XCTAssertEqual(edits, ["My PC"])
        model.beginRename()
        model.renameDraft = "Cancelled"
        model.finishRename(cancel: true)
        XCTAssertEqual(edits, ["My PC"])
        model.beginRename()
        model.renameDraft = "Last name"
        model.update(hosts: [], known: [:], nicknames: [:])
        XCTAssertEqual(edits, ["My PC", "Last name"])
    }

    @MainActor func testPINCompletionIsOneShotAndDeadAttemptCannotAnswer() async {
        var answers: [String?] = []
        let prompt = PINPrompt(host: "PC", explanation: "") { answers.append($0) }
        prompt.respond("123456")
        prompt.respond(nil) // dismissal must not cancel after submission
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0], "123456")
        let old = PINPrompt(host: "PC", explanation: "") { answers.append($0) }
        old.invalidate()
        old.respond("654321")
        old.respond(nil)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(PINPrompt.digits("12 ٣4a56789"), "124567")
    }

    @MainActor func testScreenRefreshClampPreservesNativeResolution() async {
        let model = PickerModel()
        model.configure(native: CGSize(width: 2560, height: 1664), maxRefresh: 60,
                        initial: StreamMode(scale: 1, refresh: 120))
        XCTAssertEqual(model.mode, StreamMode(scale: 1, refresh: 60))
        XCTAssertEqual(model.refreshRates, [60])
    }

    func testResetInvalidatesQueuedFrameNotifications() throws {
        let renderer = try VideoRenderer()
        XCTAssertTrue(renderer.isCurrent(generation: 0))
        renderer.reset()
        XCTAssertFalse(renderer.isCurrent(generation: 0))
    }

    @MainActor func testResolutionTitlesAreNotDigitGrouped() async {
        let model = PickerModel()
        model.configure(native: CGSize(width: 3024, height: 1964), maxRefresh: 120, initial: nil)
        XCTAssertEqual(model.resolutionTitle(1), "Native (3024 × 1964)")
        XCTAssertEqual(model.resolutionTitle(0.75), "75% (2268 × 1474)")
    }

    @MainActor func testRowDetailAndHoverCard() async {
        var pc = host("DESKTOP-1", key: 7)
        pc.facts.cpu = "Ryzen"
        let row = PickerModel.Row(host: pc, paired: true, nickname: "Desk")
        XCTAssertEqual(row.name, "Desk")
        XCTAssertEqual(row.detail, "This MacBook") // seen on no interface
        let labels = row.hoverRows.map(\.label)
        XCTAssertEqual(labels.first, "Name:") // the PC's own name, since the row shows the nickname
        XCTAssertTrue(labels.contains("CPU:"))
        XCTAssertEqual(labels.last, "Key:")
        XCTAssertFalse(PickerModel.Row(host: pc, paired: true, nickname: nil).hoverRows.contains { $0.label == "Name:" })
    }

    @MainActor func testListItemsKeepTitlesStableAndReinsertPairedPCs() async {
        let model = PickerModel()
        let a = host("A", key: 1), b = host("B", key: 2)
        // Nothing yet: no titles at all; the picker's empty state covers the list.
        XCTAssertEqual(model.listItems.map(\.id), [])
        model.update(hosts: [a, b], known: [:], nicknames: [:])
        XCTAssertEqual(model.listItems.map(\.id), ["title.available", "host.available.A", "host.available.B"])
        // B pairs: it leaves Available and appears under a new Paired title
        // (a new ID, so a fade out and an insert rather than a move through
        // A), and the titles keep their IDs so they slide rather than fade
        // through each other. B stays selected through its tag.
        model.selection = "B"
        model.update(hosts: [a, b], known: [b.publicKey!: "B"], nicknames: [:])
        XCTAssertEqual(model.listItems.map(\.id), ["title.paired", "host.paired.B", "title.available", "host.available.A"])
        XCTAssertEqual(model.selection, "B")
        let firsts = model.listItems.compactMap { item -> Bool? in
            if case let .title(_, first) = item { return first } else { return nil }
        }
        XCTAssertEqual(firsts, [true, false]) // only the top title skips the gap
    }

    func testListIsAsTallAsItsRowsThenScrollsWithAPeek() {
        let row = Style.rowHeight, title = Style.sectionRowHeight, insets = PickerLayout.listInsets
        // Empty: the empty state, held at the two-row floor.
        let floor = insets + title + 2 * row
        XCTAssertEqual(PickerLayout.listHeight(paired: 0, available: 0), floor)
        // One paired PC and nothing available: both titles and the PC, under the floor.
        XCTAssertEqual(PickerLayout.listHeight(paired: 1, available: 0), floor)
        XCTAssertEqual(PickerLayout.listHeight(paired: 1, available: 2), insets + 2 * title + Style.Space.l + 3 * row)
        // Five PCs still fit exactly.
        let five = insets + 2 * title + Style.Space.l + 5 * row
        XCTAssertEqual(PickerLayout.listHeight(paired: 2, available: 3), five)
        XCTAssertFalse(PickerLayout.overflows(paired: 2, available: 3))
        // Past that the list scrolls, half a row taller so a partly shown row
        // says there is more below.
        XCTAssertEqual(PickerLayout.listHeight(paired: 2, available: 4), five + row / 2)
        XCTAssertTrue(PickerLayout.overflows(paired: 2, available: 4))
        XCTAssertEqual(PickerLayout.listHeight(paired: 3, available: 5), five + row / 2)
        // Six available and nothing paired: one title fewer, so all six fit.
        XCTAssertFalse(PickerLayout.overflows(paired: 0, available: 6))
    }

    @MainActor func testFooterButtonSaysPairOnlyForAnAvailablePC() async {
        let model = PickerModel()
        XCTAssertEqual(model.connectTitle, "Connect") // nothing selected
        let a = host("A", key: 1)
        model.update(hosts: [a], known: [:], nicknames: [:])
        XCTAssertEqual(model.connectTitle, "Pair")
    }

    @MainActor func testWiFiConnectAsksFirstUnlessSuppressed() async {
        let key = PickerModel.wifiWarningSuppressedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)

        let model = PickerModel()
        var connects = 0
        model.connect = { connects += 1 }
        var overWiFi = true
        model.connectsOverWiFi = { _ in overWiFi }
        let paired = host("Desk", key: 1), available = host("New", key: 2)
        model.update(hosts: [paired, available], known: [paired.publicKey!: "Desk"], nicknames: [:])

        // Paired over Wi-Fi: the alert, no connection yet.
        model.selection = "Desk"
        model.requestConnect()
        XCTAssertEqual(model.wifiCandidate?.id, "Desk")
        XCTAssertEqual(connects, 0)
        model.wifiCandidate = nil

        // Pairing an available PC streams nothing: no warning.
        model.selection = "New"
        model.requestConnect()
        XCTAssertNil(model.wifiCandidate)
        XCTAssertEqual(connects, 1)

        // Over a cable: straight through.
        overWiFi = false
        model.selection = "Desk"
        model.requestConnect()
        XCTAssertNil(model.wifiCandidate)
        XCTAssertEqual(connects, 2)

        // Cancel while connecting is never held up.
        overWiFi = true
        model.connecting = true
        model.requestConnect()
        XCTAssertNil(model.wifiCandidate)
        XCTAssertEqual(connects, 3)
        model.connecting = false

        // "Do not show this message again".
        UserDefaults.standard.set(true, forKey: key)
        model.requestConnect()
        XCTAssertNil(model.wifiCandidate)
        XCTAssertEqual(connects, 4)
    }
}
