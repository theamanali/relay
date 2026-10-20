import CoreMedia
import CoreVideo
import XCTest
@testable import Relay

private final class DecodedBuffer: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var image: CVPixelBuffer?
    func put(_ value: CVPixelBuffer) { lock.withLock { image = value }; ready.signal() }
    func get() -> CVPixelBuffer? { lock.withLock { image } }
}

final class DecodedPrecisionTests: XCTestCase {
    private func nals(_ data: Data) -> [Data] {
        let b = Array(data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i+1] == 0, b[i+2] == 1 { starts.append((i, i+3)); i += 3 }
            else if i + 4 <= b.count, b[i] == 0, b[i+1] == 0, b[i+2] == 0, b[i+3] == 1 {
                starts.append((i,i+4)); i += 4
            } else { i += 1 }
        }
        return starts.indices.map { j in Data(b[starts[j].1..<(j+1 < starts.count ? starts[j+1].0 : b.count)]) }
    }

    func testHardwareDecodeAndNativeMetalPrecisionForAllSDRFormats() throws {
        guard HostConnection.hardwareCodecs & Proto.Codec.hevc.bit != 0,
              HostConnection.hardwareCodecs & Proto.Codec.h264.bit != 0, MetalPresenter() != nil else {
            throw XCTSkip("requires local hardware H.264/HEVC decode and Metal")
        }
        for (depth, chroma, codec) in [(8,420,Proto.Codec.hevc),(8,444,.hevc),
                                     (10,420,.hevc),(10,444,.hevc),(8,420,.h264)] {
            let name = "\(chroma)-\(depth).\(codec == .hevc ? "hevc" : "h264")"
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let units = nals(try Data(contentsOf: url))
            func kind(_ nal: Data) -> UInt8 { codec == .hevc ? (nal[0] >> 1) & 63 : nal[0] & 31 }
            let config = units.filter { codec == .hevc ? [32,33,34].contains(kind($0)) : [7,8].contains(kind($0)) }
            let frame = units.filter { codec == .hevc ? kind($0) < 32 : [1,5].contains(kind($0)) }
            let renderer = try VideoRenderer()
            let decoded = DecodedBuffer()
            renderer.decodedBufferHandler = { decoded.put($0) }
            var start = Data(); start.appendBE16(256); start.appendBE16(128)
            start.appendBE16(60); start.appendBE16(120); start.append(codec.rawValue); start.append(1)
            renderer.streamDidStart(try XCTUnwrap(Proto.StreamStart(start)))
            renderer.setParameterSets(config)
            XCTAssertNil(renderer.failure, name)
            var payload = Data()
            frame.forEach { payload.appendBE32(UInt32($0.count)); payload.append($0) }
            renderer.enqueue(frame: payload, keyframe: true, sequence: 1,
                             receivedAt: CMClockGetTime(CMClockGetHostTimeClock()))
            XCTAssertEqual(decoded.ready.wait(timeout: .now() + 5), .success, name)
            let image = try XCTUnwrap(decoded.get(), name)
            let format = CVPixelBufferGetPixelFormatType(image)
            let expected: OSType = depth == 10
                ? (chroma == 444 ? kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                : (chroma == 444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertEqual(format, expected, name)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0))
            let row = base.advanced(by: 64 * CVPixelBufferGetBytesPerRowOfPlane(image, 0))
            let actual = (32..<96).map { x in depth == 10
                ? Int(row.assumingMemoryBound(to: UInt16.self)[x] >> 6)
                : Int(row.assumingMemoryBound(to: UInt8.self)[x]) }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            let expectedCodes = (400..<464).map { depth == 10 ? $0 : ($0+2)/4 }
            XCTAssertEqual(actual, expectedCodes, "\(name): decoded luma must match controlled source, not just occupy low bits")
            guard let metal = MetalPresenter() else { return XCTFail("Metal required") }
            let bytes = try XCTUnwrap(metal.renderNativeOffscreen(image, width: 256, height: 128), name)
            func rgb(_ x: Int, _ y: Int) -> [Int] {
                let i = (y * 256 + x) * 4
                if depth == 8 { return [Int(bytes[i+2]),Int(bytes[i+1]),Int(bytes[i])] }
                let v = UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24
                return [Int(v >> 20 & 1023), Int(v >> 10 & 1023), Int(v & 1023)]
            }
            let maxCode = depth == 10 ? 1023 : 255
            var error = 0
            for (j, code) in actual.enumerated() {
                let expectedRGB = Int((Double(code - (depth == 10 ? 64 : 16)) / Double(depth == 10 ? 876 : 219) * Double(maxCode)).rounded())
                for c in rgb(32+j,64) { error = max(error,abs(c-expectedRGB)) }
            }
            XCTAssertLessThanOrEqual(error, 1, name)
            let distinct = Set((32..<96).map { rgb($0,64)[0] }).count
            XCTAssertEqual(distinct, depth == 10 ? 64 : 17, name)
            XCTAssertLessThanOrEqual(rgb(16,8).max()!,1,"\(name): black")
            XCTAssertGreaterThanOrEqual(rgb(64,8).min()!,maxCode-1,"\(name): white")
            for (x, channel) in [(112,0),(160,1),(224,2)] {
                let p = rgb(x,8)
                XCTAssertGreaterThan(p[channel], maxCode * 9 / 10,"\(name): RGB channel order")
                XCTAssertLessThan(p.enumerated().filter { $0.offset != channel }.map(\.element).max()!,maxCode / 12)
            }
            print("PRECISION \(name): CVPixelBuffer \(MetalPresenter.fourCC(format)); source/decoded \(Set(actual).count)/\(Set(expectedCodes).count), Metal \(distinct)/64, max RGB code error \(error), black/white/RGB pass")
            renderer.reset()
        }
    }
}
