import Foundation

/// Latency samples in fixed 0.1 ms bins up to 50 ms, plus one overflow bin.
/// Recording is two additions, so it can run for every frame of every
/// session; a percentile is the mean of the samples in the bin it lands in,
/// exact when they are all equal and within a bin's width otherwise.
struct LatencyHistogram: Equatable, Sendable {
    static let binWidth = 0.1
    static let binCount = 500
    private var counts = [UInt32](repeating: 0, count: binCount + 1)
    private var sums = [Double](repeating: 0, count: binCount + 1)
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var max = 0.0

    var mean: Double? { count == 0 ? nil : sum / Double(count) }

    mutating func record(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        let bin = Swift.min(Int(ms / Self.binWidth), Self.binCount)
        counts[bin] += 1
        sums[bin] += ms
        count += 1
        sum += ms
        max = Swift.max(max, ms)
    }

    mutating func merge(_ other: LatencyHistogram) {
        guard other.count > 0 else { return }
        for i in counts.indices {
            counts[i] += other.counts[i]
            sums[i] += other.sums[i]
        }
        count += other.count
        sum += other.sum
        max = Swift.max(max, other.max)
    }

    /// Nearest-rank percentile, `fraction` in 0...1.
    func percentile(_ fraction: Double) -> Double? {
        guard count > 0 else { return nil }
        let rank = Swift.max(1, Int((fraction * Double(count)).rounded(.up)))
        var seen = 0
        for i in counts.indices where counts[i] > 0 {
            seen += Int(counts[i])
            if seen >= rank { return sums[i] / Double(counts[i]) }
        }
        return max
    }

    struct Bar: Equatable, Sendable {
        let start: Double
        let count: Int
    }

    /// Bars `width` ms wide from 0 to `upTo`; the last one holds everything
    /// from `upTo` on.
    func bars(width: Double, upTo: Double) -> [Bar] {
        let n = Int((upTo / width).rounded())
        var totals = [Int](repeating: 0, count: n + 1)
        for i in counts.indices where counts[i] > 0 {
            let bar = Swift.min(Int(Double(i) * Self.binWidth / width + 1e-9), n)
            totals[bar] += Int(counts[i])
        }
        return totals.enumerated().map { Bar(start: Double($0.offset) * width, count: $0.element) }
    }
}

/// The last few seconds of a measurement: one histogram per wall-clock
/// second, reused in a ring.
struct LatencyWindow: Sendable {
    private var slots: [(second: UInt64, histogram: LatencyHistogram)]

    init(seconds: Int) {
        slots = Array(repeating: (UInt64.max, LatencyHistogram()), count: seconds)
    }

    var seconds: Int { slots.count }

    mutating func record(_ ms: Double, at nanos: UInt64) {
        let second = nanos / 1_000_000_000
        let i = Int(second % UInt64(slots.count))
        if slots[i].second != second { slots[i] = (second, LatencyHistogram()) }
        slots[i].histogram.record(ms)
    }

    func merged(at nanos: UInt64) -> LatencyHistogram {
        let now = nanos / 1_000_000_000
        var out = LatencyHistogram()
        for slot in slots where slot.second <= now && slot.second + UInt64(slots.count) > now {
            out.merge(slot.histogram)
        }
        return out
    }
}

/// One median per second of the session, for the report's timeline: the
/// current second's samples build a histogram, its median is kept when the
/// next second starts. Seconds without samples stay nil.
struct SecondMedians: Sendable {
    private(set) var medians: [Double?] = []
    private var current: (second: Int, histogram: LatencyHistogram)?

    /// `second` counts from the start of measurement.
    mutating func record(_ ms: Double, second: Int) {
        guard second >= 0 else { return }
        if let c = current, c.second != second { flush() }
        if current == nil { current = (second, LatencyHistogram()) }
        current?.histogram.record(ms)
    }

    /// Every second so far, including the one still in progress.
    var all: [Double?] {
        var copy = self
        copy.flush()
        return copy.medians
    }

    private mutating func flush() {
        guard let c = current else { return }
        if medians.count < c.second { medians += Array(repeating: nil, count: c.second - medians.count) }
        if medians.count == c.second { medians.append(c.histogram.percentile(0.5)) }
        current = nil
    }
}

/// Bytes per wall-clock second over the last few seconds, for a data rate.
struct ByteWindow: Sendable {
    private var slots: [(second: UInt64, bytes: Int)]

    init(seconds: Int) { slots = Array(repeating: (UInt64.max, 0), count: seconds) }

    mutating func add(_ bytes: Int, at nanos: UInt64) {
        let second = nanos / 1_000_000_000
        let i = Int(second % UInt64(slots.count))
        if slots[i].second != second { slots[i] = (second, 0) }
        slots[i].bytes += bytes
    }

    func total(at nanos: UInt64) -> Int {
        let now = nanos / 1_000_000_000
        return slots.filter { $0.second <= now && $0.second + UInt64(slots.count) > now }.reduce(0) { $0 + $1.bytes }
    }
}

/// The newest `capacity` values, oldest first when read.
struct RecentSamples: Sendable {
    private var values: [Double]
    private var next = 0
    private var filled = false

    init(capacity: Int) { values = Array(repeating: 0, count: capacity) }

    mutating func append(_ value: Double) {
        values[next] = value
        next = (next + 1) % values.count
        if next == 0 { filled = true }
    }

    var ordered: [Double] { filled ? Array(values[next...] + values[..<next]) : Array(values[..<next]) }
}

/// What was streamed, for the HUD's detail view and the session report.
struct StreamInfo: Equatable, Sendable {
    var host: String
    var codec: String
    var width: Int
    var height: Int
    var fps: Int
    var bitrateMbps: Int
    /// "4:4:4, 10-bit, Balanced", or empty.
    var format: String
    var link: String?
    var vsync: Bool

    var summary: String {
        var parts = ["\(codec) \(width)×\(height) @ \(fps) Hz", "\(bitrateMbps) Mbps"]
        if !format.isEmpty { parts.append(format) }
        if let link { parts.append(link) }
        parts.append(vsync ? "VSync on" : "VSync off")
        return parts.joined(separator: ", ")
    }

    /// The widest summary this app can produce, for sizing the report so it
    /// stays on one line: the longest codec and link names, an 8K stream at
    /// 240 Hz, the top bitrate and every picture option.
    static let widest = StreamInfo(
        host: "", codec: "H.264", width: 7680, height: 4320, fps: 240,
        bitrateMbps: VideoBitrate.maximum,
        format: "4:4:4, 10-bit, \(EncoderQuality.best.title)", link: "This MacBook", vsync: false
    )
}

/// The presenter's running totals for the session.
struct PresenterCounters: Equatable, Sendable {
    /// Decoded frames replaced by a newer one before they were drawn.
    var replaced: Int
    /// Frames that arrived after the presenter had moved on.
    var late: Int
    /// Drawables Metal reported as never shown.
    var dropped: Int
    /// No drawable, no command buffer or an unsupported pixel format.
    var unavailable: Int
    var gpuFailures: Int

    static let zero = PresenterCounters(replaced: 0, late: 0, dropped: 0, unavailable: 0, gpuFailures: 0)
}

/// Thread-safe session telemetry. Presentation times arrive from Metal's
/// callbacks, decode times from VideoToolbox, host timing on the network
/// queue; the HUD reads a snapshot a few times a second and the session
/// report once at the end. Every recording is a few additions under the lock.
final class LatencyStats: @unchecked Sendable {
    struct Stage: Equatable, Sendable {
        var count: Int
        var p50: Double?
        var p95: Double?
        var p99: Double?
        init(_ h: LatencyHistogram) {
            count = h.count
            p50 = h.percentile(0.5); p95 = h.percentile(0.95); p99 = h.percentile(0.99)
        }
    }

    struct HUDSnapshot: Sendable {
        var presentedFPS: Double
        var decodedFPS: Double
        /// Receive → shown on the display.
        var toScreen: Stage
        /// Receive → decoded.
        var decode: Stage
        /// Capture + encode + send on the PC.
        var host: Stage
        var networkHalfRTT: Double?
        /// A whole frame's estimated time on the wire (ReceiveTiming).
        var transfer: Stage
        /// macOS input event → message handed to the socket.
        var inputSent: Stage
        /// Measured across both clocks (FRAME_TIMING_EXT), once synced.
        var desktopToScreen = Stage(LatencyHistogram())
        var contentAge = Stage(LatencyHistogram())
        /// Host submit → sent; independent of source time and clock sync.
        var encodeSend = Stage(LatencyHistogram())
        var sentToReceived = Stage(LatencyHistogram())
        var inputApplied = Stage(LatencyHistogram())
        /// Video data arriving, in Mbps, and the bitrate the PC was asked for.
        var receivedMbps: Double?
        /// Desktop → screen per frame, oldest first; empty without clock sync.
        var desktopSparkline: [Double] = []
        /// PC minus Mac, and the delay of the exchange it came from.
        var clockOffsetMs: Double?
        var clockDelayMs: Double?
        /// Receive → screen per frame, oldest first.
        var sparkline: [Double]
        /// One refresh interval of the stream, in ms.
        var frameBudget: Double
        var stream: StreamInfo?
        var counters = PresenterCounters.zero
        /// Still inside `warmUp`: nothing measured yet, the HUD stays hidden.
        var warmingUp = false
    }

    /// The first seconds after STREAM_START are not measured: the first
    /// keyframe, decoder start-up and the encoder settling would skew the
    /// HUD and the session report.
    static let warmUp: UInt64 = 3_000_000_000
    static let windowSeconds = 5
    static let sparklineFrames = 480

    private let lock = NSLock()
    private var stream: StreamInfo?
    /// STREAM_START + `warmUp`: samples before this are dropped.
    private var measuringFrom: UInt64 = 0
    private var toScreen = LatencyWindow(seconds: windowSeconds)
    private var decode = LatencyWindow(seconds: windowSeconds)
    private var host = LatencyWindow(seconds: windowSeconds)
    private var network = LatencyWindow(seconds: windowSeconds)
    private var transfer = LatencyWindow(seconds: windowSeconds)
    private var inputSent = LatencyWindow(seconds: windowSeconds)
    private var desktopToScreen = LatencyWindow(seconds: windowSeconds)
    private var contentAge = LatencyWindow(seconds: windowSeconds)
    private var encodeSend = LatencyWindow(seconds: windowSeconds)
    private var sentToReceived = LatencyWindow(seconds: windowSeconds)
    private var inputApplied = LatencyWindow(seconds: windowSeconds)
    private var sessionDesktopToScreen = LatencyHistogram()
    private var sessionContentAge = LatencyHistogram()
    private var sessionEncodeSend = LatencyHistogram()
    private var sessionSentToReceived = LatencyHistogram()
    private var sessionInputApplied = LatencyHistogram()
    private var clock: ClockSync.Sample?
    private var clockReplies = 0
    private var desktopSparkline = RecentSamples(capacity: sparklineFrames)
    private var toScreenTimeline = SecondMedians()
    private var desktopTimeline = SecondMedians()
    /// A frame's PC present (Mac µs) and its Metal presentation meet here,
    /// whichever arrives first; keyed by the Mac's FRAME sequence.
    private var pendingShown: [UInt64: (present: Int64?, shown: Int64?)] = [:]
    private var sessionToScreen = LatencyHistogram()
    private var sessionDecode = LatencyHistogram()
    private var sessionHost = LatencyHistogram()
    private var sessionNetwork = LatencyHistogram()
    private var sessionTransfer = LatencyHistogram()
    private var sessionInputSent = LatencyHistogram()
    private var sessionDecrypt = LatencyHistogram()
    /// Bytes and time behind the transfer estimates, for the link's rate.
    private var lateBytes = 0
    private var received = ByteWindow(seconds: windowSeconds)
    private var sessionBytes = 0
    private var lateNanos: UInt64 = 0
    private var sparkline = RecentSamples(capacity: sparklineFrames)

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// A new stream: everything measured so far is dropped.
    func reset(stream: StreamInfo? = nil, at nanos: UInt64 = LatencyStats.now()) {
        lock.withLock {
            self.stream = stream
            measuringFrom = nanos + Self.warmUp
            toScreen = LatencyWindow(seconds: Self.windowSeconds)
            decode = LatencyWindow(seconds: Self.windowSeconds)
            host = LatencyWindow(seconds: Self.windowSeconds)
            network = LatencyWindow(seconds: Self.windowSeconds)
            transfer = LatencyWindow(seconds: Self.windowSeconds)
            inputSent = LatencyWindow(seconds: Self.windowSeconds)
            desktopToScreen = LatencyWindow(seconds: Self.windowSeconds)
            contentAge = LatencyWindow(seconds: Self.windowSeconds)
            encodeSend = LatencyWindow(seconds: Self.windowSeconds)
            sentToReceived = LatencyWindow(seconds: Self.windowSeconds)
            inputApplied = LatencyWindow(seconds: Self.windowSeconds)
            sessionDesktopToScreen = LatencyHistogram()
            sessionContentAge = LatencyHistogram()
            sessionEncodeSend = LatencyHistogram()
            sessionSentToReceived = LatencyHistogram()
            sessionInputApplied = LatencyHistogram()
            clock = nil
            clockReplies = 0
            desktopSparkline = RecentSamples(capacity: Self.sparklineFrames)
            toScreenTimeline = SecondMedians()
            desktopTimeline = SecondMedians()
            pendingShown = [:]
            sessionToScreen = LatencyHistogram()
            sessionDecode = LatencyHistogram()
            sessionHost = LatencyHistogram()
            sessionNetwork = LatencyHistogram()
            sessionTransfer = LatencyHistogram()
            sessionInputSent = LatencyHistogram()
            sessionDecrypt = LatencyHistogram()
            lateBytes = 0
            received = ByteWindow(seconds: Self.windowSeconds)
            sessionBytes = 0
            lateNanos = 0
            sparkline = RecentSamples(capacity: Self.sparklineFrames)
        }
    }

    /// The UI learns the host name and link after the pipeline has reset.
    func setStream(_ info: StreamInfo) { lock.withLock { stream = info } }

    func recordPresented(milliseconds ms: Double, at nanos: UInt64 = LatencyStats.now()) {
        guard ms.isFinite, ms >= 0 else { return }
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            toScreen.record(ms, at: nanos)
            sessionToScreen.record(ms)
            sparkline.append(ms)
            toScreenTimeline.record(ms, second: second(of: nanos))
        }
    }

    func recordDecoded(milliseconds ms: Double, at nanos: UInt64 = LatencyStats.now()) {
        guard ms.isFinite, ms >= 0 else { return }
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            decode.record(ms, at: nanos)
            sessionDecode.record(ms)
        }
    }

    func record(_ timing: Proto.FrameTiming, at nanos: UInt64 = LatencyStats.now()) {
        let unknown = Proto.FrameTiming.unknownMicros
        let fields = [timing.captureMicros, timing.encodeMicros, timing.sendMicros]
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            if !fields.contains(unknown) {
                let ms = fields.reduce(0) { $0 + Double($1) } / 1_000
                host.record(ms, at: nanos)
                sessionHost.record(ms)
            }
            if timing.networkRTTMicros != unknown {
                // Direct Ethernet is close to symmetric; labelled an estimate.
                let ms = Double(timing.networkRTTMicros) / 2_000
                network.record(ms, at: nanos)
                sessionNetwork.record(ms)
            }
        }
    }

    /// One FRAME's arrival. Frames whose later records were already
    /// buffered give no transfer estimate; decryption counts for every frame.
    func record(_ timing: ReceiveTiming, at nanos: UInt64 = LatencyStats.now()) {
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            received.add(timing.wireBytes, at: nanos)
            sessionBytes += timing.wireBytes
            sessionDecrypt.record(timing.decryptMilliseconds)
            guard let ms = timing.transferMilliseconds else { return }
            transfer.record(ms, at: nanos)
            sessionTransfer.record(ms)
            lateBytes += timing.lateBytes
            lateNanos += timing.lateNanos
        }
    }

    func recordInputSent(milliseconds ms: Double, at nanos: UInt64 = LatencyStats.now()) {
        guard ms.isFinite, ms >= 0 else { return }
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            inputSent.record(ms, at: nanos)
            sessionInputSent.record(ms)
        }
    }

    func recordClock(_ best: ClockSync.Sample) { lock.withLock { clock = best; clockReplies += 1 } }

    /// One frame across both clocks. Content age and sent → received count
    /// at once; desktop → screen waits for the frame's presentation.
    func record(_ timing: FrameEndToEnd, at nanos: UInt64 = LatencyStats.now()) {
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            if let ms = timing.encodeSendMs { encodeSend.record(ms, at: nanos); sessionEncodeSend.record(ms) }
            if let ms = timing.contentAgeMs { contentAge.record(ms, at: nanos); sessionContentAge.record(ms) }
            if let ms = timing.sentToReceivedMs { sentToReceived.record(ms, at: nanos); sessionSentToReceived.record(ms) }
            guard let present = timing.presentMacMicros else { return }
            join(timing.sequence, present: present, shown: nil, at: nanos)
        }
    }

    /// A frame reached the screen at `atMicros` (Mac µs).
    func recordShown(sequence: UInt64, atMicros: Int64, at nanos: UInt64 = LatencyStats.now()) {
        lock.withLock {
            // Before any sync (or from an older PC) nothing will meet it.
            guard clock != nil, nanos >= measuringFrom else { return }
            join(sequence, present: nil, shown: atMicros, at: nanos)
        }
    }

    /// Seconds since measurement began; under the lock.
    private func second(of nanos: UInt64) -> Int {
        nanos >= measuringFrom ? Int((nanos - measuringFrom) / 1_000_000_000) : -1
    }

    /// Under the lock.
    private func join(_ sequence: UInt64, present: Int64?, shown: Int64?, at nanos: UInt64) {
        var entry = pendingShown[sequence] ?? (nil, nil)
        if let present { entry.present = present }
        if let shown { entry.shown = shown }
        if let p = entry.present, let s = entry.shown {
            pendingShown[sequence] = nil
            let ms = Double(s - p) / 1_000
            guard ms.isFinite, ms >= 0 else { return }
            desktopToScreen.record(ms, at: nanos)
            sessionDesktopToScreen.record(ms)
            desktopSparkline.append(ms)
            desktopTimeline.record(ms, second: second(of: nanos))
            return
        }
        pendingShown[sequence] = entry
        // Replaced frames are never shown, re-encoded ones have no present:
        // forget anything well behind the newest.
        if pendingShown.count > 256 {
            pendingShown = pendingShown.filter { $0.key + 128 > sequence }
        }
    }

    func recordInputApplied(milliseconds ms: Double, at nanos: UInt64 = LatencyStats.now()) {
        guard ms.isFinite else { return }
        lock.withLock {
            guard nanos >= measuringFrom else { return }
            inputApplied.record(ms, at: nanos)
            sessionInputApplied.record(ms)
        }
    }

    func hudSnapshot(at nanos: UInt64 = LatencyStats.now()) -> HUDSnapshot {
        lock.withLock {
            let shown = toScreen.merged(at: nanos)
            let decoded = decode.merged(at: nanos)
            // The window holds the current second and the four before it.
            let windowStart = (nanos / 1_000_000_000).saturatingSubtract(UInt64(Self.windowSeconds - 1)) * 1_000_000_000
            let elapsed = Double(nanos - min(nanos, max(measuringFrom, windowStart))) / 1_000_000_000
            func rate(_ h: LatencyHistogram) -> Double { elapsed > 0.05 ? Double(h.count) / elapsed : 0 }
            return HUDSnapshot(
                presentedFPS: rate(shown), decodedFPS: rate(decoded),
                toScreen: Stage(shown), decode: Stage(decoded), host: Stage(host.merged(at: nanos)),
                networkHalfRTT: network.merged(at: nanos).percentile(0.5),
                transfer: Stage(transfer.merged(at: nanos)),
                inputSent: Stage(inputSent.merged(at: nanos)),
                desktopToScreen: Stage(desktopToScreen.merged(at: nanos)),
                contentAge: Stage(contentAge.merged(at: nanos)),
                encodeSend: Stage(encodeSend.merged(at: nanos)),
                sentToReceived: Stage(sentToReceived.merged(at: nanos)),
                inputApplied: Stage(inputApplied.merged(at: nanos)),
                receivedMbps: elapsed > 0.05 ? Double(received.total(at: nanos)) * 8 / elapsed / 1e6 : nil,
                desktopSparkline: desktopToScreen.merged(at: nanos).count > 0 ? desktopSparkline.ordered : [],
                clockOffsetMs: clock.map { Double($0.offset) / 1_000 },
                clockDelayMs: clock.map { Double($0.delay) / 1_000 },
                sparkline: sparkline.ordered,
                frameBudget: 1_000 / Double(max(stream?.fps ?? 60, 1)),
                stream: stream,
                warmingUp: nanos < measuringFrom)
        }
    }

    /// Opt-in once-per-second diagnostics for matched static/moving phases.
    /// Counts disclose sparse source measurements; no stale-value substitution.
    func timingLogLine(at nanos: UInt64 = LatencyStats.now()) -> String {
        let s = hudSnapshot(at: nanos)
        func stage(_ name: String, _ value: Stage) -> String {
            "\(name)=\(SessionReport.ms(value.p50))/\(SessionReport.ms(value.p95))[n=\(value.count)]"
        }
        let replies = lock.withLock { clockReplies }
        return String(format: "Timing window: uptime=%.3f fps=%.1f decoded=%.1f sync=%@ replies=%d ",
                      Double(nanos) / 1e9, s.presentedFPS, s.decodedFPS, s.clockOffsetMs == nil ? "no" : "yes", replies)
            + [stage("source-age", s.contentAge), stage("pc-work", s.host), stage("encode-send", s.encodeSend),
               stage("receive-screen", s.toScreen), stage("desktop-screen", s.desktopToScreen)].joined(separator: " ")
    }

    /// The whole session, or nil when nothing reached the screen.
    func sessionReport(at nanos: UInt64 = LatencyStats.now(), counters: PresenterCounters,
                       endedAt: Date = Date()) -> SessionReport? {
        lock.withLock {
            guard let stream, sessionToScreen.count > 0, nanos > measuringFrom else { return nil }
            let duration = Double(nanos - measuringFrom) / 1_000_000_000
            return SessionReport(stream: stream, endedAt: endedAt, duration: duration,
                                 presentedFPS: Double(sessionToScreen.count) / duration,
                                 toScreen: sessionToScreen, decode: sessionDecode, host: sessionHost,
                                 network: sessionNetwork, transfer: sessionTransfer,
                                 inputSent: sessionInputSent, decrypt: sessionDecrypt,
                                 desktopToScreen: sessionDesktopToScreen, contentAge: sessionContentAge,
                                 sentToReceived: sessionSentToReceived, inputApplied: sessionInputApplied,
                                 clock: clock,
                                 linkBitsPerSecond: lateNanos > 0 ? Double(lateBytes) * 8 / (Double(lateNanos) / 1e9) : nil,
                                 counters: counters,
                                 encodeSend: sessionEncodeSend,
                                 receivedBytes: sessionBytes,
                                 timeline: sessionDesktopToScreen.count > 0 ? desktopTimeline.all : toScreenTimeline.all)
        }
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}

/// One finished session's numbers, for the report window, the clipboard and
/// the log.
struct SessionReport: Sendable {
    let stream: StreamInfo
    let endedAt: Date
    let duration: Double
    let presentedFPS: Double
    let toScreen: LatencyHistogram
    let decode: LatencyHistogram
    let host: LatencyHistogram
    let network: LatencyHistogram
    let transfer: LatencyHistogram
    let inputSent: LatencyHistogram
    let decrypt: LatencyHistogram
    let desktopToScreen: LatencyHistogram
    let contentAge: LatencyHistogram
    let sentToReceived: LatencyHistogram
    let inputApplied: LatencyHistogram
    /// The clock estimate in use when the session ended; nil for a PC
    /// without CAP_TIMING.
    let clock: ClockSync.Sample?
    /// The rate frames' later records arrived at, over the whole session.
    let linkBitsPerSecond: Double?
    let counters: PresenterCounters
    var encodeSend = LatencyHistogram()
    /// Video data received after the warm-up (wire bytes of FRAMEs).
    var receivedBytes = 0
    /// The headline measure's median per second (desktop → screen once
    /// synced, else receive → screen); nil for seconds with no frame.
    var timeline: [Double?] = []

    struct Row: Identifiable {
        let name: String
        let histogram: LatencyHistogram
        var id: String { name }
    }

    var rows: [Row] {
        [Row(name: "Desktop → screen", histogram: desktopToScreen),
         Row(name: "Content age", histogram: contentAge),
         Row(name: "PC work", histogram: host),
         Row(name: "Encode & send", histogram: encodeSend),
         Row(name: "Sent → received", histogram: sentToReceived),
         Row(name: "Network (RTT/2 est.)", histogram: network),
         Row(name: "Frame transfer (est.)", histogram: transfer),
         Row(name: "Decrypt", histogram: decrypt),
         Row(name: "Receive → decode", histogram: decode),
         Row(name: "Receive → screen", histogram: toScreen),
         Row(name: "Input → sent", histogram: inputSent),
         Row(name: "Input → applied", histogram: inputApplied)]
    }

    /// The whole session in the HUD's terms, so the report's headline and
    /// breakdown use the same measures, words and fallbacks as the HUD.
    var snapshot: LatencyStats.HUDSnapshot {
        var s = LatencyStats.HUDSnapshot(
            presentedFPS: presentedFPS, decodedFPS: duration > 0 ? Double(decode.count) / duration : 0,
            toScreen: .init(toScreen), decode: .init(decode), host: .init(host),
            networkHalfRTT: network.percentile(0.5), transfer: .init(transfer), inputSent: .init(inputSent),
            sparkline: [], frameBudget: 1_000 / Double(max(stream.fps, 1)), stream: stream, counters: counters)
        s.desktopToScreen = .init(desktopToScreen)
        s.contentAge = .init(contentAge)
        s.encodeSend = .init(encodeSend)
        s.clockOffsetMs = clock.map { Double($0.offset) / 1_000 }
        s.clockDelayMs = clock.map { Double($0.delay) / 1_000 }
        s.sentToReceived = .init(sentToReceived)
        s.inputApplied = .init(inputApplied)
        return s
    }

    var summary: StatsHUD.Summary { StatsHUD.Summary(snapshot) }

    /// The headline measure for the whole session: desktop → screen once
    /// synced, else receive → screen.
    var headline: LatencyHistogram { desktopToScreen.count > 0 ? desktopToScreen : toScreen }

    /// Decoded frames that never reached the screen (replaced by a newer one
    /// or dropped by the display), as a share of decoded frames.
    var skippedFraction: Double? {
        guard decode.count > 0 else { return nil }
        return min(1, Double(counters.replaced + counters.dropped) / Double(decode.count))
    }

    /// "Received 1.2 GB, 48 Mbps on average", or nil before any data.
    var dataText: String? {
        guard receivedBytes > 0, duration > 0 else { return nil }
        let gb = Double(receivedBytes) / 1e9
        let size = gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(receivedBytes) / 1e6)
        return String(format: "Received %@, %.0f Mbps on average", size, Double(receivedBytes) * 8 / duration / 1e6)
    }

    /// "Skipped 0.4% of frames".
    var skippedText: String {
        guard let f = skippedFraction else { return "Skipped frames: –" }
        return f > 0 && f < 0.001 ? "Skipped under 0.1% of frames" : String(format: "Skipped %.1f%% of frames", f * 100)
    }

    /// The breakdown on one line, for the Markdown and the log.
    var summaryLine: String {
        let s = summary
        var parts = ["\(s.label.replacingOccurrences(of: ", median", with: "")) p50 \(Self.ms(s.median)) p95 \(Self.ms(s.p95))"]
        parts += s.groups.map { "\($0.name) \(Self.ms($0.milliseconds))" }
        parts.append("\(s.inputLabel) \(Self.ms(s.input))")
        parts.append(skippedText.lowercased())
        return parts.joined(separator: ", ")
    }

    /// "PC clock +12.345 ms from this Mac (best delay 0.081 ms)", or nil.
    var clockText: String? {
        clock.map { String(format: "PC clock %+.3f ms from this Mac (best delay %.3f ms)",
                           Double($0.offset) / 1_000, Double($0.delay) / 1_000) }
    }

    /// "Frame data arrived at 2.31 Gb/s", or nil when no frame measured it.
    var linkText: String? {
        linkBitsPerSecond.map { String(format: "Frame data arrived at %.2f Gb/s", $0 / 1e9) }
    }

    var lengthText: String {
        let s = Int(duration.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    var countersText: String {
        var text = "replaced \(counters.replaced), late \(counters.late), dropped \(counters.dropped)"
        if counters.unavailable > 0 { text += ", no drawable \(counters.unavailable)" }
        if counters.gpuFailures > 0 { text += ", GPU errors \(counters.gpuFailures)" }
        return text
    }

    static let footnote = "Desktop → screen, Sent → received and Input → applied use clock sync. "
        + "Content age and Encode & send use only the PC clock; PC work is capture + encode + send. Receive starts after decryption; Frame transfer is estimated. Not "
        + "measured: the Windows app's own frame, input device sampling and the display panel."

    static func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }

    /// Paste-ready for docs/LATENCY.md.
    var markdown: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let date = format.string(from: endedAt)
        var lines = [
            "### \(stream.host), \(date)",
            "",
            stream.summary,
            "",
            summaryLine + " (ms)" + (dataText.map { ". " + $0 } ?? ""),
            "",
            "Length \(lengthText), \(String(format: "%.1f", presentedFPS)) fps shown, \(countersText)"
                + (linkText.map { ". " + $0 } ?? "") + (clockText.map { ". " + $0 } ?? ""),
            "",
            "| stage (ms) | p50 | p95 | p99 | max | samples |",
            "|---|---|---|---|---|---|",
        ]
        for row in rows {
            let h = row.histogram
            lines.append("| \(row.name) | \(Self.ms(h.percentile(0.5))) | \(Self.ms(h.percentile(0.95))) | "
                + "\(Self.ms(h.percentile(0.99))) | \(Self.ms(h.count > 0 ? h.max : nil)) | \(h.count) |")
        }
        lines += ["", Self.footnote]
        return lines.joined(separator: "\n")
    }

    var logLine: String {
        "\(stream.summary); \(lengthText), \(String(format: "%.1f", presentedFPS)) fps; "
            + rows.map { "\($0.name) p50 \(Self.ms($0.histogram.percentile(0.5))) p95 \(Self.ms($0.histogram.percentile(0.95)))" }
                .joined(separator: ", ")
            + "; \(countersText)" + (clockText.map { "; " + $0 } ?? "")
    }
}
