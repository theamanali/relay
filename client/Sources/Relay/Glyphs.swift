// Symbols SF Symbols does not have: a plain PC tower, alone and next to a
// MacBook. Drawn as template images in the SF outline style so they tint and
// scale like the real ones.

import AppKit

@MainActor
enum Glyphs {
    /// A desktop tower: rounded case, power button at the top, vents at the bottom.
    /// `pointSize` matches the SF Symbol point size it sits beside.
    static func tower(pointSize: CGFloat) -> NSImage {
        let height = pointSize * 1.15
        let width = height * 0.56
        let stroke = max(1.5, pointSize / 16)
        let size = NSSize(width: width + stroke, height: height + stroke)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let body = NSRect(x: stroke / 2, y: stroke / 2, width: width, height: height)
            let case_ = NSBezierPath(roundedRect: body, xRadius: width * 0.16, yRadius: width * 0.16)
            case_.lineWidth = stroke
            case_.stroke()

            // Power button, top centre.
            let dot = stroke * 1.8
            NSBezierPath(ovalIn: NSRect(x: body.midX - dot / 2, y: body.maxY - height * 0.16 - dot / 2, width: dot, height: dot)).fill()

            // Vents across the bottom of the case.
            let inset = width * 0.22
            for i in 0..<3 {
                let y = body.minY + height * (0.16 + 0.1 * CGFloat(i))
                let vent = NSBezierPath()
                vent.move(to: NSPoint(x: body.minX + inset, y: y))
                vent.line(to: NSPoint(x: body.maxX - inset, y: y))
                vent.lineWidth = stroke
                vent.lineCapStyle = .round
                vent.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// SF's `laptopcomputer`, cropped to its drawn pixels so the composite's
    /// knockout hugs the shape instead of the symbol's padding.
    static func macBook(pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return NSImage() }
        let bounds = opaqueBounds(of: symbol)
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            symbol.draw(in: rect, from: bounds, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Bounding box of the non-transparent pixels, in the image's point space.
    private static func opaqueBounds(of image: NSImage) -> NSRect {
        let scale: CGFloat = 4
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSRect(origin: .zero, size: image.size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return NSRect(origin: .zero, size: image.size) }
        // Bitmap rows are top-down; flip to the image's bottom-up point space.
        return NSRect(x: CGFloat(minX) / scale,
                      y: CGFloat(h - 1 - maxY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }

    /// The tower with a MacBook in front, a halo knocked out where they
    /// overlap the way Apple's combined symbols do.
    static func towerAndMacBook(pointSize: CGFloat) -> NSImage {
        let tower = tower(pointSize: pointSize)
        let mac = macBook(pointSize: pointSize * 0.8)
        let halo = max(2.0, pointSize / 18)
        let overlap = mac.size.width * 0.3
        let size = NSSize(width: tower.size.width + mac.size.width - overlap, height: tower.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            tower.draw(in: NSRect(origin: .zero, size: tower.size))
            let macRect = NSRect(x: size.width - mac.size.width, y: 0, width: mac.size.width, height: mac.size.height)
            // The MacBook image is tight to its outline, so this clears just
            // the shape plus the halo.
            let mask = NSBezierPath(roundedRect: macRect.insetBy(dx: -halo, dy: -halo), xRadius: halo * 2, yRadius: halo * 2)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            mask.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            mac.draw(in: macRect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
