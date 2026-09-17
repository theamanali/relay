// Symbols SF Symbols does not have: a plain PC tower, alone and next to a
// MacBook. Drawn as template images in the SF outline style so they tint and
// scale like the real ones.

import AppKit

enum Glyphs {
    /// A desktop tower: rounded case, optical-drive slot, power button, vents.
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

            let inset = width * 0.22
            // Vents across the top of the case.
            for i in 0..<3 {
                let y = body.maxY - height * (0.16 + 0.1 * CGFloat(i))
                let vent = NSBezierPath()
                vent.move(to: NSPoint(x: body.minX + inset, y: y))
                vent.line(to: NSPoint(x: body.maxX - inset, y: y))
                vent.lineWidth = stroke
                vent.lineCapStyle = .round
                vent.stroke()
            }
            // Power button, centred near the bottom.
            let dot = stroke * 1.8
            NSBezierPath(ovalIn: NSRect(x: body.midX - dot / 2, y: body.minY + height * 0.16 - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The tower with a MacBook in front, a halo knocked out where they
    /// overlap the way Apple's combined symbols do.
    static func towerAndMacBook(pointSize: CGFloat) -> NSImage {
        let tower = tower(pointSize: pointSize)
        let macConfig = NSImage.SymbolConfiguration(pointSize: pointSize * 0.72, weight: .regular)
        guard let mac = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(macConfig)
        else { return tower }
        let overlap = mac.size.width * 0.15
        let size = NSSize(width: tower.size.width + mac.size.width - overlap, height: tower.size.height)
        let macRect = NSRect(x: size.width - mac.size.width, y: 0, width: mac.size.width, height: mac.size.height)
        // The symbol image has transparent padding; occlude only where the
        // laptop is actually drawn, so the tower's lines meet its outline.
        let footprint = opaqueBounds(of: mac).offsetBy(dx: macRect.minX, dy: macRect.minY)
        let image = NSImage(size: size, flipped: false) { _ in
            tower.draw(in: NSRect(origin: .zero, size: tower.size))
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            footprint.insetBy(dx: 0.5, dy: 0.5).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            mac.draw(in: macRect)
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
}
