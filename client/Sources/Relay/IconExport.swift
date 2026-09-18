// `--render-icons <dir>`: write the host's tray icons from the same glyph the
// picker draws, so the PC and the Mac share one piece of artwork. Produces
// relay-light.ico (black, for a light taskbar) and relay-dark.ico (white, for a
// dark one); Windows does not tint tray icons, hence two files. See
// host/assets/README.md.

import AppKit

enum IconExport {
    /// Pixel sizes Windows may ask for, from a 16 px tray at 100 % DPI to the
    /// 256 px Explorer tile.
    static let sizes = [16, 20, 24, 32, 40, 48, 64, 256]

    static func run(into directory: String) -> Int32 {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ico(color: .black).write(to: dir.appendingPathComponent("relay-light.ico"))
            try ico(color: .white).write(to: dir.appendingPathComponent("relay-dark.ico"))
        } catch {
            FileHandle.standardError.write("render-icons: \(error)\n".data(using: .utf8)!)
            return 1
        }
        print("wrote relay-light.ico and relay-dark.ico to \(dir.path)")
        return 0
    }

    /// One PNG per size, tinted to `color`, packed into an .ico container.
    /// PNG entries are valid for every size since Vista and keep the alpha.
    static func ico(color: NSColor) -> Data {
        let pngs = sizes.map { png(pixels: $0, color: color) }
        var out = Data()
        func u8(_ v: Int) { out.append(UInt8(v)) }
        func u16(_ v: Int) { out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff)) }
        func u32(_ v: Int) { u16(v & 0xffff); u16((v >> 16) & 0xffff) }
        u16(0); u16(1); u16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for (size, data) in zip(sizes, pngs) {
            let dim = size >= 256 ? 0 : size
            u8(dim); u8(dim); u8(0); u8(0)
            u16(1); u16(32)
            u32(data.count); u32(offset)
            offset += data.count
        }
        for data in pngs { out.append(data) }
        return out
    }

    /// The composite drawn to fill a `pixels`-square canvas, tinted to `color`.
    static func png(pixels: Int, color: NSColor) -> Data {
        // Point size is what the glyph is drawn for; the composite is a little
        // wider than tall, so size it by width to fit the square with a hair
        // of margin, then centre it.
        let probe = Glyphs.towerAndMacBook(pointSize: 100)
        let pointSize = 100 * CGFloat(pixels) * 0.94 / max(probe.size.width, probe.size.height)
        let glyph = Glyphs.towerAndMacBook(pointSize: pointSize)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return Data() }
        // One point == one pixel in this rep.
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let origin = NSPoint(x: (CGFloat(pixels) - glyph.size.width) / 2,
                             y: (CGFloat(pixels) - glyph.size.height) / 2)
        glyph.draw(in: NSRect(origin: origin, size: glyph.size))
        // Template images are black on clear; tint by painting the colour
        // through the glyph's alpha.
        color.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
