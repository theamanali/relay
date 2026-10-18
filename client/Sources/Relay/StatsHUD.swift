import AppKit
import CoreText

/// ⌃⌥⌘L cycles through these.
enum HUDMode: String, CaseIterable, Sendable {
    case off, compact, detailed

    var title: String {
        switch self {
        case .off: "Off"
        case .compact: "Compact"
        case .detailed: "Detailed"
        }
    }

    var next: HUDMode {
        switch self {
        case .off: .compact
        case .compact: .detailed
        case .detailed: .off
        }
    }
}

/// Draws the latency HUD into a bitmap a few times a second. The presenter
/// blends that bitmap into the video frame itself, so the stream stays one
/// opaque layer and macOS can still send it straight to the display; a view
/// on top of the layer cost about 2.5 ms of time to screen (docs/LATENCY.md).
/// CoreText and CoreGraphics only, so it can run off the main thread.
enum StatsHUD {
    static let width: CGFloat = 236
    /// Distance from the screen's top-left corner, in points.
    static let margin: CGFloat = 16
    private static let padding: CGFloat = 12
    private static let sparklineHeight: CGFloat = 36
    private static let rowHeight: CGFloat = 17

    enum Level: Equatable {
        case good, warning, bad

        /// Against one refresh interval: comfortably inside, close, over.
        init(value: Double, budget: Double) {
            self = value <= budget * 0.75 ? .good : value <= budget ? .warning : .bad
        }

        var color: CGColor {
            switch self {
            case .good: CGColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
            case .warning: CGColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
            case .bad: CGColor(srgbRed: 1, green: 0.41, blue: 0.38, alpha: 1)
            }
        }
    }

    private static let primary = CGColor(gray: 1, alpha: 0.95)
    private static let secondary = CGColor(gray: 1, alpha: 0.55)
    private static let hairline = CGColor(gray: 1, alpha: 0.14)

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) as CTFont
    }

    /// Premultiplied BGRA at `scale` pixels per point; nil when off.
    static func render(_ s: LatencyStats.HUDSnapshot, mode: HUDMode, scale: CGFloat) -> CGImage? {
        guard mode != .off else { return nil }
        let height = height(for: s, mode: mode)
        let pw = Int((width * scale).rounded(.up)), ph = Int((height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Top-down points, like a flipped view.
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let canvas = Canvas(ctx: ctx)

        let panel = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1),
                           cornerWidth: 11, cornerHeight: 11, transform: nil)
        ctx.addPath(panel)
        ctx.setFillColor(CGColor(gray: 0.07, alpha: 0.9))
        ctx.fillPath()
        ctx.addPath(panel)
        ctx.setStrokeColor(hairline)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let summary = Summary(s)
        let inner = width - 2 * padding
        var y = padding

        // Headline: PC → this screen when the clocks are synced, else the
        // Mac's own share; colored against its budget.
        let level = summary.median.map { Level(value: $0, budget: summary.budget) }
        let big = canvas.text(summary.median.map { String(format: "%.1f", $0) } ?? "––",
                              font: font(26, .semibold), color: level?.color ?? primary, x: padding, baseline: y + 25)
        canvas.text("ms", font: font(13, .medium), color: secondary, x: padding + big + 3, baseline: y + 25)
        canvas.text(String(format: "%.0f fps", s.presentedFPS), font: font(13, .semibold), color: primary,
                    right: padding + inner, baseline: y + 25)
        y += 32
        // Two columns: p95 under the latency it qualifies, skipped frames
        // (only when there are enough to matter) under the frame rate.
        let p95Level = summary.p95.map { Level(value: $0, budget: summary.budget) }
        let p95Label = canvas.text("p95: ", font: font(11), color: secondary, x: padding, baseline: y + 10)
        canvas.text(milliseconds(summary.p95), font: font(11, .medium), color: p95Level?.color ?? secondary,
                    x: padding + p95Label, baseline: y + 10)
        if summary.skipping {
            canvas.text(String(format: "%.0f skipped/s", summary.skippedPerSecond), font: font(11, .medium),
                        color: Level.warning.color, right: padding + inner, baseline: y + 10)
        }
        y += headerSecondLine
        // Without clock sync the headline is the Mac's share alone; say so,
        // since nothing else on the HUD names its measure.
        if let note = summary.unsyncedNote {
            canvas.text(note, font: font(10), color: secondary, x: padding, baseline: y + 10)
            y += unsyncedLine
        }
        y += headerToSparkline

        sparkline(ctx: ctx, canvas: canvas, values: summary.sparkline, budget: summary.budget,
                  frame: CGRect(x: padding, y: y, width: inner, height: sparklineHeight))
        y += sparklineHeight

        guard mode == .detailed else { return ctx.makeImage() }

        y += gap
        divider(ctx, y: y)
        y += gap

        // Where the time goes: one bar, then one block per machine.
        bar(ctx, segments: summary.groups.map { ($0.milliseconds ?? 0, $0.color) },
            frame: CGRect(x: padding, y: y, width: inner, height: barHeight))
        y += barHeight + gap
        for group in summary.groups {
            ctx.setFillColor(group.color)
            ctx.fillEllipse(in: CGRect(x: padding, y: y + 4.5, width: 7, height: 7))
            canvas.text(group.name, font: font(11, .medium), color: primary, x: padding + 12, baseline: y + 12)
            canvas.text(milliseconds(group.milliseconds), font: font(11, .medium), color: primary,
                        right: padding + inner, baseline: y + 12)
            y += rowHeight
            canvas.text(group.detail, font: font(10), color: secondary, x: padding + 12, baseline: y + 10,
                        maxWidth: inner - 12)
            y += detailHeight
        }

        y += gap - 4
        divider(ctx, y: y)
        y += gap - 2
        canvas.text(summary.inputLabel, font: font(11), color: secondary, x: padding, baseline: y + 12)
        canvas.text(milliseconds(summary.input), font: font(11, .medium), color: primary,
                    right: padding + inner, baseline: y + 12)
        y += rowHeight

        if let stream = s.stream {
            y += gap - 4
            divider(ctx, y: y)
            y += gap - 2
            // Label / value rows, like the rows above, instead of loose lines.
            // The settings are fixed for the session; only Data moves, so
            // it is the one drawn at full strength.
            for (label, value) in streamRows(stream, receivedMbps: s.receivedMbps) {
                canvas.text(label, font: font(10), color: secondary, x: padding, baseline: y + 11)
                canvas.text(value, font: font(10, .medium), color: label == "Data" ? primary : CGColor(gray: 1, alpha: 0.7),
                            right: padding + inner, baseline: y + 11, maxWidth: inner - streamLabelWidth)
                y += streamLineHeight
            }
        }
        return ctx.makeImage()
    }

    private static let gap: CGFloat = 10
    private static let headerSecondLine: CGFloat = 15
    private static let headerToSparkline: CGFloat = 6
    private static let unsyncedLine: CGFloat = 14
    private static let barHeight: CGFloat = 6
    private static let detailHeight: CGFloat = 15
    private static let streamLineHeight: CGFloat = 15
    /// Room kept for the widest label ("Picture") left of a value.
    static let streamLabelWidth: CGFloat = 52

    static func height(for s: LatencyStats.HUDSnapshot, mode: HUDMode) -> CGFloat {
        let compact = padding + 32 + headerSecondLine + (Summary(s).unsyncedNote == nil ? 0 : unsyncedLine)
            + headerToSparkline + sparklineHeight + padding
        guard mode == .detailed else { return compact }
        let breakdown = 2 * gap + barHeight + gap + 3 * (rowHeight + detailHeight)
        let footer = (gap - 4) + (gap - 2) + rowHeight
        let stream = s.stream.map {
            (gap - 4) + (gap - 2) + CGFloat(streamRows($0, receivedMbps: s.receivedMbps).count) * streamLineHeight
        } ?? 0
        return compact + breakdown + footer + stream
    }

    /// What the HUD shows, decided apart from the drawing so it can be
    /// tested: the headline, the per-machine breakdown and the fallbacks for
    /// a PC without clock sync.
    struct Summary: Equatable {
        struct Group: Equatable {
            let name: String
            let milliseconds: Double?
            let detail: String
            let color: CGColor
        }

        /// The headline and its sparkline: desktop → screen once synced.
        /// The HUD leaves the label out; the session report names its measure with it.
        let label: String
        /// Shown under the header only without clock sync.
        let unsyncedNote: String?
        let median: Double?
        let p95: Double?
        let sparkline: [Double]
        /// The budget the headline is colored against: one refresh for the
        /// Mac's share, three for PC → screen, which spans capture, encode,
        /// the network and display.
        let budget: Double
        let groups: [Group]
        let inputLabel: String
        let input: Double?
        let skippedPerSecond: Double
        /// Enough skipped frames to point out: one a second, or 5 %.
        let skipping: Bool

        static let pcColor = CGColor(srgbRed: 0.39, green: 0.62, blue: 1, alpha: 1)
        static let networkColor = CGColor(srgbRed: 0.75, green: 0.55, blue: 1, alpha: 1)
        static let macColor = CGColor(srgbRed: 0.3, green: 0.84, blue: 0.74, alpha: 1)

        init(_ s: LatencyStats.HUDSnapshot) {
            let endToEnd = s.desktopToScreen.p50 != nil
            label = endToEnd ? "PC → your screen, median" : "receive → screen, median"
            unsyncedNote = endToEnd ? nil : "Receive → screen, clock not synced"
            median = endToEnd ? s.desktopToScreen.p50 : s.toScreen.p50
            p95 = endToEnd ? s.desktopToScreen.p95 : s.toScreen.p95
            sparkline = endToEnd ? s.desktopSparkline : s.sparkline
            budget = s.frameBudget * (endToEnd ? 3 : 1)

            let work = s.host.p50
            let pc: Double? = work.map { $0 + (s.contentAge.p50 ?? 0) }
            let pcDetail = s.contentAge.p50.map { "image age \(StatsHUD.ms($0)), encode & send \(StatsHUD.ms(work))" }
                ?? "capture, encode & send"
            let measured = s.sentToReceived.p50
            let network = measured ?? s.networkHalfRTT
            let mac = s.toScreen.p50
            let display = mac.flatMap { m in s.decode.p50.map { max(0, m - $0) } }
            groups = [
                Group(name: "PC", milliseconds: pc, detail: pcDetail, color: Self.pcColor),
                Group(name: "Network", milliseconds: network,
                      detail: measured != nil ? "one way" : "half a ping round trip",
                      color: Self.networkColor),
                Group(name: "Mac", milliseconds: mac,
                      detail: "decode \(StatsHUD.ms(s.decode.p50)), display \(StatsHUD.ms(display))",
                      color: Self.macColor),
            ]
            let applied = s.inputApplied.p50
            inputLabel = applied != nil || endToEnd ? "Input → PC" : "Input → sent"
            input = applied ?? (endToEnd ? nil : s.inputSent.p50)
            // Clamp before rounding: a window with a few more shown than decoded
            // rounds to −0, which max(0, −0) keeps and prints as "-0".
            skippedPerSecond = max(0, s.decodedFPS - s.presentedFPS).rounded()
            skipping = skippedPerSecond >= max(1, s.decodedFPS * 0.05)
        }
    }

    /// The stream as label / value rows. Data is the video actually
    /// arriving against the bitrate asked for ("48 of 120 Mbps").
    static func streamRows(_ s: StreamInfo, receivedMbps: Double?) -> [(String, String)] {
        var rows = [("Video", "\(s.codec) \(s.width)×\(s.height) @ \(s.fps) Hz")]
        if !s.format.isEmpty { rows.append(("Picture", s.format)) }
        // VSync off is the default; only the exception takes a row.
        if s.vsync { rows.append(("Display", "VSync on")) }
        if let link = s.link { rows.append(("Link", link)) }
        rows.append(("Data", "\(receivedMbps.map { String(format: "%.0f", $0) } ?? "––") of \(s.bitrateMbps) Mbps"))
        return rows
    }

    private static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "––" }

    /// Proportional segments with a sliver of space between them; empty
    /// segments are left out, and one too short to see still gets a few
    /// points (the network is often under 3 % of the total).
    private static func bar(_ ctx: CGContext, segments: [(Double, CGColor)], frame: CGRect) {
        let total = segments.reduce(0) { $0 + max(0, $1.0) }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2,
                           transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.08))
        ctx.fill(frame)
        if total > 0 {
            // Short segments take their minimum out of the rest's share.
            let shown = segments.filter { $0.0 > 0 }
            let minimum: CGFloat = 4
            let raw = shown.map { frame.width * CGFloat($0.0 / total) }
            let short = raw.filter { $0 < minimum }
            let long = raw.filter { $0 >= minimum }.reduce(0, +)
            let squeeze = long > 0 ? (frame.width - minimum * CGFloat(short.count)) / long : 1
            var x = frame.minX
            for ((_, color), w) in zip(shown, raw) {
                let width = w < minimum ? minimum : w * squeeze
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: x, y: frame.minY, width: max(1, width - 1.5), height: frame.height))
                x += width
            }
        }
        ctx.restoreGState()
    }

    fileprivate static func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "––" }

    private static func divider(_ ctx: CGContext, y: CGFloat) {
        ctx.setFillColor(hairline)
        ctx.fill(CGRect(x: padding, y: y, width: width - 2 * padding, height: 1))
    }

    /// The worst frame in each point-wide column, oldest on the left, so a
    /// single slow frame stays a visible peak instead of aliasing between
    /// samples. The window is always `sparklineFrames` wide; a short history
    /// fills the right-hand columns.
    static func columnMaxima(_ values: [Double], columns: Int) -> [Double] {
        guard columns > 0, !values.isEmpty else { return [] }
        let span = Double(max(values.count, LatencyStats.sparklineFrames)) / Double(columns)
        let offset = max(values.count, LatencyStats.sparklineFrames) - values.count
        var out: [Double] = []
        for c in 0..<columns {
            let lo = max(0, Int((Double(c) * span).rounded(.down)) - offset)
            let hi = min(values.count, Int((Double(c + 1) * span).rounded(.down)) - offset)
            if lo < hi { out.append(values[lo..<hi].max()!) }
        }
        return out
    }

    /// Time to screen per frame; a dashed line marks the budget, and the
    /// part of the curve above it is drawn red.
    private static func sparkline(ctx: CGContext, canvas: Canvas, values: [Double], budget: Double, frame: CGRect) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.05))
        ctx.fill(frame)
        let top = max(budget * 1.5, min(values.max() ?? 0, budget * 4))
        func y(_ v: Double) -> CGFloat { frame.maxY - CGFloat(min(v, top) / top) * frame.height }
        let columns = columnMaxima(values, columns: Int(frame.width))
        if columns.count > 1 {
            let start = frame.maxX - CGFloat(columns.count - 1)
            let line = CGMutablePath()
            for (i, v) in columns.enumerated() {
                let p = CGPoint(x: start + CGFloat(i), y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            let area = line.mutableCopy()!
            area.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            area.addLine(to: CGPoint(x: start, y: frame.maxY))
            area.closeSubpath()
            ctx.addPath(area)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
            ctx.fillPath()
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: frame.minX, y: y(budget), width: frame.width, height: frame.maxY - y(budget)))
            ctx.addPath(line)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
            ctx.strokePath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: y(budget) - frame.minY))
            ctx.addPath(line)
            ctx.setStrokeColor(Level.bad.color)
            ctx.strokePath()
            ctx.restoreGState()
        }
        let by = y(budget)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.4))
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: CGPoint(x: frame.minX, y: by))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: by))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        // The limit's value on a chip in the panel color, so the curve
        // never runs through the digits.
        let label = String(format: "%.0f ms", budget)
        let labelFont = font(9, .medium)
        let labelWidth = canvas.width(label, font: labelFont)
        let chip = CGRect(x: frame.minX, y: by - 6, width: labelWidth + 8, height: 12)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fillPath()
        canvas.text(label, font: labelFont, color: secondary, x: chip.minX + 4, baseline: by + 3)
    }

    /// One-line CoreText drawing in the flipped context.
    private struct Canvas {
        let ctx: CGContext

        func width(_ string: String, font: CTFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        @discardableResult
        func text(_ string: String, font: CTFont, color: CGColor, x: CGFloat? = nil, right: CGFloat? = nil,
                  baseline: CGFloat, maxWidth: CGFloat? = nil) -> CGFloat {
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            var line = CTLineCreateWithAttributedString(attributed)
            var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if let maxWidth, width > maxWidth,
               let truncated = CTLineCreateTruncatedLine(line, maxWidth, .end,
                    CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    ]))) {
                line = truncated
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
            ctx.textPosition = CGPoint(x: right.map { $0 - width } ?? x ?? 0, y: baseline)
            CTLineDraw(line, ctx)
            return width
        }
    }
}
