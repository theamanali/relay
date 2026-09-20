// Decides which known host to ask whether it still has this Mac paired. The
// host's TXT record carries `pg`, a digest of its pairing list that moves
// whenever it pairs or forgets a client; a known host advertising a digest
// other than the one last verified (or one never verified, as after an
// update or a launch while the PC forgot us) gets one handshake-only
// connection (`VerifyTask`). Pure, so the rule is testable without a network.

import Foundation

struct PairingVerifier {
    /// Digests attempted this run, per host key. One attempt per value: an
    /// unreachable host is not asked again on every browse update, only when
    /// its digest moves (or the app restarts).
    private var attempted: [Data: String] = [:]

    /// The next host to check, if any: known, advertising a digest, and that
    /// digest neither verified nor already attempted. The attempt is recorded
    /// here, before the connection is made.
    mutating func next(among hosts: [DiscoveredHost], known: [Data: String], verified: [Data: String]) -> (host: DiscoveredHost, key: Data, digest: String)? {
        for host in hosts {
            guard let key = host.publicKey, known[key] != nil, let digest = host.pairingDigest else { continue }
            if verified[key] == digest || attempted[key] == digest { continue }
            attempted[key] = digest
            return (host, key, digest)
        }
        return nil
    }

    /// An attempt whose answer was thrown away (a Connect, Pair or Forget to
    /// the same host started meanwhile): ask again next time.
    mutating func retract(_ key: Data) {
        attempted[key] = nil
    }
}
