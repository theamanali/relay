import AppKit
import Charts
import SwiftUI

/// View ▸ Last Session Report: the whole session's numbers, opened by itself
/// when a session ends with the latency HUD on. It reads like the HUD: the
/// same headline (PC → your screen once the clocks are synced), the same
/// PC / Network / Mac breakdown; Details swaps the charts for the full stage
/// table (in place, so the window fits a laptop screen either way).
/// Copy gives everything as Markdown for docs/LATENCY.md.
struct SessionReportView: View {
    let report: SessionReport
    @State private var copied = false
    /// Bumped on every click, so only the newest one turns "Copied" back.
    @State private var copies = 0
    @State private var page = Page.summary

    enum Page: Hashable { case summary, details }

    private var summary: StatsHUD.Summary { report.summary }
    /// "PC → your screen" or "receive → screen".
    private var measure: String { summary.label.replacingOccurrences(of: ", median", with: "") }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: report.stream.host).font(.title3.weight(.semibold))
                    Spacer()
                    Picker("Show", selection: $page) {
                        Text("Summary").tag(Page.summary)
                        Text("Details").tag(Page.details)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(verbatim: "\(report.endedAt.formatted(date: .abbreviated, time: .shortened)) for \(report.lengthText)")
                    .foregroundStyle(.secondary)
                Text(verbatim: report.stream.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            header

            switch page {
            case .summary:
                if report.timeline.compactMap({ $0 }).count > 1 { timeline }
                histogram
                breakdown
            case .details:
                details
            }

            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.markdown, forType: .string)
                    copied = true
                    copies += 1
                    let click = copies
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        if copies == click { copied = false }
                    }
                }
            }
        }
        .padding(Style.Space.margin)
        .frame(width: Self.width)
    }

    /// Wide enough for `StreamInfo.widest` on one line, never under 520.
    static var width: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let text = (StreamInfo.widest.summary as NSString).size(withAttributes: [.font: font]).width
        return max(520, ceil(text) + 2 * Style.Space.margin)
    }

    private func level(_ value: Double) -> Color {
        Color(cgColor: StatsHUD.Level(value: value, budget: summary.budget).color)
    }

    /// The HUD's header at the report's size: the median, graded, with p95
    /// under it; frames shown with the share skipped under that.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Style.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: summary.median.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(summary.median.map(level) ?? .primary)
                    Text(verbatim: "ms").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    Text(verbatim: "p95: ").foregroundStyle(.secondary)
                    Text(verbatim: Self.milliseconds(summary.p95)).fontWeight(.medium).monospacedDigit()
                        .foregroundStyle(summary.p95.map(level) ?? .secondary)
                }
                .font(.callout)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Style.Space.tight) {
                Text(verbatim: String(format: "%.1f fps", report.presentedFPS))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                if let skipped = skippedText {
                    Text(verbatim: skipped).font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle((report.skippedFraction ?? 0) >= 0.05
                                         ? Color(cgColor: StatsHUD.Level.warning.color) : .secondary)
                }
            }
        }
    }

    /// "0.2% skipped"; nil before any frame was decoded.
    private var skippedText: String? {
        report.skippedFraction.map { f in
            f > 0 && f < 0.001 ? "Under 0.1% skipped" : String(format: "%.1f%% skipped", f * 100)
        }
    }

    /// The budget as the HUD labels it.
    private var budgetLabel: String { String(format: "%.0f ms", summary.budget) }

    /// The share of frames over the budget, for the histogram's budget line.
    private var overBudget: Double? {
        let h = report.headline
        guard h.count > 0, let over = h.bars(width: summary.budget, upTo: summary.budget).last else { return nil }
        return Double(over.count) / Double(h.count)
    }

    /// The timeline cut where it crosses the budget, so the part above can be
    /// drawn red as in the HUD's sparkline.
    private struct Run: Identifiable {
        let id: Int
        let over: Bool
        var points: [(x: Double, y: Double)]
    }

    private func runs(_ points: [(second: Int, ms: Double)]) -> [Run] {
        let budget = summary.budget
        var runs: [Run] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let p = (x: Double(a.second), y: a.ms), q = (x: Double(b.second), y: b.ms)
            let aOver = p.y > budget, bOver = q.y > budget
            if runs.isEmpty || runs[runs.count - 1].over != aOver { runs.append(Run(id: runs.count, over: aOver, points: [p])) }
            if aOver != bOver {
                let cross = (x: p.x + (q.x - p.x) * (budget - p.y) / (q.y - p.y), y: budget)
                runs[runs.count - 1].points.append(cross)
                runs.append(Run(id: runs.count, over: bOver, points: [cross]))
            }
            runs[runs.count - 1].points.append(q)
        }
        return runs
    }

    /// The median of each second, so a slow stretch shows where it happened.
    private var timeline: some View {
        let points = report.timeline.enumerated().compactMap { i, v in v.map { (second: i, ms: $0) } }
        return VStack(alignment: .leading, spacing: Style.Space.m) {
            Text(verbatim: measure.prefix(1).uppercased() + measure.dropFirst() + ", median per second")
                .foregroundStyle(.secondary)
            Chart {
                ForEach(points, id: \.second) { p in
                    AreaMark(x: .value("Second", Double(p.second)), y: .value("ms", p.ms), series: .value("Run", "area"))
                        .foregroundStyle(Color.primary.opacity(0.08))
                }
                // As in the HUD: the curve in the text color, red above the budget.
                ForEach(runs(points)) { run in
                    ForEach(Array(run.points.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Second", p.x), y: .value("ms", p.y), series: .value("Run", run.id))
                            .foregroundStyle(run.over ? Color(cgColor: StatsHUD.Level.bad.color) : Color.primary.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
                RuleMark(y: .value("Budget", summary.budget))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: budgetLabel).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXScale(domain: 0...Double(max(1, report.timeline.count - 1)))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let s = value.as(Double.self).map({ Int($0) }) { Text(verbatim: String(format: "%d:%02d", s / 60, s % 60)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { Self.msLabel(value) }
                }
            }
            .chartYScale(domain: 0...max(summary.budget * 1.2, (points.map(\.ms).max() ?? 0) * 1.1))
            .frame(height: 90)
        }
    }

    /// The headline measure in bars; the last bar holds everything beyond.
    private var histogram: some View {
        let h = report.headline
        let barWidth = summary.budget > 10 ? 1.0 : 0.5
        let limit = max(summary.budget * 2, (h.percentile(0.99) ?? 0) + barWidth).rounded(.up)
        let bars = h.bars(width: barWidth, upTo: limit)
        // Captioned above, like the timeline and the breakdown.
        return VStack(alignment: .leading, spacing: Style.Space.m) {
            Text(verbatim: measure.prefix(1).uppercased() + measure.dropFirst() + ", every frame")
                .foregroundStyle(.secondary)
            Chart {
            ForEach(bars.filter { $0.count > 0 }, id: \.start) { bar in
                RectangleMark(xStart: .value("ms", bar.start + barWidth * 0.08),
                              xEnd: .value("ms", bar.start + barWidth * 0.92),
                              yStart: .value("Frames", 0), yEnd: .value("Frames", bar.count))
                    .foregroundStyle(level(bar.start + barWidth))
            }
            RuleMark(x: .value("Budget", summary.budget))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color.secondary)
                .annotation(position: .top, alignment: .leading) {
                    Text(verbatim: overBudget.map { String(format: "%@, %.1f%% of frames over", budgetLabel, $0 * 100) }
                         ?? budgetLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                }
        }
        // Room for the budget label above the bars, clear of the timeline.
        .padding(.top, Style.Space.m)
        .chartXScale(domain: 0...(limit + barWidth))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel { Self.msLabel(value) }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 110)
        }
    }

    /// Where the time went, as in the HUD: one bar, then each machine with
    /// its parts.
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Style.Space.s) {
            // Charts' first marks (axis label, budget note) sit a little
            // above their frames; this evens the visible gap under each
            // title (about 10 pt) with the bar's flat top.
            Text("Latency split by stage, median").foregroundStyle(.secondary)
                .padding(.bottom, 1.5)
            // The report's width is fixed, so the bar is sized directly: a
            // GeometryReader here fed back into the window's own sizing and
            // AppKit ended the app over an endless constraint pass.
            let total = summary.groups.reduce(0) { $0 + max(0, $1.milliseconds ?? 0) }
            let inner = Self.width - 2 * Style.Space.margin - 4
            HStack(spacing: 2) {
                ForEach(summary.groups, id: \.name) { group in
                    if let v = group.milliseconds, v > 0, total > 0 {
                        Rectangle().fill(Color(cgColor: group.color)).frame(width: max(2, inner * v / total))
                    }
                }
            }
            .frame(width: Self.width - 2 * Style.Space.margin, height: 8, alignment: .leading)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())

            Grid(alignment: .leading, horizontalSpacing: Style.Space.s, verticalSpacing: Style.Space.s) {
                ForEach(summary.groups, id: \.name) { group in
                    GridRow(alignment: .firstTextBaseline) {
                        Circle().fill(Color(cgColor: group.color)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: group.name).fontWeight(.medium)
                            Text(verbatim: group.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: Self.milliseconds(group.milliseconds))
                            .monospacedDigit().gridColumnAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                // Label / value rows, as under the HUD's breakdown.
                GridRow(alignment: .firstTextBaseline) {
                    Color.clear.frame(width: 8, height: 8)
                    Text(verbatim: summary.inputLabel).foregroundStyle(.secondary)
                    Text(verbatim: Self.milliseconds(summary.input)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let data = dataValue {
                    GridRow(alignment: .firstTextBaseline) {
                        Color.clear.frame(width: 8, height: 8)
                        Text(verbatim: "Data").foregroundStyle(.secondary)
                        Text(verbatim: data).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Everything else: every stage's percentiles, the counters, the link
    /// rate, the clock estimate and what the numbers do not cover.
    private var details: some View {
        VStack(alignment: .leading, spacing: Style.Space.l) {
            Grid(alignment: .trailing, horizontalSpacing: Style.Space.l, verticalSpacing: 6) {
                GridRow {
                    Text("Stage (ms)").gridColumnAlignment(.leading)
                    Text("p50"); Text("p95"); Text("p99"); Text("max"); Text("samples")
                }
                .foregroundStyle(.secondary)
                Divider()
                // The end-to-end measure first, then the stages grouped and
                // colored as in the Summary's split.
                ForEach(detailSections, id: \.name) { section in
                    if !section.name.isEmpty {
                        GridRow {
                            HStack(spacing: Style.Space.s) {
                                // Input has no color; a clear dot keeps its name in line.
                                Circle().fill(section.color.map { Color(cgColor: $0) } ?? .clear)
                                    .frame(width: 8, height: 8)
                                Text(verbatim: section.name).fontWeight(.semibold)
                            }
                            .gridCellColumns(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, Style.Space.s)
                    }
                    ForEach(section.rows) { row in
                        GridRow {
                            Text(verbatim: row.name).gridColumnAlignment(.leading)
                                .padding(.leading, section.name.isEmpty ? 0 : 16)
                                .fontWeight(section.name.isEmpty ? .semibold : .regular)
                            Text(verbatim: SessionReport.ms(row.histogram.percentile(0.5)))
                            Text(verbatim: SessionReport.ms(row.histogram.percentile(0.95)))
                            Text(verbatim: SessionReport.ms(row.histogram.percentile(0.99)))
                            Text(verbatim: SessionReport.ms(row.histogram.count > 0 ? row.histogram.max : nil))
                            Text(row.histogram.count, format: .number).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                }
            }
            Divider()
            // Label / value rows, as under the Summary's split.
            Grid(alignment: .leading, horizontalSpacing: Style.Space.l, verticalSpacing: Style.Space.s) {
                GridRow {
                    Text("Frames").foregroundStyle(.secondary)
                    Text(verbatim: framesValue).frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let bps = report.linkBitsPerSecond {
                    GridRow {
                        Text("Link").foregroundStyle(.secondary)
                        Text(verbatim: String(format: "Frame data at %.2f Gb/s", bps / 1e9)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if let clock = report.clock {
                    GridRow {
                        Text("Clock").foregroundStyle(.secondary)
                        Text(verbatim: String(format: "PC %+.3f ms from this Mac, best delay %.3f ms",
                                              Double(clock.offset) / 1_000, Double(clock.delay) / 1_000))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            Text(verbatim: SessionReport.footnote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct DetailSection {
        let name: String
        let color: CGColor?
        let rows: [SessionReport.Row]
    }

    private var detailSections: [DetailSection] {
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.name, $0) })
        func pick(_ names: [String]) -> [SessionReport.Row] { names.compactMap { rows[$0] } }
        return [
            DetailSection(name: "", color: nil, rows: pick(["Desktop → screen"])),
            DetailSection(name: "PC", color: StatsHUD.Summary.pcColor, rows: pick(["Content age", "PC work"])),
            DetailSection(name: "Network", color: StatsHUD.Summary.networkColor,
                          // RTT/2 only stands in for a PC without clock sync, as in the Summary.
                          rows: pick([report.sentToReceived.count > 0 ? "Sent → received" : "Network (RTT/2 est.)",
                                      "Frame transfer (est.)"])),
            DetailSection(name: "Mac", color: StatsHUD.Summary.macColor,
                          rows: pick(["Decrypt", "Receive → decode", "Receive → screen"])),
            DetailSection(name: "Input", color: nil, rows: pick(["Input → sent", "Input → applied"])),
        ]
    }

    /// "40 replaced, 3 late, 1 dropped", plus any rarer failures.
    private var framesValue: String {
        let c = report.counters
        var text = "\(c.replaced) replaced, \(c.late) late, \(c.dropped) dropped"
        if c.unavailable > 0 { text += ", \(c.unavailable) without a drawable" }
        if c.gpuFailures > 0 { text += ", \(c.gpuFailures) GPU errors" }
        return text
    }

    /// "2.5 GB, 48 of 120 Mbps on average": the HUD's Data row over the session.
    private var dataValue: String? {
        guard report.receivedBytes > 0, report.duration > 0 else { return nil }
        let bytes = Double(report.receivedBytes)
        let size = bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : String(format: "%.0f MB", bytes / 1e6)
        return String(format: "%@, %.0f of %d Mbps on average", size, bytes * 8 / report.duration / 1e6,
                      report.stream.bitrateMbps)
    }

    /// An axis value with its unit: "20 ms".
    @ViewBuilder
    private static func msLabel(_ value: AxisValue) -> some View {
        if let v = value.as(Double.self) { Text(verbatim: String(format: "%g ms", v)) }
    }

    private static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "–" }
}
