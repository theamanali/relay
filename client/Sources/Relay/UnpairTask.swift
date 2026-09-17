// One-shot connection that asks a host to forget this Mac. Wraps a
// HostConnection in unpair mode and reduces its delegate callbacks to a single
// completion: whether the host confirmed. The local pairing is the caller's to
// remove, and it should go regardless of the outcome.

import CoreMedia
import Foundation

final class UnpairTask: HostConnectionDelegate {
    private let connection: HostConnection
    private var completion: ((Bool) -> Void)?
    private var timeout: DispatchWorkItem?

    init(options: HostConnection.Options) throws {
        var opts = options
        opts.unpairOnly = true
        opts.reconnects = false
        connection = try HostConnection(options: opts)
        connection.delegate = self
    }

    /// `completion` runs once, on an arbitrary queue, with `true` when the host
    /// answered UNPAIR. An unreachable host counts as unconfirmed after `timeout`.
    func run(timeout seconds: Double, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.connection.stop()
            self.deliver(false)
        }
        timeout = work
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        connection.start()
    }

    private func deliver(_ confirmed: Bool) {
        timeout?.cancel()
        timeout = nil
        guard let completion else { return }
        self.completion = nil
        completion(confirmed)
    }

    // MARK: HostConnectionDelegate

    func connection(_ c: HostConnection, didChangeStatus status: String) {}

    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping (String?) -> Void) {
        // Unpair mode never asks; if it somehow does, decline.
        completion(nil)
    }

    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {}
    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {}
    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime) {}
    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming) {}

    func connectionDidEnd(_ c: HostConnection, reason: String) {
        deliver(c.hostConfirmedUnpair)
    }
}
