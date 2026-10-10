// Invoked by Tools/test-pair-name.sh. Real HostConnection + fakehost over TCP.
// Foundation's fixed test home isolates identity and pairings without changing
// the production state code. Fail before constructing any client if absent.
import CoreMedia
import CryptoKit
import Foundation
import Network

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

final class Delegate: HostConnectionDelegate {
    let ended = DispatchSemaphore(value: 0)
    var reason = ""
    var prompted = false
    func connection(_ c: HostConnection, didChangeStatus status: String) {}
    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping @Sendable (String?) -> Void) {
        prompted = true
        completion(nil)
    }
    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {}
    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {}
    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime) {}
    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming) {}
    func connectionDidEnd(_ c: HostConnection, reason: String) {
        self.reason = reason
        ended.signal()
    }
}

final class FakeHost {
    let process = Process()
    let logURL: URL
    let directory: URL
    let output: FileHandle
    let port: NWEndpoint.Port

    init(root: URL, label: String, arguments: [String]) throws {
        directory = root.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("host.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        output = try FileHandle(forWritingTo: logURL)
        process.executableURL = root.appendingPathComponent("fakehost")
        process.arguments = ["0"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        var chosenPort: NWEndpoint.Port?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && process.isRunning {
            if let line = (try? String(contentsOf: logURL, encoding: .utf8))?.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("listening on ") }),
               let field = line.split(separator: " ").dropFirst(2).first,
               let value = UInt16(field.trimmingCharacters(in: CharacterSet(charactersIn: ","))) {
                chosenPort = NWEndpoint.Port(rawValue: value)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let chosenPort else {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? output.close()
            throw CheckFailure(description: "\(label): fakehost failed to listen: \((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")")
        }
        port = chosenPort
    }

    var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
    var key: Data {
        get throws {
            let raw = try Data(contentsOf: directory.appendingPathComponent("fakehost.key"))
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation
        }
    }
    func waitForLog(_ text: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if log.contains(text) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CheckFailure(description: "missing '\(text)' in fakehost log:\n\(log)")
    }
    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? output.close()
    }
}

func connect(_ host: FakeHost, name: String = "Aman’s MacBook Pro", pin: String? = "000000",
             pairOnly: Bool = true, verifyOnly: Bool = false, unpairOnly: Bool = false) throws -> (HostConnection, Delegate) {
    var options = HostConnection.Options(endpoint: .hostPort(host: "127.0.0.1", port: host.port))
    options.expectedHostKey = try host.key
    options.clientName = name
    options.pin = pin
    options.pairOnly = pairOnly
    options.verifyOnly = verifyOnly
    options.unpairOnly = unpairOnly
    options.dialTimeout = 5
    let client = try HostConnection(options: options)
    let delegate = Delegate()
    client.delegate = delegate
    client.start()
    let completed = delegate.ended.wait(timeout: .now() + 10) == .success
    client.stop()
    client.queue.sync {} // finish callbacks and cancellation before inspecting state
    try check(completed, "HostConnection timed out:\n\(host.log)")
    return (client, delegate)
}

// Shared only between the callback and test thread; every access takes the lock.
final class TaskResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var outcome: Value?
    func record(_ result: Value) { lock.withLock { calls += 1; outcome = result } }
    func snapshot() -> (Int, Value?) { lock.withLock { (calls, outcome) } }
}

func unpair(_ host: FakeHost, timeout: Double = 5, expectedKey: Data? = nil) throws -> UnpairTask.Outcome {
    var options = HostConnection.Options(endpoint: .hostPort(host: "127.0.0.1", port: host.port))
    options.expectedHostKey = try expectedKey ?? host.key
    let task = try UnpairTask(options: options)
    defer { withExtendedLifetime(task) {} }
    let ended = DispatchSemaphore(value: 0)
    let state = TaskResult<UnpairTask.Outcome>()
    task.run(timeout: timeout) { result in
        state.record(result)
        ended.signal()
    }
    try check(ended.wait(timeout: .now() + 10) == .success, "UnpairTask did not complete")
    // Host closure proves the timed-out connection was canceled too.
    try host.waitForLog("-- closed")
    let (total, result) = state.snapshot()
    try check(total == 1, "UnpairTask completed more than once")
    return result!
}

func verify(_ host: FakeHost, timeout: Double) throws -> VerifyTask.Outcome {
    var options = HostConnection.Options(endpoint: .hostPort(host: "127.0.0.1", port: host.port))
    options.expectedHostKey = try host.key
    let task = try VerifyTask(options: options)
    defer { withExtendedLifetime(task) {} }
    let ended = DispatchSemaphore(value: 0)
    let state = TaskResult<VerifyTask.Outcome>()
    task.run(timeout: timeout) { result in state.record(result); ended.signal() }
    try check(ended.wait(timeout: .now() + 10) == .success, "VerifyTask did not complete")
    try host.waitForLog("-- closed")
    // Let the canceled deadline expire too: it must not deliver a second result.
    Thread.sleep(forTimeInterval: timeout + 0.1)
    let (count, result) = state.snapshot()
    try check(count == 1, "VerifyTask delivered both timeout and response")
    return result!
}

func run(_ root: URL) throws {
    let fm = FileManager.default
    guard let fixedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
        throw CheckFailure(description: "run through Tools/test-pair-name.sh for isolated state")
    }
    let expected = URL(fileURLWithPath: fixedHome).appendingPathComponent("Library/Application Support").resolvingSymlinksInPath()
    let actual = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.resolvingSymlinksInPath()
    try check(actual.path == expected.path && expected.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              "Foundation did not honor the isolated test home: expected \(expected.path), got \(actual.path)")

    for (label, args) in [("verify-paired", ["accept", "--paired"]),
                          ("verify-forgotten", ["accept"]),
                          ("verify-timeout", ["accept", "--paired", "--ignore-hello"])] {
        let host = try FakeHost(root: root, label: label, arguments: args)
        defer { host.stop() }
        let result = try verify(host, timeout: 0.5)
        switch (label, result) {
        case ("verify-paired", .paired), ("verify-forgotten", .forgotten), ("verify-timeout", .unreachable): break
        default: throw CheckFailure(description: "unexpected VerifyTask result for \(label)")
        }
        try check(!host.log.contains("CLIENT_HELLO") && !host.log.contains("first message 0x81"),
                  "VerifyTask requested a streaming display")
        print("PASS \(label): real VerifyTask, one completion, no CLIENT_HELLO")
    }

    for (label, arguments, name, stored) in [
        ("named", ["accept"], "Aman’s MacBook Pro", "Aman’s MacBook Pro"),
        ("legacy", ["accept", "--legacy-pair"], "Aman’s MacBook Pro", "Paired MacBook"),
        ("busy", ["busy"], "Aman’s MacBook Pro", "Aman’s MacBook Pro"),
        ("empty", ["accept"], "", "Paired MacBook"),
        ("unicode", ["accept"], String(repeating: "界", count: 86), String(repeating: "界", count: 85)),
        ("controls", ["accept"], " \nAman\tMac\0 ", "Aman Mac"),
        ("emoji", ["accept"], "Family 👨‍👩‍👧‍👦 Mac", "Family 👨‍👩‍👧‍👦 Mac"),
    ] {
        let host = try FakeHost(root: root, label: label, arguments: arguments)
        defer { host.stop() }
        let (client, delegate) = try connect(host, name: name)
        try check(client.pairingCompleted && delegate.reason == "paired", "\(label): \(delegate.reason)")
        try check(ClientState.knownHosts()[try host.key] == "Fake PC", "\(label): client did not store pairing")
        try host.waitForLog("pair-only client closed without requesting the display")
        try check(host.log.contains("confirmed peer name: \(stored)\n"), "\(label): wrong peer name:\n\(host.log)")
        let storedAt = host.log.range(of: "confirmed peer name:")!.lowerBound
        let successAt = host.log.range(of: "PAIR_RESULT paired")!.lowerBound
        try check(storedAt < successAt, "\(label): name committed after success")
        try check(!host.log.contains("0x81") && !host.log.contains("CLIENT_HELLO"), "\(label): pair-only requested streaming")
        try check(host.log.contains("first message 0xa0 (\(label == "legacy" ? 32 : 32 + Proto.pairNameAD(name).count) bytes)"),
                  "\(label): wrong PAIR layout")
        print("PASS \(label): paired, named before success, no CLIENT_HELLO")

        if label == "named" {
            let before = host.log.components(separatedBy: "first message 0xa0").count
            let (known, knownDelegate) = try connect(host, pin: nil)
            try check(known.pairingCompleted && knownDelegate.reason == "already paired" && !knownDelegate.prompted,
                      "already-paired path asked for a PIN")
            let (verified, _) = try connect(host, verifyOnly: true)
            try check(verified.pairingVerified == true, "verify-only failed")
            try check(host.log.components(separatedBy: "first message 0xa0").count == before,
                      "known/verify-only sent PAIR")
            guard case .confirmed = try unpair(host) else { throw CheckFailure(description: "UNPAIR failed") }
            // The picker/UnpairTask owns local forgetting after the reply;
            // HostConnection only reports that the host confirmed it.
            ClientState.forget(host: try host.key)
            print("PASS already-paired, verify-only and UNPAIR")
        }
    }

    for (label, arguments, expectedKey) in [
        ("unpair-busy", ["busy"], Optional<Data>.none),
        ("unpair-timeout", ["accept", "--ignore-unpair"], nil),
        ("unpair-key-change", ["accept"], Data(repeating: 9, count: 32)),
    ] {
        let host = try FakeHost(root: root, label: label, arguments: arguments)
        defer { host.stop() }
        let outcome = try unpair(host, timeout: 0.5, expectedKey: expectedKey)
        switch (label, outcome) {
        case ("unpair-busy", .confirmed): break
        case ("unpair-timeout", .unreachable(let reason)):
            try check(reason == "the PC didn't answer", "Forget lost timeout reason")
            try check(host.log.contains("withholding confirmation"), "Forget timed out before sending UNPAIR")
        case ("unpair-key-change", .unreachable(let reason)):
            try check(reason.contains("host identity changed"), "Forget lost identity-change reason")
            try check(!host.log.contains("first message"), "UNPAIR sent to a different host identity")
        default: throw CheckFailure(description: "\(label): unexpected outcome \(outcome)")
        }
        print("PASS \(label): real UnpairTask, one completion, preserved reason")
    }

    for (label, arguments) in [("wrong", ["wrong"]), ("rate-limit", ["ratelimit", "599"])] {
        let host = try FakeHost(root: root, label: label, arguments: arguments)
        defer { host.stop() }
        let (client, _) = try connect(host)
        try check(client.pinRejected && !client.pairingCompleted, "\(label): pairing unexpectedly succeeded")
        try check(ClientState.knownHosts()[try host.key] == nil, "\(label): stored refused pairing")
        if label == "rate-limit" { try check(client.pairRetryAfter == 599, "rate-limit wait lost") }
        try host.waitForLog("-- closed")
        try check(!host.log.contains("confirmed peer name:"), "\(label): stored an unconfirmed name")
        try check(host.log.components(separatedBy: "first message 0xa0").count == 2, "\(label): retried as a different variant")
        print("PASS \(label): no stored peer/name, no fallback retry")
    }

    let host = try FakeHost(root: root, label: "pair-then-stream", arguments: ["busy"])
    defer { host.stop() }
    let (client, delegate) = try connect(host, pairOnly: false)
    if HostConnection.hardwareCodecs == 0 {
        // Virtual Macs (GitHub's macos-14 runners) have no hardware decoder:
        // pairing must still complete, then the client stops before streaming.
        try check(ClientState.knownHosts()[try host.key] != nil, "pair-then-stream did not pair without a decoder")
        try check(delegate.reason.contains("no supported hardware"), "pair-then-stream: \(delegate.reason)")
        try host.waitForLog("-- closed")
        try check(!host.log.contains("next message 0x81"), "pair-then-stream sent CLIENT_HELLO without a decoder")
        try check(host.log.contains("confirmed peer name: Aman’s MacBook Pro"), "pair-then-stream omitted name")
        print("PASS pair-then-stream (no hardware decoder): named pairing, no CLIENT_HELLO")
        return
    }
    try check(client.hostBusy && ClientState.knownHosts()[try host.key] != nil, "pair-then-stream did not pair before BUSY")
    try host.waitForLog("next message 0x81")
    try check(host.log.contains("confirmed peer name: Aman’s MacBook Pro"), "pair-then-stream omitted name")
    print("PASS pair-then-stream: named pairing then CLIENT_HELLO")
}

do {
    try check(CommandLine.arguments.count == 2, "expected temporary test directory")
    try run(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    print("Pair-name integration checks passed; all state was temporary.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
