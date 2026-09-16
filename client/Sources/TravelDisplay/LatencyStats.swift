import Foundation

/// Thread-safe rolling latency samples. Frame callbacks arrive on the network
/// queue while the overlay polls snapshots on the main thread.
final class LatencyStats {
    struct Snapshot {
        let fps: Double
        let hostMedian: Double?
        let hostP95: Double?
        let networkMedian: Double?
        let clientAverage: Double?
        let enqueueMedian: Double?
        let totalEstimate: Double?
        let droppedFrames: Int?
        let samples: Int

        var overlayText: String {
            func ms(_ value: Double?) -> String {
                value.map { String(format: "%6.2f ms", $0) } ?? "      --"
            }
            var lines = [
                String(format: "FPS          %6.1f", fps),
                "Total est.   \(ms(totalEstimate))",
                "Host         \(ms(hostMedian))",
                "Network ~    \(ms(networkMedian))",
                "Client       \(ms(clientAverage))",
            ]
            if clientAverage == nil {
                lines.append("  enqueue    \(ms(enqueueMedian))")
                lines.append("  display       hidden")
            }
            lines.append("Host p95     \(ms(hostP95))")
            if let droppedFrames {
                lines.append(String(format: "Dropped      %6d", droppedFrames))
            }
            lines.append(String(format: "Samples      %6d", samples))
            return lines.joined(separator: "\n")
        }
    }

    private let lock = NSLock()
    private static let capacity = 600
    private var host: [Double] = []
    private var network: [Double] = []
    private var enqueue: [Double] = []
    private var clientAverage: Double?
    private var droppedFrames: Int?
    private var framesSinceSnapshot = 0
    private var lastSnapshotAt = DispatchTime.now().uptimeNanoseconds
    private var lastFrameSequence: UInt64?

    func reset() {
        lock.lock()
        host.removeAll(keepingCapacity: true)
        network.removeAll(keepingCapacity: true)
        enqueue.removeAll(keepingCapacity: true)
        clientAverage = nil
        droppedFrames = nil
        framesSinceSnapshot = 0
        lastFrameSequence = nil
        lastSnapshotAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func recordFrame(sequence: UInt64, enqueueMilliseconds: Double) {
        lock.lock()
        Self.append(enqueueMilliseconds, to: &enqueue)
        lastFrameSequence = sequence
        framesSinceSnapshot += 1
        lock.unlock()
    }

    func record(_ timing: Proto.FrameTiming) {
        lock.lock()
        guard lastFrameSequence == timing.sequence else {
            lock.unlock()
            return
        }
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

    func recordVideoPerformance(_ snapshot: VideoPerformanceSnapshot) {
        lock.lock()
        clientAverage = snapshot.clientMilliseconds
        droppedFrames = snapshot.droppedFrames
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
        let total = [hostMedian, networkMedian, clientAverage]
        let totalEstimate = total.allSatisfy { $0 != nil }
            ? total.compactMap { $0 }.reduce(0, +)
            : nil
        return Snapshot(
            fps: fps,
            hostMedian: hostMedian,
            hostP95: percentile(host, 0.95),
            networkMedian: networkMedian,
            clientAverage: clientAverage,
            enqueueMedian: percentile(enqueue, 0.5),
            totalEstimate: totalEstimate,
            droppedFrames: droppedFrames,
            samples: host.count
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
