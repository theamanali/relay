import Foundation

/// Thread-safe rolling latency samples. Host timing arrives on the network
/// queue, decoded-frame timing arrives on VideoToolbox threads, and the overlay
/// polls snapshots on the main thread.
/// All mutable measurements are protected by lock.
final class LatencyStats: @unchecked Sendable {
    struct Snapshot {
        let fps: Double
        let hostMedian: Double?
        let hostP95: Double?
        let networkMedian: Double?
        let clientAverage: Double?
        let decodeMedian: Double?
        let totalEstimate: Double?
        let droppedFrames: Int?
        let samples: Int
        var clientP95: Double? = nil
        var performance: VideoPerformanceSnapshot? = nil

        var overlayText: String {
            func ms(_ value: Double?) -> String {
                value.map { String(format: "%6.2f ms", $0) } ?? "      --"
            }
            var lines = [
                String(format: "Decode FPS   %6.1f", fps),
                "Host work p50 \(ms(hostMedian))",
                "RTT/2 est.    \(ms(networkMedian))",
            ]
            lines.append("Rx→decode p50 \(ms(decodeMedian))")
            if let p = performance {
                if p.backend == "metal" {
                    lines.append("Metal Rx→present (last \(p.samples))")
                    lines.append("  mean        \(ms(p.clientMilliseconds))")
                    lines.append("  p95         \(ms(p.clientP95))")
                    lines.append("Session counts:")
                    lines.append("  replaced    \(p.replaced)")
                    lines.append("  late output \(p.late)")
                    lines.append("  no drawable/command \(p.unavailable)")
                    lines.append("  zero-time callbacks \(p.droppedFrames)")
                    lines.append("  GPU errors  \(p.gpuFailures)")
                    lines.append("  invalid timing \(p.invalidTimes)")
                } else {
                    lines.append("AV scheduling delay (cumulative)")
                    lines.append("  mean        \(ms(p.clientMilliseconds))")
                    lines.append("AV reported drops \(p.droppedFrames)")
                    lines.append("Rx→present unavailable")
                }
            } else { lines.append("Presentation metrics unavailable") }
            lines.append("Host p95     \(ms(hostP95))")
            lines.append("Host samples \(samples) (last 600)")
            lines.append("Rx starts after decrypt; not input→photon")
            return lines.joined(separator: "\n")
        }
    }

    private let lock = NSLock()
    private static let capacity = 600
    private var host: [Double] = []
    private var network: [Double] = []
    private var decode: [Double] = []
    private var clientAverage: Double?
    private var clientP95: Double?
    private var droppedFrames: Int?
    private var performance: VideoPerformanceSnapshot?
    private var framesSinceSnapshot = 0
    private var lastSnapshotAt = DispatchTime.now().uptimeNanoseconds

    func reset() {
        lock.lock()
        host.removeAll(keepingCapacity: true)
        network.removeAll(keepingCapacity: true)
        decode.removeAll(keepingCapacity: true)
        clientAverage = nil
        clientP95 = nil
        droppedFrames = nil
        performance = nil
        framesSinceSnapshot = 0
        lastSnapshotAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func recordFrame(sequence _: UInt64, decodeMilliseconds: Double) {
        lock.lock()
        if decodeMilliseconds.isFinite && decodeMilliseconds >= 0 {
            Self.append(decodeMilliseconds, to: &decode)
        }
        framesSinceSnapshot += 1
        lock.unlock()
    }

    func record(_ timing: Proto.FrameTiming) {
        lock.lock()
        let fields = [timing.captureMicros, timing.encodeMicros, timing.sendMicros]
        if fields.allSatisfy({ $0 != Proto.FrameTiming.unknownMicros }) {
            Self.append(fields.reduce(0) { $0 + Double($1) / 1_000 }, to: &host)
        }
        if timing.networkRTTMicros != Proto.FrameTiming.unknownMicros {
            // Direct Ethernet is close to symmetric. This is deliberately
            // labelled as an estimate in the overlay.
            Self.append(Double(timing.networkRTTMicros) / 2_000, to: &network)
        }
        lock.unlock()
    }

    func recordVideoPerformance(_ snapshot: VideoPerformanceSnapshot?) {
        lock.lock()
        performance = snapshot
        clientAverage = snapshot?.clientMilliseconds
        clientP95 = snapshot?.clientP95
        droppedFrames = snapshot?.droppedFrames
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = max(Double(now - lastSnapshotAt) / 1_000_000_000, 0.001)
        let fps = Double(framesSinceSnapshot) / seconds
        framesSinceSnapshot = 0
        lastSnapshotAt = now

        let hostMedian = percentile(host, 0.5)
        let networkMedian = percentile(network, 0.5)
        return Snapshot(
            fps: fps,
            hostMedian: hostMedian,
            hostP95: percentile(host, 0.95),
            networkMedian: networkMedian,
            clientAverage: clientAverage,
            decodeMedian: percentile(decode, 0.5),
            totalEstimate: nil,
            droppedFrames: droppedFrames,
            samples: host.count,
            clientP95: clientP95,
            performance: performance
        )
    }

    private static func append(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }
}
