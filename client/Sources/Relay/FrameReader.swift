import Foundation

/// Reassembles length-prefixed frames from a byte stream so the receive
/// loop can pull whatever the socket has in one read instead of one read for
/// the 4-byte length and another for the body. Caller serializes access.
struct FrameReader {
    enum Failure: Error, Equatable {
        case badLength(Int)
    }

    let maxFrame: Int
    private var buffer = Data()
    private var consumed = 0

    init(maxFrame: Int) {
        self.maxFrame = maxFrame
    }

    /// Bytes still needed before `next()` can return a frame: the rest of the
    /// header, or the rest of the body once the header is in.
    var needed: Int {
        let have = buffer.count - consumed
        guard have >= 4 else { return 4 - have }
        let len = Int(buffer.be32(at: consumed))
        return max(1, 4 + len - have)
    }

    /// Bytes received but not yet returned by `next()`.
    var buffered: Int { buffer.count - consumed }

    mutating func append(_ data: Data) {
        // Drop the consumed prefix only when it dominates, so steady-state
        // reads are appends rather than reallocations.
        if consumed > 0, consumed >= buffer.count / 2 {
            buffer.removeSubrange(0..<consumed)
            consumed = 0
        }
        buffer.append(data)
    }

    /// The next complete frame body, or nil when more bytes are needed.
    mutating func next() throws -> Data? {
        let have = buffer.count - consumed
        guard have >= 4 else { return nil }
        let len = Int(buffer.be32(at: consumed))
        guard len > 0, len <= maxFrame else { throw Failure.badLength(len) }
        guard have >= 4 + len else { return nil }
        let start = buffer.startIndex + consumed + 4
        let body = Data(buffer[start..<start + len])
        consumed += 4 + len
        return body
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        consumed = 0
    }
}
