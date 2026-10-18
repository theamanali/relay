import Foundation

/// How one message arrived, as far as the Mac can see without the PC's
/// clock: its size on the wire, the bytes that arrived in reads after its
/// first record was decrypted (and over how long), and decryption time.
struct ReceiveTiming: Equatable, Sendable {
    /// Wire bytes of the whole message: length prefixes, records and tags.
    var wireBytes: Int
    /// Bytes of this message that arrived after its first record was in.
    /// Zero for a single-record message, or when the rest was already
    /// buffered by then (the Mac was late to read, not the link fast).
    var lateBytes: Int
    var lateNanos: UInt64
    /// Time spent decrypting this message's records.
    var decryptNanos: UInt64

    /// The rate the message's later records arrived at: the link, or the
    /// PC's sending, whichever was slower.
    var bitsPerSecond: Double? {
        guard lateBytes > 0, lateNanos > 0 else { return nil }
        return Double(lateBytes) * 8 / (Double(lateNanos) / 1e9)
    }

    /// The whole message's time on the wire at that rate: an estimate,
    /// since the first record's own arrival is not observed.
    var transferMilliseconds: Double? {
        bitsPerSecond.map { Double(wireBytes) * 8 / $0 * 1_000 }
    }

    var decryptMilliseconds: Double { Double(decryptNanos) / 1e6 }
}

/// Follows the receive loop's reads and record decryptions; pure, so tests
/// can drive it with made-up times. Positions are wire bytes since the
/// connection opened: `bytesRead` counts everything read, `consumed` (what
/// the frame reader has handed out) trails it by what is still buffered.
struct ReceiveTimer {
    private(set) var bytesRead = 0
    private var message: (start: Int, decrypt: UInt64, firstRecord: (at: UInt64, bytesRead: Int)?)?

    mutating func didRead(_ count: Int) { bytesRead += count }

    /// One record decrypted. `startedAt` is the consumed position before the
    /// record, `consumed` after it. Returns the message's timing when this
    /// record completed it.
    mutating func opened(startedAt: Int, consumed: Int, decryptNanos: UInt64,
                         complete: Bool, now: UInt64) -> ReceiveTiming? {
        var current = message ?? (startedAt, 0, nil)
        current.decrypt += decryptNanos
        guard complete else {
            if current.firstRecord == nil { current.firstRecord = (now, bytesRead) }
            message = current
            return nil
        }
        message = nil
        var late = 0
        var lateNanos: UInt64 = 0
        if let first = current.firstRecord, consumed > first.bytesRead, now > first.at {
            late = consumed - first.bytesRead
            lateNanos = now - first.at
        }
        return ReceiveTiming(wireBytes: consumed - current.start, lateBytes: late,
                             lateNanos: lateNanos, decryptNanos: current.decrypt)
    }

    mutating func reset() {
        bytesRead = 0
        message = nil
    }
}
