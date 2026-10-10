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
        let prompt = PINPrompt(host: "PC", fingerprint: "test", explanation: "") { answers.append($0) }
        prompt.respond("123456")
        prompt.respond(nil) // dismissal must not cancel after submission
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0], "123456")
        let old = PINPrompt(host: "PC", fingerprint: "test", explanation: "") { answers.append($0) }
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
}
