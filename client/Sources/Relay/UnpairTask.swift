// One-shot connection that asks a host to forget this Mac. Wraps a
// HostConnection in unpair mode and reduces its delegate callbacks to a single
// completion: whether the host confirmed, and if not, why. The local pairing
// is the caller's to remove, and it should go regardless of the outcome.

import CoreMedia
import Foundation

final class UnpairTask: HostConnectionDelegate {
    enum Outcome {
        /// The host answered UNPAIR: the pairing is gone on both sides.
        case confirmed
        /// The host is in a session with another client and read nothing
        /// of ours; its half of the pairing is still there.
        case busy
        /// macOS explicitly denied access to local devices.
        case localNetworkDenied
        /// No confirmation, with the connection failure retained for the UI/log.
        case unreachable(reason: String)
    }

    private let connection: HostConnection
    private var completion: ((Outcome) -> Void)?
    private var timeout: DispatchWorkItem?

    init(options: HostConnection.Options) throws {
        var opts = options
        opts.unpairOnly = true
        opts.reconnects = false
        connection = try HostConnection(options: opts)
        connection.delegate = self
    }

    /// `completion` runs once, on an arbitrary queue. A host that has not
    /// answered by `timeout` counts as unreachable.
    func run(timeout seconds: Double, completion: @escaping (Outcome) -> Void) {
        connection.queue.async { [self] in
            self.completion = completion
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.connection.stop()
                self.deliver(.unreachable(reason: "the PC didn't answer"))
            }
            timeout = work
            // Serialize the timeout with delegate replies: only one outcome
            // may remove local state and open a result sheet.
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

    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping (String?) -> Void) {
        // Unpair mode never asks; if it somehow does, decline.
        completion(nil)
    }

    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart) {}
    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data]) {}
    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime) {}
    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming) {}

    func connectionDidEnd(_ c: HostConnection, reason: String) {
        if c.hostConfirmedUnpair { deliver(.confirmed) }
        else if c.hostBusy { deliver(.busy) }
        else if c.localNetworkDenied { deliver(.localNetworkDenied) }
        else { deliver(.unreachable(reason: reason)) }
    }
}
