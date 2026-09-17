// Symbols SF Symbols does not have: a plain PC tower, alone and next to a
// MacBook. Drawn as template images in the SF outline style so they tint and
// scale like the real ones.

import AppKit

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

    /// A MacBook in the same outline style: rounded screen over a wider base
    /// bar. Drawn here (rather than SF's `laptopcomputer`) so the image has no
    /// padding and the knockout in the composite hugs the shape.
    static func macBook(pointSize: CGFloat) -> NSImage {
        let stroke = max(1.5, pointSize / 16)
        let baseWidth = pointSize * 1.15
        let screenWidth = baseWidth * 0.84
        let screenHeight = screenWidth * 0.64
        let size = NSSize(width: baseWidth + stroke, height: screenHeight + stroke * 2.5)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let baseY = stroke / 2 + stroke * 0.5
            let base = NSBezierPath()
            base.move(to: NSPoint(x: stroke / 2 + stroke * 0.4, y: baseY))
            base.line(to: NSPoint(x: size.width - stroke / 2 - stroke * 0.4, y: baseY))
            base.lineWidth = stroke
            base.lineCapStyle = .round
            base.stroke()
            let screen = NSRect(x: (size.width - screenWidth) / 2, y: baseY + stroke, width: screenWidth, height: screenHeight)
            let path = NSBezierPath(roundedRect: screen, xRadius: stroke * 1.2, yRadius: stroke * 1.2)
            path.lineWidth = stroke
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The tower with a MacBook in front, a halo knocked out where they
    /// overlap the way Apple's combined symbols do.
    static func towerAndMacBook(pointSize: CGFloat) -> NSImage {
        let tower = tower(pointSize: pointSize)
        let mac = macBook(pointSize: pointSize * 0.72)
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
