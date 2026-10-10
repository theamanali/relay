// One-shot connection that asks a host, over the handshake alone, whether
// it still has this Mac paired. Wraps a HostConnection in verify mode and
// reduces its delegate callbacks to a single completion. The handshake ends
// with SERVER_HELLO's `paired`, and nothing follows it (no CLIENT_HELLO), so
// the host's display and any other Mac's session are untouched; what to do
// with the answer is the caller's.

import CoreMedia
import Foundation

/// Completion and deadline are owned exclusively by connection.queue.
final class VerifyTask: HostConnectionDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        /// SERVER_HELLO said `paired`: the host still knows this Mac.
        case paired
        /// SERVER_HELLO said not paired: the host forgot this Mac.
        case forgotten
        /// No handshake before the timeout, or a host with another identity.
        case unreachable
    }

    private let connection: HostConnection
    private var completion: (@Sendable (Outcome) -> Void)?
    private var timeout: DispatchWorkItem?

    init(options: HostConnection.Options) throws {
        var opts = options
        opts.verifyOnly = true
        opts.reconnects = false
        connection = try HostConnection(options: opts)
        connection.delegate = self
    }

    /// `completion` runs once, on an arbitrary queue. A host that has not
    /// answered by `timeout` counts as unreachable.
    func run(timeout seconds: Double, completion: @escaping @Sendable (Outcome) -> Void) {
        connection.queue.async { [self] in
            self.completion = completion
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.connection.stop()
                self.deliver(.unreachable)
            }
            timeout = work
            connection.queue.asyncAfter(deadline: .now() + seconds, execute: work)
            connection.start()
        }
    }

    private func deliver(_ outcome: Outcome) {
        timeout?.cancel()
        timeout = nil
        guard let completion else { return }
        self.completion = nil
        completion(outcome)
    }

    // MARK: HostConnectionDelegate

    func connection(_ c: HostConnection, didChangeStatus status: String) {}

    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping @Sendable (String?) -> Void) {
        // Verify mode never asks; if it somehow does, decline.
        completion(nil)
    }

    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {}
    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {}
    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime) {}
    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming) {}

    func connectionDidEnd(_ c: HostConnection, reason: String) {
        switch c.pairingVerified {
        case .some(true): deliver(.paired)
        case .some(false): deliver(.forgotten)
        case .none: deliver(.unreachable)
        }
    }
}
