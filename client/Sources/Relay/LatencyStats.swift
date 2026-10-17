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
    /// "4:4:4 · 10-bit · Balanced", or empty.
    var format: String
    var link: String?
    var vsync: Bool

    var summary: String {
        var parts = ["\(codec) \(width)×\(height) @ \(fps) Hz", "\(bitrateMbps) Mbps"]
        if !format.isEmpty { parts.append(format) }
        if let link { parts.append(link) }
        parts.append(vsync ? "VSync on" : "VSync off")
        return parts.joined(separator: " · ")
    }
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
        var p50: Double?
        var p95: Double?
        var p99: Double?
        init(_ h: LatencyHistogram) {
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
    private var sessionToScreen = LatencyHistogram()
    private var sessionDecode = LatencyHistogram()
    private var sessionHost = LatencyHistogram()
    private var sessionNetwork = LatencyHistogram()
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
            sessionToScreen = LatencyHistogram()
            sessionDecode = LatencyHistogram()
            sessionHost = LatencyHistogram()
            sessionNetwork = LatencyHistogram()
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
                sparkline: sparkline.ordered,
                frameBudget: 1_000 / Double(max(stream?.fps ?? 60, 1)),
                stream: stream,
                warmingUp: nanos < measuringFrom)
        }
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
                                 network: sessionNetwork, counters: counters)
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
    let counters: PresenterCounters

    struct Row: Identifiable {
        let name: String
        let histogram: LatencyHistogram
        var id: String { name }
    }

    var rows: [Row] {
        [Row(name: "Receive → screen", histogram: toScreen),
         Row(name: "Receive → decode", histogram: decode),
         Row(name: "PC work", histogram: host),
         Row(name: "Network (RTT/2 est.)", histogram: network)]
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
            "Length \(lengthText) · \(String(format: "%.1f", presentedFPS)) fps shown · \(countersText)",
            "",
            "| stage (ms) | p50 | p95 | p99 | max | frames |",
            "|---|---|---|---|---|---|",
        ]
        for row in rows {
            let h = row.histogram
            lines.append("| \(row.name) | \(Self.ms(h.percentile(0.5))) | \(Self.ms(h.percentile(0.95))) | "
                + "\(Self.ms(h.percentile(0.99))) | \(Self.ms(h.count > 0 ? h.max : nil)) | \(h.count) |")
        }
        lines += ["", "Receive starts after decryption; the stages do not add up to input-to-photon latency."]
        return lines.joined(separator: "\n")
    }

    var logLine: String {
        "\(stream.summary); \(lengthText), \(String(format: "%.1f", presentedFPS)) fps; "
            + rows.map { "\($0.name) p50 \(Self.ms($0.histogram.percentile(0.5))) p95 \(Self.ms($0.histogram.percentile(0.95)))" }
                .joined(separator: ", ")
            + "; \(countersText)"
    }
}
