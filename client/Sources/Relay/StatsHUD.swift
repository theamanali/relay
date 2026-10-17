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
        ctx.setFillColor(CGColor(gray: 0.07, alpha: 0.78))
        ctx.fillPath()
        ctx.addPath(panel)
        ctx.setStrokeColor(hairline)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let budget = s.frameBudget
        let inner = width - 2 * padding
        var y = padding

        // Headline: median time to screen, colored against the budget.
        let level = s.toScreen.p50.map { Level(value: $0, budget: budget) }
        let big = canvas.text(s.toScreen.p50.map { String(format: "%.1f", $0) } ?? "––",
                              font: font(26, .semibold), color: level?.color ?? primary, x: padding, baseline: y + 25)
        canvas.text("ms", font: font(13, .medium), color: secondary, x: padding + big + 3, baseline: y + 25)
        canvas.text(String(format: "%.0f fps", s.presentedFPS), font: font(13, .semibold), color: primary,
                    right: padding + inner, baseline: y + 14)
        let p95Level = s.toScreen.p95.map { Level(value: $0, budget: budget) }
        canvas.text("p95 " + ms(s.toScreen.p95), font: font(11, .medium), color: p95Level?.color ?? secondary,
                    right: padding + inner, baseline: y + 29)
        y += 32
        canvas.text("receive → screen, median", font: font(10), color: secondary, x: padding, baseline: y + 9)
        y += 18

        sparkline(ctx: ctx, canvas: canvas, values: s.sparkline, budget: budget,
                  frame: CGRect(x: padding, y: y, width: inner, height: sparklineHeight))
        y += sparklineHeight

        guard mode == .detailed else { return ctx.makeImage() }

        y += 10
        divider(ctx, y: y)
        y += 6
        let rows: [(String, String, CGColor)] = [
            ("p99 to screen", ms(s.toScreen.p99), s.toScreen.p99.map { Level(value: $0, budget: budget).color } ?? primary),
            ("PC work p50 / p95", ms(s.host.p50) + " / " + ms(s.host.p95), primary),
            ("Network (RTT/2)", ms(s.networkHalfRTT), primary),
            ("Receive → decode", ms(s.decode.p50), primary),
            ("Decoded", String(format: "%.0f fps", s.decodedFPS), primary),
            ("Replaced · late · dropped", "\(s.counters.replaced) · \(s.counters.late) · \(s.counters.dropped)", primary),
        ]
        for (label, value, color) in rows {
            canvas.text(label, font: font(11), color: secondary, x: padding, baseline: y + 12)
            canvas.text(value, font: font(11, .medium), color: color, right: padding + inner, baseline: y + 12)
            y += rowHeight
        }
        if let stream = s.stream {
            y += 6
            divider(ctx, y: y)
            y += 6
            for line in streamLines(stream) {
                canvas.text(line, font: font(10), color: secondary, x: padding, baseline: y + 11, maxWidth: inner)
                y += 14
            }
        }
        return ctx.makeImage()
    }

    static func height(for s: LatencyStats.HUDSnapshot, mode: HUDMode) -> CGFloat {
        let compact = padding + 32 + 18 + sparklineHeight + padding
        guard mode == .detailed else { return compact }
        let stream: CGFloat = s.stream == nil ? 0 : 12 + 2 * 14
        return compact + 16 + 6 * rowHeight + stream
    }

    private static func streamLines(_ s: StreamInfo) -> [String] {
        var second = s.format.isEmpty ? [] : [s.format]
        if let link = s.link { second.append(link) }
        second.append(s.vsync ? "VSync on" : "VSync off")
        return ["\(s.codec) \(s.width)×\(s.height) @ \(s.fps) Hz · \(s.bitrateMbps) Mbps",
                second.joined(separator: " · ")]
    }

    private static func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "––" }

    private static func divider(_ ctx: CGContext, y: CGFloat) {
        ctx.setFillColor(hairline)
        ctx.fill(CGRect(x: padding, y: y, width: width - 2 * padding, height: 1))
    }

    /// Time to screen per frame, oldest on the left; a dashed line marks one
    /// refresh interval, and the part of the curve above it is drawn red.
    private static func sparkline(ctx: CGContext, canvas: Canvas, values: [Double], budget: Double, frame: CGRect) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.05))
        ctx.fill(frame)
        let top = max(budget * 1.5, min(values.max() ?? 0, budget * 4))
        func y(_ v: Double) -> CGFloat { frame.maxY - CGFloat(min(v, top) / top) * frame.height }
        if values.count > 1 {
            let step = frame.width / CGFloat(Swift.max(values.count, LatencyStats.sparklineFrames) - 1)
            let start = frame.maxX - step * CGFloat(values.count - 1)
            let line = CGMutablePath()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: start + step * CGFloat(i), y: y(v))
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
        canvas.text(String(format: "%.1f", budget), font: font(9, .medium), color: secondary,
                    right: frame.maxX - 2, baseline: by - 2)
    }

    /// One-line CoreText drawing in the flipped context.
    private struct Canvas {
        let ctx: CGContext

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
