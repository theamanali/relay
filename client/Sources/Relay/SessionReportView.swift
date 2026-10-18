import AppKit
import Charts
import SwiftUI

/// View ▸ Last Session Report: the whole session's numbers, opened by itself
/// when a session ends with the latency HUD on. Copy gives the same as a
/// Markdown table for docs/LATENCY.md.
struct SessionReportView: View {
    let report: SessionReport
    @State private var copied = false

    private var budget: Double { 1_000 / Double(max(report.stream.fps, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: report.stream.host).font(.title3.weight(.semibold))
                Text(verbatim: "\(report.endedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.lengthText)")
                    .foregroundStyle(.secondary)
                Text(verbatim: report.stream.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: Style.Space.m) {
                tile("Median to screen", value: report.toScreen.percentile(0.5), unit: "ms", graded: true)
                tile("p95 to screen", value: report.toScreen.percentile(0.95), unit: "ms", graded: true)
                tile("Frames shown", value: report.presentedFPS, unit: "fps", graded: false)
            }

            histogram

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

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: report.countersText.prefix(1).uppercased() + report.countersText.dropFirst())
                    if let link = report.linkText { Text(verbatim: link) }
                }
                .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.markdown, forType: .string)
                    copied = true
                }
            }
            Text(verbatim: SessionReport.footnote)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func tile(_ title: String, value: Double?, unit: String, graded: Bool) -> some View {
        let color: Color = graded ? value.map { Color(cgColor: StatsHUD.Level(value: $0, budget: budget).color) } ?? .primary
                                  : .primary
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
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

    /// Receive → screen in half-millisecond bars, up to twice the frame
    /// interval or past the p99, whichever is further; the last bar holds
    /// everything beyond.
    private var histogram: some View {
        let limit = max(budget * 2, (report.toScreen.percentile(0.99) ?? 0) + 1).rounded(.up)
        let bars = report.toScreen.bars(width: 0.5, upTo: limit)
        return Chart {
            ForEach(bars.filter { $0.count > 0 }, id: \.start) { bar in
                RectangleMark(xStart: .value("ms", bar.start + 0.04), xEnd: .value("ms", bar.start + 0.46),
                              yStart: .value("Frames", 0), yEnd: .value("Frames", bar.count))
                    .foregroundStyle(Color(cgColor: StatsHUD.Level(value: bar.start + 0.5, budget: budget).color))
            }
            RuleMark(x: .value("Frame", budget))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color.secondary)
                .annotation(position: .top, alignment: .leading) {
                    Text(verbatim: String(format: "1 frame (%.1f ms)", budget)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: 0...(limit + 0.5))
        .chartXAxisLabel("Receive → screen (ms)")
        .chartYAxis(.hidden)
        .frame(height: 120)
    }
}
