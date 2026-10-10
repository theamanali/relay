import CoreMedia
import Foundation

/// Network/decoder boundary. The lock serializes decoder control with UI
/// cancellation and rejects callbacks from retired connections. Frames stay on
/// the connection queue; only control events are dispatched to the main actor.
final class SessionPipeline: HostConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var active: HostConnection?
    private let renderer: VideoRenderer
    private let stats: LatencyStats
    @MainActor private weak var owner: AppDelegate?

    @MainActor
    init(owner: AppDelegate, renderer: VideoRenderer, stats: LatencyStats) {
        self.owner = owner
        self.renderer = renderer
        self.stats = stats
    }

    func activate(_ connection: HostConnection) {
        lock.withLock { active = connection; renderer.reset() }
    }
    func reset() { lock.withLock { renderer.reset() } }
    func deactivate() { lock.withLock { active = nil; renderer.reset() } }
    private func withActive(_ c: HostConnection, _ body: () -> Void) {
        lock.withLock {
            guard active === c else { return }
            body()
            if let failure = renderer.failure { c.fail(failure) }
        }
    }

    func connection(_ c: HostConnection, didChangeStatus status: String) {
        DispatchQueue.main.async { [weak self] in self?.owner?.connection(c, didChangeStatus: status) }
    }
    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String,
                    completion: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let owner = self?.owner else { completion(nil); return }
            owner.connection(c, needsPINFor: host, fingerprint: fingerprint, completion: completion)
        }
    }
    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {
        withActive(c) { stats.reset(); renderer.streamDidStart(stream) }
        DispatchQueue.main.async { [weak self] in self?.owner?.connection(c, didStart: stream) }
    }
    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {
        withActive(c) { renderer.setParameterSets(parameterSets) }
    }
    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool,
                    sequence: UInt64, receivedAt: CMTime) {
        withActive(c) { renderer.enqueue(frame: nalUnits, keyframe: keyframe, sequence: sequence, receivedAt: receivedAt) }
    }
    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming) {
        withActive(c) { stats.record(timing) }
    }
    func connectionDidEnd(_ c: HostConnection, reason: String) {
        let outcome = ConnectionOutcome(c)
        withActive(c) { renderer.reset() }
        DispatchQueue.main.async { [weak self] in self?.owner?.connectionDidEnd(c, reason: reason, outcome: outcome) }
    }
}

/// Snapshot on the connection queue, before a fixed-host retry changes it.
struct ConnectionOutcome: Sendable {
    let everConnected: Bool
    let pinRejected: Bool
    let pairRetryAfter: Int?
    let pairingCompleted: Bool
    let activeBitrateMbps: Int?
    init(_ c: HostConnection) {
        everConnected = c.everConnected
        pinRejected = c.pinRejected
        pairRetryAfter = c.pairRetryAfter
        pairingCompleted = c.pairingCompleted
        activeBitrateMbps = c.activeBitrateMbps
    }
}
