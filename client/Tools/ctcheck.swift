// Timing check for the Elligator 2 map that turns the pairing PIN into a
// curve point (Sources/Relay/Field25519.swift). The map's input is derived
// from the PIN, so its running time must not depend on that input.
//
// Method: dudect (Reparaz, Balasch, Verbauwhede, "Dude, is my code constant
// time?", 2017). Time the map on two classes of input, one fixed value and
// fresh random values, interleaved in random order; drop the slowest
// measurements at several cut-offs; compare the classes with Welch's t-test.
// |t| above 10 is a timing difference beyond reasonable doubt; under 4.5 is
// no evidence of one.
//
//   swiftc -O -parse-as-library -o ctcheck Tools/ctcheck.swift Sources/Relay/Field25519.swift
//   ./ctcheck            # 200000 measurements, about a minute
//   ./ctcheck 50000
//
// Run it on an otherwise idle machine. Exit status 1 when |t| > 10.
import Foundation

func randomBytes(_ n: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
}

/// Welch's t over the measurements at or under `cutoff` nanoseconds.
func welch(_ times: [UInt64], _ classes: [Int], cutoff: UInt64) -> (t: Double, n0: Int, n1: Int) {
    var n = [0.0, 0.0], mean = [0.0, 0.0], m2 = [0.0, 0.0]
    for i in 0..<times.count where times[i] <= cutoff {
        let c = classes[i]
        let x = Double(times[i])
        n[c] += 1
        let delta = x - mean[c]
        mean[c] += delta / n[c]
        m2[c] += delta * (x - mean[c])
    }
    guard n[0] > 1, n[1] > 1 else { return (0, Int(n[0]), Int(n[1])) }
    let v0 = m2[0] / (n[0] - 1), v1 = m2[1] / (n[1] - 1)
    let t = (mean[0] - mean[1]) / (v0 / n[0] + v1 / n[1]).squareRoot()
    return (t, Int(n[0]), Int(n[1]))
}

@main
enum CTCheck {
    static func main() {
        setbuf(stdout, nil)
        let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 200_000 : 200_000

        // Everything random is prepared before timing starts.
        let fixed = randomBytes(32)
        var classes = [Int](repeating: 0, count: count)
        var inputs = [Data]()
        inputs.reserveCapacity(count)
        for i in 0..<count {
            classes[i] = Int.random(in: 0...1)
            inputs.append(classes[i] == 0 ? fixed : randomBytes(32))
        }

        // Warm up caches and branch predictors.
        var sink: UInt8 = 0
        for i in 0..<min(2000, count) { sink ^= Elligator2.map(inputs[i]).first! }

        var times = [UInt64](repeating: 0, count: count)
        for i in 0..<count {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let u = Elligator2.map(inputs[i])
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            sink ^= u.first!
            times[i] = end - start
        }

        let sorted = times.sorted()
        let median = sorted[count / 2]
        print("map: \(count) measurements, median \(median) ns (sink \(sink))")
        var worst = 0.0
        for percentile in [0.5, 0.75, 0.9, 0.95, 0.99, 1.0] {
            let cutoff = sorted[min(count - 1, Int(Double(count) * percentile))]
            let (t, n0, n1) = welch(times, classes, cutoff: cutoff)
            worst = max(worst, abs(t))
            print(String(format: "  fastest %3.0f%%  (<= %6llu ns): t = %+7.2f   fixed %d, random %d",
                         percentile * 100, cutoff, t, n0, n1))
        }
        if worst > 10 {
            print(String(format: "LEAK: |t| = %.1f > 10, the map's time depends on its input", worst))
            exit(1)
        } else if worst > 4.5 {
            print(String(format: "inconclusive: |t| = %.1f; rerun on an idle machine with more measurements", worst))
        } else {
            print(String(format: "ok: max |t| = %.2f, no evidence of input-dependent timing", worst))
        }
    }
}
