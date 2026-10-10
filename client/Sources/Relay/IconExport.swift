// `--render-icons <dir>`: write the host's tray icons from the same glyph the
// picker draws, so the PC and the Mac share one piece of artwork. Produces
// relay-light.ico (black, for a light taskbar) and relay-dark.ico (white, for a
// dark one); Windows does not tint tray icons, hence two files. See
// host/assets/README.md.
//
// `--render-app-icon <dir>`: the Mac app's own icon from the same glyph.
// Two forms. AppIcon.icon is an Icon Composer document (macOS 26): a blue
// fill and the glyph as a layer, from which the system itself renders the
// light, dark, clear and tinted appearances — a plain .icns has no
// appearance slot, and an asset catalog silently drops dark variants for
// macOS icons — and bundle.sh compiles it with actool. Relay.icns is the
// same drawing flattened (white glyph on a blue squircle at Apple's icon
// geometry), the fallback for a bundle built without Xcode and for a Dock
// icon at launch so a `swift run` looks right.

import AppKit

@MainActor
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

    /// AppIcon.icon, and Relay.icns via `iconutil` from a temporary
    /// .iconset of the standard sizes (16…512 at 1x and 2x).
    static func renderAppIcon(into directory: String) -> Int32 {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Relay-\(getpid()).iconset")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                    try appIconPNG(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
                }
            }
            let icon = dir.appendingPathComponent("AppIcon.icon", isDirectory: true)
            try? FileManager.default.removeItem(at: icon)
            try FileManager.default.createDirectory(at: icon.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try glyphLayerPNG().write(to: icon.appendingPathComponent("Assets/glyph.png"))
            try Data(iconDocument.utf8).write(to: icon.appendingPathComponent("icon.json"))
            let out = dir.appendingPathComponent("Relay.icns")
            let iconutil = Process()
            iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
            iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
            try iconutil.run()
            iconutil.waitUntilExit()
            try? FileManager.default.removeItem(at: iconset)
            guard iconutil.terminationStatus == 0 else {
                FileHandle.standardError.write("render-app-icon: iconutil failed\n".data(using: .utf8)!)
                return 1
            }
            print("wrote AppIcon.icon and Relay.icns to \(dir.path)")
            return 0
        } catch {
            FileHandle.standardError.write("render-app-icon: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    /// The app icon as an image, for `NSApp.applicationIconImage`.
    static func appIcon() -> NSImage {
        let image = NSImage()
        for pixels in [256, 512, 1024] {
            if let rep = NSBitmapImageRep(data: appIconPNG(pixels: pixels)) {
                rep.size = NSSize(width: 512, height: 512)
                image.addRepresentation(rep)
            }
        }
        image.size = NSSize(width: 512, height: 512)
        return image
    }

    /// The Icon Composer document: the fill's colour becomes Apple's own
    /// gradient, and the glyph is one layer over it, sized in glyphLayerPNG.
    private static let iconDocument = """
    {
      "fill" : {
        "automatic-gradient" : "srgb:0.10,0.47,0.95,1.00"
      },
      "groups" : [
        {
          "layers" : [
            {
              "image-name" : "glyph.png",
              "name" : "glyph"
            }
          ]
        }
      ],
      "supported-platforms" : {
        "circles" : [ "watchOS" ],
        "squares" : "shared"
      }
    }

    """

    /// The glyph as an icon layer: white, on a transparent 1024 canvas, at
    /// the size the flattened icon draws it, so the two forms match.
    private static func glyphLayerPNG() -> Data {
        let pixels = 1024
        let canvas = CGFloat(pixels)
        let square = canvas * 824 / 1024
        let probe = Glyphs.towerAndMacBook(pointSize: 100)
        let pointSize = 100 * square * 0.80 / max(probe.size.width, probe.size.height)
        let glyph = Glyphs.towerAndMacBook(pointSize: pointSize)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return Data() }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let origin = NSPoint(x: (canvas - glyph.size.width) / 2, y: (canvas - glyph.size.height) / 2)
        let glyphRect = NSRect(origin: origin, size: glyph.size)
        tinted(glyph, in: glyphRect.size, color: .white)?.draw(in: glyphRect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Apple's icon grid: on a 1024 canvas the rounded square is 824 wide
    /// with corners of about 22 %; the rest is margin the system expects.
    static func appIconPNG(pixels: Int) -> Data {
        let canvas = CGFloat(pixels)
        let square = canvas * 824 / 1024
        let radius = square * 0.2237
        let squareRect = NSRect(x: (canvas - square) / 2, y: (canvas - square) / 2, width: square, height: square)

        let probe = Glyphs.towerAndMacBook(pointSize: 100)
        let pointSize = 100 * square * 0.80 / max(probe.size.width, probe.size.height)
        let glyph = Glyphs.towerAndMacBook(pointSize: pointSize)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return Data() }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        // System blue, lighter at the top, like Apple's own single-colour
        // icons, with the glyph in white.
        let top = NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 1)
        let bottom = NSColor(srgbRed: 0.0, green: 0.42, blue: 0.93, alpha: 1)
        let path = NSBezierPath(roundedRect: squareRect, xRadius: radius, yRadius: radius)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        let origin = NSPoint(x: (canvas - glyph.size.width) / 2, y: (canvas - glyph.size.height) / 2)
        let glyphRect = NSRect(origin: origin, size: glyph.size)
        tinted(glyph, in: glyphRect.size, color: .white)?.draw(in: glyphRect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// A template image painted in `color`, alpha preserved.
    private static func tinted(_ image: NSImage, in size: NSSize, color: NSColor) -> NSImage? {
        NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
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
