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
            // Power button, lower left (clear of the MacBook in the composite).
            let dot = stroke * 1.8
            NSBezierPath(ovalIn: NSRect(x: body.minX + inset - dot / 2 + stroke / 2, y: body.minY + height * 0.16 - dot / 2, width: dot, height: dot)).fill()
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
        let halo = max(2.0, pointSize / 18)
        let overlap = mac.size.width * 0.3
        let size = NSSize(width: tower.size.width + mac.size.width - overlap, height: tower.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            tower.draw(in: NSRect(origin: .zero, size: tower.size))
            let macRect = NSRect(x: size.width - mac.size.width, y: 0, width: mac.size.width, height: mac.size.height)
            // The MacBook is solid from the tower's point of view: clear its
            // whole silhouette (plus a small halo), not just its outline, so no
            // tower lines show through the screen.
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
