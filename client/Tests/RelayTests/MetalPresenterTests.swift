import CoreVideo
import simd
import XCTest
@testable import Relay

final class MetalPresenterTests: XCTestCase {
    /// NV12 buffer of the given size; `fill` writes (Y, Cb, Cr) per pixel.
    private func makeBuffer(width: Int, height: Int, fullRange: Bool,
                            fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                               : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<height {
            for col in 0..<width {
                let (yy, cb, cr) = fill(col, row)
                y[row * yStride + col] = yy
                if row % 2 == 0, col % 2 == 0 {
                    c[(row / 2) * cStride + col] = cb
                    c[(row / 2) * cStride + col + 1] = cr
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4 // BGRA
        return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
    }

    func testLimitedRangeBlackWhiteAndPrimaries() throws {
        guard let presenter = MetalPresenter() else { throw XCTSkip("no Metal device") }
        // Left half white, right half black; a pure-red patch top-left.
        let image = makeBuffer(width: 64, height: 64, fullRange: false) { x, y in
            if x < 16, y < 16 { return (63, 102, 240) } // BT.709 limited-range red
            return x < 32 ? (235, 128, 128) : (16, 128, 128)
        }
        let out = try XCTUnwrap(presenter.renderOffscreen(image, width: 64, height: 64))
        let white = pixel(out, width: 64, x: 24, y: 40)
        let black = pixel(out, width: 64, x: 48, y: 40)
        let red = pixel(out, width: 64, x: 4, y: 4)
        XCTAssertGreaterThanOrEqual(min(white.r, white.g, white.b), 252)
        XCTAssertLessThanOrEqual(max(black.r, black.g, black.b), 3)
        XCTAssertGreaterThanOrEqual(red.r, 245); XCTAssertLessThanOrEqual(red.g, 12); XCTAssertLessThanOrEqual(red.b, 12)
    }

    func testFullRangeUsesUnscaledLuma() throws {
        guard let presenter = MetalPresenter() else { throw XCTSkip("no Metal device") }
        let image = makeBuffer(width: 16, height: 16, fullRange: true) { _, _ in (128, 128, 128) }
        let out = try XCTUnwrap(presenter.renderOffscreen(image, width: 16, height: 16))
        let grey = pixel(out, width: 16, x: 8, y: 8)
        XCTAssertEqual(grey.r, 128, accuracy: 2); XCTAssertEqual(grey.g, 128, accuracy: 2); XCTAssertEqual(grey.b, 128, accuracy: 2)
    }

    func testOrientationAndLetterboxing() throws {
        guard let presenter = MetalPresenter() else { throw XCTSkip("no Metal device") }
        // Top row bright, rest dark; 2:1 picture into a square target -> bars top and bottom.
        let image = makeBuffer(width: 64, height: 32, fullRange: false) { _, y in
            y < 4 ? (235, 128, 128) : (100, 128, 128)
        }
        let out = try XCTUnwrap(presenter.renderOffscreen(image, width: 64, height: 64))
        XCTAssertLessThanOrEqual(pixel(out, width: 64, x: 32, y: 4).r, 3, "top letterbox bar should be black")
        XCTAssertLessThanOrEqual(pixel(out, width: 64, x: 32, y: 60).r, 3, "bottom letterbox bar should be black")
        XCTAssertGreaterThanOrEqual(pixel(out, width: 64, x: 32, y: 17).r, 250, "picture's top row lands just under the top bar")
        XCTAssertEqual(pixel(out, width: 64, x: 32, y: 40).r, 98, accuracy: 4, "body of the picture")
    }

    func testMatrixSelection() {
        let image = makeBuffer(width: 2, height: 2, fullRange: false) { _, _ in (16, 128, 128) }
        let (offset, m) = MetalPresenter.conversion(for: image)
        XCTAssertEqual(offset.x, -16 / 255, accuracy: 1e-6)
        // Limited-range white maps to 1.0 on every channel.
        let white = m * (SIMD3<Float>(235, 128, 128) / 255 + offset)
        XCTAssertEqual(white.x, 1, accuracy: 1e-3); XCTAssertEqual(white.y, 1, accuracy: 1e-3); XCTAssertEqual(white.z, 1, accuracy: 1e-3)
    }
    /// A 10-bit or 4:4:4 biplanar buffer filled with one (Y, Cb, Cr) per
    /// pixel, given as 8-bit code values (10-bit buffers store them × 4,
    /// in the top bits of 16 like the decoder does).
    private func makeBuffer(format: OSType, width: Int, height: Int,
                            fill: (Int, Int) -> (Int, Int, Int)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = pb!
        let tenBit = MetalPresenter.isTenBit(format)
        let fullChroma = CVPixelBufferGetWidthOfPlane(buffer, 1) == width
        CVPixelBufferLockBaseAddress(buffer, [])
        func store(_ plane: Int, _ index: Int, _ code: Int) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let row = index / 100_000, col = index % 100_000
            if tenBit {
                base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)[col] = UInt16(code * 4) << 6
            } else {
                base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)[col] = UInt8(code)
            }
        }
        for row in 0..<height {
            for col in 0..<width {
                let (y, cb, cr) = fill(col, row)
                store(0, row * 100_000 + col, y)
                if fullChroma || (row % 2 == 0 && col % 2 == 0) {
                    let (cRow, cCol) = fullChroma ? (row, col) : (row / 2, col / 2)
                    store(1, cRow * 100_000 + cCol * 2, cb)
                    store(1, cRow * 100_000 + cCol * 2 + 1, cr)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    func testTenBitAndFullColorFormatsRenderTheSameColors() throws {
        guard let presenter = MetalPresenter() else { throw XCTSkip("no Metal device") }
        for format in [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange] {
            let name = MetalPresenter.fourCC(format)
            let image = makeBuffer(format: format, width: 64, height: 64) { x, y in
                if x < 16, y < 16 { return (63, 102, 240) } // BT.709 limited-range red
                return x < 32 ? (235, 128, 128) : (16, 128, 128)
            }
            let out = try XCTUnwrap(presenter.renderOffscreen(image, width: 64, height: 64), name)
            let white = pixel(out, width: 64, x: 24, y: 40), black = pixel(out, width: 64, x: 48, y: 40)
            let red = pixel(out, width: 64, x: 4, y: 4)
            XCTAssertGreaterThanOrEqual(min(white.r, white.g, white.b), 252, name)
            XCTAssertLessThanOrEqual(max(black.r, black.g, black.b), 3, name)
            XCTAssertGreaterThanOrEqual(red.r, 245, name); XCTAssertLessThanOrEqual(red.g, 12, name); XCTAssertLessThanOrEqual(red.b, 12, name)
        }
    }

    func testFullColorKeepsOnePixelChromaDetail() throws {
        guard let presenter = MetalPresenter() else { throw XCTSkip("no Metal device") }
        // Alternate red and blue columns at the same luma: 4:4:4 keeps them
        // apart, which 4:2:0 cannot.
        let image = makeBuffer(format: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, width: 16, height: 16) { x, _ in
            x % 2 == 0 ? (81, 90, 240) : (81, 240, 118)
        }
        let out = try XCTUnwrap(presenter.renderOffscreen(image, width: 16, height: 16))
        let even = pixel(out, width: 16, x: 6, y: 8), odd = pixel(out, width: 16, x: 7, y: 8)
        XCTAssertGreaterThan(even.r, even.b + 100, "red column")
        XCTAssertGreaterThan(odd.b, odd.r + 100, "blue column")
    }

    func testTenBitRangeMath() {
        let video = makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 2, height: 2) { _, _ in (16, 128, 128) }
        let (offset, m) = MetalPresenter.conversion(for: video)
        // Code values as r16Unorm reads them: code × 64 / 65535.
        func read(_ code10: Float) -> Float { code10 * 64 / 65535 }
        let white = m * (SIMD3<Float>(read(940), read(512), read(512)) + offset)
        let black = m * (SIMD3<Float>(read(64), read(512), read(512)) + offset)
        XCTAssertEqual(white.x, 1, accuracy: 1e-4); XCTAssertEqual(white.y, 1, accuracy: 1e-4); XCTAssertEqual(white.z, 1, accuracy: 1e-4)
        XCTAssertEqual(black.x, 0, accuracy: 1e-4)
        let full = makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, width: 2, height: 2) { _, _ in (0, 128, 128) }
        let (fOffset, fm) = MetalPresenter.conversion(for: full)
        let fullWhite = fm * (SIMD3<Float>(read(1023), read(512), read(512)) + fOffset)
        XCTAssertEqual(fullWhite.x, 1, accuracy: 1e-3)
        XCTAssertEqual(MetalPresenter.layerFormat(for: full), .bgr10a2Unorm)
        XCTAssertEqual(MetalPresenter.layerFormat(for: makeBuffer(width: 2, height: 2, fullRange: false) { _, _ in (16, 128, 128) }), .bgra8Unorm)
    }
}
