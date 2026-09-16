// Wire format shared with the Rust host. See docs/PROTOCOL.md.

import Foundation

enum Proto {
    static let version: UInt16 = 2
    static let defaultPort: UInt16 = 8468
    static let serviceType = "_traveldisplay._tcp"
    static let headerSize = 8
    static let maxPayload: UInt32 = 64 * 1024 * 1024

    enum Msg: UInt8 {
        // host -> client
        case serverHello = 0x01
        case streamStart = 0x02
        case codecConfig = 0x03
        case frame = 0x04
        case cursor = 0x05
        case streamStop = 0x06
        case ping = 0x07
        case pairResult = 0xA1
        // client -> host
        case clientHello = 0x81
        case pong = 0x87
        case mouseMove = 0x90
        case mouseButton = 0x91
        case mouseWheel = 0x92
        case key = 0x93
        case pair = 0xA0
    }

    static let flagKeyframe: UInt8 = 0x01

    enum Codec: UInt8 {
        case h264 = 1
        case hevc = 2
        case av1 = 3

        var bit: UInt8 {
            switch self {
            case .h264: return 0b001
            case .hevc: return 0b010
            case .av1: return 0b100
            }
        }
    }

    struct Header {
        let type: UInt8
        let flags: UInt8
        let length: UInt32

        init?(_ data: Data) {
            guard data.count >= Proto.headerSize else { return nil }
            let b = [UInt8](data)
            type = b[0]
            flags = b[1]
            length = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        }
    }

    struct StreamStart {
        let width: Int
        let height: Int
        let fps: Int
        let codec: Codec

        init?(_ p: Data) {
            guard p.count >= 8, let codec = Codec(rawValue: p[p.startIndex + 6]) else { return nil }
            width = Int(p.be16(at: 0))
            height = Int(p.be16(at: 2))
            fps = Int(p.be16(at: 4))
            self.codec = codec
        }
    }

    /// Split a length-prefixed NAL list (FRAME / CODEC_CONFIG payload) into units.
    static func nalUnits(in payload: Data) -> [Data] {
        var units: [Data] = []
        var i = payload.startIndex
        while i + 4 <= payload.endIndex {
            let len = Int(payload.be32(at: i - payload.startIndex))
            i += 4
            guard i + len <= payload.endIndex else { break }
            units.append(payload.subdata(in: i..<(i + len)))
            i += len
        }
        return units
    }

    // MARK: message builders

    static func message(_ type: Msg, flags: UInt8 = 0, payload: Data = Data()) -> Data {
        var d = Data(capacity: headerSize + payload.count)
        d.append(type.rawValue)
        d.append(flags)
        d.append(contentsOf: [0, 0])
        d.appendBE32(UInt32(payload.count))
        d.append(payload)
        return d
    }

    static func clientHello(width: Int, height: Int, refresh: Int, wantsInput: Bool, codecs: UInt8, name: String) -> Data {
        var p = Data()
        p.appendBE16(version)
        p.appendBE16(UInt16(clamping: width))
        p.appendBE16(UInt16(clamping: height))
        p.appendBE16(UInt16(clamping: refresh))
        p.append(wantsInput ? 0x01 : 0x00)
        p.append(codecs)
        let nameBytes = Array(name.utf8.prefix(255))
        p.append(UInt8(nameBytes.count))
        p.append(contentsOf: nameBytes)
        return message(.clientHello, payload: p)
    }

    static func pong(_ pingPayload: Data) -> Data {
        message(.pong, payload: pingPayload)
    }

    /// `x`/`y` normalised 0...1 across the streamed frame.
    static func mouseMove(x: Double, y: Double) -> Data {
        var p = Data(capacity: 4)
        p.appendBE16(UInt16(clamping: Int((x.clamped01) * 65535)))
        p.appendBE16(UInt16(clamping: Int((y.clamped01) * 65535)))
        return message(.mouseMove, payload: p)
    }

    static func mouseButton(_ button: UInt8, down: Bool) -> Data {
        message(.mouseButton, payload: Data([button, down ? 1 : 0]))
    }

    static func mouseWheel(dx: Int16, dy: Int16) -> Data {
        var p = Data(capacity: 4)
        p.appendBE16(UInt16(bitPattern: dx))
        p.appendBE16(UInt16(bitPattern: dy))
        return message(.mouseWheel, payload: p)
    }

    static func key(hidUsage: UInt16, down: Bool) -> Data {
        var p = Data(capacity: 3)
        p.appendBE16(hidUsage)
        p.append(down ? 1 : 0)
        return message(.key, payload: p)
    }
}

extension Data {
    func be16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func be32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    mutating func appendBE16(_ v: UInt16) {
        append(UInt8(v >> 8))
        append(UInt8(v & 0xff))
    }

    mutating func appendBE32(_ v: UInt32) {
        append(UInt8(v >> 24))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
