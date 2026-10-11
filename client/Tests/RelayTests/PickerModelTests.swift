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
        // Only available PCs: Paired stays, saying nothing is paired yet.
        model.update(hosts: [a, b], known: [:], nicknames: [:])
        XCTAssertEqual(model.listItems.map(\.id),
                       ["title.paired", "no-paired", "title.available", "host.available.A", "host.available.B"])
        // B pairs: it leaves Available and appears under Paired (a new ID, so
        // no move through A), and B stays selected through its tag.
        model.selection = "B"
        model.update(hosts: [a, b], known: [b.publicKey!: "B"], nicknames: [:])
        XCTAssertEqual(model.listItems.map(\.id), ["title.paired", "host.paired.B", "title.available", "host.available.A"])
        XCTAssertEqual(model.selection, "B")
        // Everything paired: Available stays, with its searching row.
        model.update(hosts: [a, b], known: [a.publicKey!: "A", b.publicKey!: "B"], nicknames: [:])
        XCTAssertEqual(model.listItems.map(\.id), ["title.paired", "host.paired.A", "host.paired.B", "title.available", "searching"])
    }

    @MainActor func testCollapsingHidesASectionAndMovesTheSelectionOut() async {
        let model = PickerModel()
        let a = host("A", key: 1), b = host("B", key: 2)
        model.update(hosts: [a, b], known: [b.publicKey!: "B"], nicknames: [:])
        model.selection = "B"
        // Folding Paired hides B, so the selection moves to the first PC shown.
        model.toggle(.paired)
        XCTAssertEqual(model.listItems.map(\.id), ["title.paired", "title.available", "host.available.A"])
        XCTAssertEqual(model.selection, "A")
        // Folding Available too leaves nothing to select.
        model.toggle(.available)
        XCTAssertEqual(model.listItems.map(\.id), ["title.paired", "title.available"])
        XCTAssertNil(model.selection)
        // Unfolding with nothing selected selects the first PC shown.
        model.toggle(.available)
        XCTAssertEqual(model.selection, "A")
        model.toggle(.available)
        XCTAssertNil(model.selection)
        // A PC asked for after a session unfolds its section.
        model.preselect(key: b.publicKey, name: "B")
        XCTAssertEqual(model.selection, "B")
        XCTAssertFalse(model.collapsed.contains(.paired))
        model.toggle(.available)
        XCTAssertEqual(model.listItems.map(\.id), ["title.paired", "host.paired.B", "title.available", "host.available.A"])
    }

    func testListIsAsTallAsItsRowsThenScrollsWithAPeek() {
        let row = Style.rowHeight, title = Style.sectionRowHeight, insets = PickerLayout.listInsets
        let titles = 2 * title + Style.Space.l
        // Empty: the empty state, held at the two-row floor.
        let floor = insets + title + 2 * row
        XCTAssertEqual(PickerLayout.listHeight(rows: 0), floor)
        // Both titles, "No paired devices yet" and one available PC.
        XCTAssertEqual(PickerLayout.listHeight(rows: titles + Style.noteRowHeight + row), insets + titles + Style.noteRowHeight + row)
        // Five PCs under both titles still fit exactly.
        let five = titles + 5 * row
        XCTAssertEqual(PickerLayout.listHeight(rows: five), insets + five)
        XCTAssertFalse(PickerLayout.overflows(rows: five))
        // Past that the list scrolls, half a row taller so a partly shown row
        // says there is more below.
        XCTAssertEqual(PickerLayout.listHeight(rows: five + row), insets + five + row / 2)
        XCTAssertTrue(PickerLayout.overflows(rows: five + row))
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

    @MainActor func testPairedFoldsOnlyOnceSomethingIsPaired() async {
        let model = PickerModel()
        let a = host("A", key: 1), b = host("B", key: 2)
        model.update(hosts: [a, b], known: [:], nicknames: [:])
        // Nothing paired: Paired cannot fold, and toggling it does nothing.
        XCTAssertFalse(model.canCollapse(.paired))
        model.toggle(.paired)
        XCTAssertEqual(model.listItems.map(\.id).prefix(2), ["title.paired", "no-paired"])
        // Paired with B, folded, then B forgotten: Paired opens again to say
        // nothing is paired, and stays open when the next PC pairs.
        model.update(hosts: [a, b], known: [b.publicKey!: "B"], nicknames: [:])
        XCTAssertTrue(model.canCollapse(.paired))
        model.toggle(.paired)
        XCTAssertTrue(model.collapsed.contains(.paired))
        model.update(hosts: [a, b], known: [:], nicknames: [:])
        XCTAssertFalse(model.collapsed.contains(.paired))
        XCTAssertEqual(model.listItems.map(\.id).prefix(2), ["title.paired", "no-paired"])
        model.update(hosts: [a, b], known: [a.publicKey!: "A"], nicknames: [:])
        XCTAssertEqual(model.listItems.map(\.id).prefix(2), ["title.paired", "host.paired.A"])
    }

    @MainActor func testSettingsOpenRightThenBelow() async {
        let model = PickerModel()
        var room = true
        model.settingsFitsRight = { room }
        model.showSettings()
        XCTAssertTrue(model.settingsPresented)
        XCTAssertEqual(model.settingsEdge, .trailing)
        model.settingsPresented = false
        room = false // window against the screen's right edge
        model.showSettings()
        XCTAssertEqual(model.settingsEdge, .bottom)
    }
    /// A model whose last PC is "Desk" (key 1), with the setting on.
    @MainActor private func autoConnectModel(connects: @escaping () -> Void) -> PickerModel {
        let model = PickerModel()
        model.connect = connects
        model.connectsOverWiFi = { _ in false }
        model.prefs.connectAtLaunch = true
        model.lastHostKey = Data(repeating: 1, count: 32)
        return model
    }

    @MainActor func testConnectsToTheLastPCOnceItIsFoundPaired() async {
        var connects = 0
        let model = autoConnectModel { connects += 1 }
        let desk = host("Desk", key: 1), other = host("Other", key: 2)
        // Only another PC so far, then Desk as available: nothing yet.
        model.update(hosts: [other], known: [other.publicKey!: "Other"], nicknames: [:])
        model.update(hosts: [other, desk], known: [other.publicKey!: "Other"], nicknames: [:])
        XCTAssertEqual(connects, 0)
        // Desk paired: selected (its section unfolded) and connected, once.
        model.collapsed.insert(.paired)
        let known = [desk.publicKey!: "Desk", other.publicKey!: "Other"]
        model.update(hosts: [other, desk], known: known, nicknames: [:])
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(model.selection, "Desk")
        XCTAssertFalse(model.collapsed.contains(.paired))
        XCTAssertFalse(model.autoConnectArmed)
        model.update(hosts: [desk], known: known, nicknames: [:])
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(model.lastHostName, "Desk")
    }

    @MainActor func testConnectAtLaunchWaitsOrStaysOff() async {
        var connects = 0
        let desk = host("Desk", key: 1)
        let known = [desk.publicKey!: "Desk"]

        // Setting off.
        let off = autoConnectModel { connects += 1 }
        off.prefs.connectAtLaunch = false
        off.update(hosts: [desk], known: known, nicknames: [:])
        XCTAssertEqual(connects, 0)

        // Another app in front: waits for the window to become key.
        let background = autoConnectModel { connects += 1 }
        var key = false
        background.isPickerKey = { key }
        background.update(hosts: [desk], known: known, nicknames: [:])
        XCTAssertEqual(connects, 0)
        key = true
        background.autoConnectIfReady()
        XCTAssertEqual(connects, 1)

        // Already connecting (or a PIN sheet up): left alone.
        let busy = autoConnectModel { connects += 1 }
        busy.connecting = true
        busy.update(hosts: [desk], known: known, nicknames: [:])
        XCTAssertEqual(connects, 1)
        XCTAssertTrue(busy.autoConnectArmed)
    }

    @MainActor func testAnyPickerActionCancelsConnectAtLaunch() async {
        var connects = 0
        let desk = host("Desk", key: 1), other = host("Other", key: 2)
        let known = [desk.publicKey!: "Desk", other.publicKey!: "Other"]
        for action in [
            { (m: PickerModel) in m.showSettings() },
            { (m: PickerModel) in m.toggle(.available) },
            { (m: PickerModel) in m.beginRename() },
            { (m: PickerModel) in m.forgetCandidate = m.selected },
        ] {
            let model = autoConnectModel { connects += 1 }
            model.update(hosts: [other], known: known, nicknames: [:])
            action(model)
            model.finishRename(cancel: true)
            model.forgetCandidate = nil
            model.update(hosts: [other, desk], known: known, nicknames: [:])
        }
        XCTAssertEqual(connects, 0)
        // A connect the user asked for is the one connect.
        let model = autoConnectModel { connects += 1 }
        model.update(hosts: [other], known: known, nicknames: [:])
        model.requestConnect()
        model.update(hosts: [other, desk], known: known, nicknames: [:])
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(model.selection, "Other")
    }

    @MainActor func testConnectAtLaunchStillWarnsAboutWiFi() async {
        let key = PickerModel.wifiWarningSuppressedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        var connects = 0
        let model = autoConnectModel { connects += 1 }
        model.connectsOverWiFi = { _ in true }
        let desk = host("Desk", key: 1)
        model.update(hosts: [desk], known: [desk.publicKey!: "Desk"], nicknames: [:])
        XCTAssertEqual(model.wifiCandidate?.id, "Desk")
        XCTAssertEqual(connects, 0)
    }
}
