/// Caller serializes access. Only decoded frames may be discarded here;
/// compressed P-frames must still reach the decoder in order.
struct LatestFrame<Value> {
    private(set) var generation = 0
    private var newest: UInt64?
    private(set) var pending: Value?
    private(set) var dropped = 0
    private(set) var replaced = 0
    private(set) var late = 0

    mutating func reset(generation: Int, clearMetrics: Bool) {
        self.generation = generation
        newest = nil
        pending = nil
        if clearMetrics { dropped = 0; replaced = 0; late = 0 }
    }

    mutating func offer(_ value: Value, sequence: UInt64, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        guard newest.map({ sequence > $0 }) ?? true else { dropped += 1; late += 1; return false }
        newest = sequence
        if pending != nil { dropped += 1; replaced += 1 }
        pending = value
        return true
    }

    mutating func take() -> Value? {
        defer { pending = nil }
        return pending
    }
}
