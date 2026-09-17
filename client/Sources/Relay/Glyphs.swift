// Symbols SF Symbols does not have: a plain PC tower, alone and next to a
// MacBook. Drawn as template images in the SF outline style so they tint and
// scale like the real ones.

import AppKit

enum Glyphs {
    /// A desktop tower: rounded case with a power button at the top.
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
            // Clear the MacBook's silhouette plus a small halo, the way Apple's
            // combined symbols separate overlapping shapes.
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
