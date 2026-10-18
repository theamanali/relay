import Foundation

/// The PC's clock relative to this Mac's, from TIME_REQUEST / TIME_REPLY
/// (PROTOCOL.md "Clock sync and frame timing"). NTP's math on the last few
/// exchanges; the one with the lowest delay gives the offset, since queueing
/// on either side only ever adds delay and skews that sample's offset.
/// Times are µs: the Mac's `systemUptime` clock and the PC's QPC.
struct ClockSync: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        /// PC minus Mac.
        let offset: Int64
        /// Round trip minus the PC's own time with the request.
        let delay: Int64
    }

    static let capacity = 8
    /// Slower exchanges say more about a stall than about the clocks.
    static let maxDelay: Int64 = 50_000

    private(set) var samples: [Sample] = []

    /// `t1` Mac sent, `t2` PC received, `t3` PC replied, `t4` Mac received.
    /// False when the sample was not kept.
    @discardableResult
    mutating func add(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) -> Bool {
        let (t1, t2, t3, t4) = (Int64(clamping: t1), Int64(clamping: t2), Int64(clamping: t3), Int64(clamping: t4))
        let delay = (t4 - t1) - (t3 - t2)
        // A negative delay means a broken stamp, not a fast network; µs
        // rounding on both sides allows a little.
        guard delay >= -2, delay <= Self.maxDelay, t4 >= t1, t3 >= t2 else { return false }
        samples.append(Sample(offset: ((t2 - t1) + (t3 - t4)) / 2, delay: max(0, delay)))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        return true
    }

    var best: Sample? { samples.min { $0.delay < $1.delay } }

    /// The Mac time of a PC stamp `h`, or nil before the first sample or for
    /// an unknown stamp.
    func macMicros(ofHost h: UInt64) -> Int64? {
        guard let best, h != UInt64.max else { return nil }
        return Int64(clamping: h) - best.offset
    }

    static func nowMicros() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000) }
}

/// Input messages sent since the first TIME_REQUEST, matched with the PC's
/// `inputs_applied`: TCP keeps them in order, so the PC's N-th is ours.
struct InputLedger: Sendable {
    private(set) var sent: UInt64 = 0
    private(set) var applied: UInt64 = 0
    /// Event times (µs, `systemUptime`) of sent inputs the PC has not
    /// reported yet; messages no event caused (key releases on focus loss)
    /// are counted but have none.
    private var eventMicros: [UInt64: Double] = [:]

    mutating func didSend(eventTime: TimeInterval?) {
        sent += 1
        if let eventTime { eventMicros[sent] = eventTime * 1_000_000 }
    }

    /// The PC handled `count` inputs, the last at `macMicros` (its stamp in
    /// Mac time). Returns event → applied for that last one, in ms, when
    /// the count moved and both ends are known.
    mutating func hostApplied(_ count: UInt64, atMacMicros macMicros: Int64?) -> Double? {
        guard count > applied else { return nil }
        applied = count
        let event = eventMicros[count]
        eventMicros = eventMicros.filter { $0.key > count }
        guard let event, let macMicros else { return nil }
        return (Double(macMicros) - event) / 1_000
    }
}

/// One frame measured across both clocks.
struct FrameEndToEnd: Equatable, Sendable {
    /// This Mac's FRAME sequence (the one the presenter reports).
    var sequence: UInt64
    /// DWM's present in Mac µs; nil on a re-encoded tick or before sync.
    var presentMacMicros: Int64?
    /// Present → submitted to NVENC: how old the content was at encode.
    var contentAgeMs: Double?
    /// The PC finished writing → this Mac had the whole frame.
    var sentToReceivedMs: Double?

    init(sequence: UInt64, ext: Proto.FrameTimingExt, clock: ClockSync, receivedMicros: UInt64) {
        self.sequence = sequence
        presentMacMicros = clock.macMicros(ofHost: ext.presentMicros)
        let unknown = Proto.FrameTimingExt.unknown
        if ext.presentMicros != unknown, ext.submitMicros != unknown, ext.submitMicros >= ext.presentMicros {
            contentAgeMs = Double(ext.submitMicros - ext.presentMicros) / 1_000
        }
        if let sent = clock.macMicros(ofHost: ext.sentMicros) {
            sentToReceivedMs = Double(Int64(clamping: receivedMicros) - sent) / 1_000
        }
    }
}
