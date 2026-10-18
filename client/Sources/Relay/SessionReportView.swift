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
                Text(verbatim: "\(report.endedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.lengthText)")
                    .foregroundStyle(.secondary)
                Text(verbatim: report.stream.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: Style.Space.m) {
                tile(measure.prefix(1).uppercased() + measure.dropFirst() + ", median", value: summary.median, unit: "ms",
                     graded: true)
                tile("95% of frames within", value: summary.p95, unit: "ms", graded: true)
                tile("Frames shown", value: report.presentedFPS, unit: "fps", graded: false)
            }

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

    private func tile(_ title: String, value: Double?, unit: String, graded: Bool) -> some View {
        let color: Color = graded ? value.map(level) ?? .primary : .primary
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                Text(verbatim: unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Style.Space.m)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "1 frame (8.3 ms)" for the Mac's share, "3 frames (25.0 ms)" end to end.
    private var budgetLabel: String {
        let frames = Int((summary.budget / (1_000 / Double(max(report.stream.fps, 1)))).rounded())
        return String(format: "%d frame%@ (%.1f ms)", frames, frames == 1 ? "" : "s", summary.budget)
    }

    /// The median of each second, so a slow stretch shows where it happened.
    private var timeline: some View {
        let points = report.timeline.enumerated().compactMap { i, v in v.map { (second: i, ms: $0) } }
        return VStack(alignment: .leading, spacing: Style.Space.xs) {
            Text(verbatim: "Over the session, median per second").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(points, id: \.second) { p in
                    LineMark(x: .value("Second", p.second), y: .value("ms", p.ms))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                }
                RuleMark(y: .value("Budget", summary.budget))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let s = value.as(Int.self) { Text(verbatim: String(format: "%d:%02d", s / 60, s % 60)) }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
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
        return Chart {
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
                    Text(verbatim: budgetLabel).font(.caption2).foregroundStyle(.secondary)
                }
        }
        // Room for the budget label above the bars, clear of the timeline.
        .padding(.top, Style.Space.m)
        .chartXScale(domain: 0...(limit + barWidth))
        .chartXAxisLabel(measure.prefix(1).uppercased() + measure.dropFirst() + " (ms)")
        .chartYAxis(.hidden)
        .frame(height: 110)
    }

    /// Where the time went, as in the HUD: one bar, then each machine with
    /// its parts.
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Style.Space.s) {
            Text("Where the time went, median").font(.caption).foregroundStyle(.secondary)
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
                GridRow(alignment: .firstTextBaseline) {
                    Color.clear.frame(width: 8, height: 8)
                    Text(verbatim: summary.inputLabel)
                    Text(verbatim: Self.milliseconds(summary.input)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Color.clear.frame(width: 8, height: 8)
                    Text(verbatim: report.skippedText)
                        .gridCellColumns(2)
                        .foregroundStyle((report.skippedFraction ?? 0) >= 0.05 ? Color(cgColor: StatsHUD.Level.warning.color)
                                                                                : .primary)
                }
            }
        }
    }

    /// Everything else: every stage's percentiles, the counters, the link
    /// rate, the clock estimate and what the numbers do not cover.
    private var details: some View {
        VStack(alignment: .leading, spacing: Style.Space.m) {
            Grid(alignment: .trailing, horizontalSpacing: Style.Space.l, verticalSpacing: 6) {
                GridRow {
                    Text("Stage (ms)").gridColumnAlignment(.leading)
                    Text("p50"); Text("p95"); Text("p99"); Text("max"); Text("samples")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(report.rows) { row in
                    GridRow {
                        Text(verbatim: row.name).gridColumnAlignment(.leading)
                        Text(verbatim: SessionReport.ms(row.histogram.percentile(0.5)))
                        Text(verbatim: SessionReport.ms(row.histogram.percentile(0.95)))
                        Text(verbatim: SessionReport.ms(row.histogram.percentile(0.99)))
                        Text(verbatim: SessionReport.ms(row.histogram.count > 0 ? row.histogram.max : nil))
                        Text(verbatim: "\(row.histogram.count)").foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: report.countersText.prefix(1).uppercased() + report.countersText.dropFirst())
                if let link = report.linkText { Text(verbatim: link) }
                if let clock = report.clockText { Text(verbatim: clock) }
            }
            .font(.callout).foregroundStyle(.secondary)
            Text(verbatim: SessionReport.footnote)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "–" }
}
