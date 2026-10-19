import CoreVideo
import Network
import XCTest
@testable import Relay

final class VideoOptionsTests: XCTestCase {
    func testAutomaticBitrateKeepsEachFramesShare() {
        // The old fixed default, and what follows from it.
        XCTAssertEqual(VideoBitrate.automatic(width: 3024, height: 1964, refresh: 120, overWiFi: false), 120)
        XCTAssertEqual(VideoBitrate.automatic(width: 3024, height: 1964, refresh: 60, overWiFi: false), 60)
        XCTAssertEqual(VideoBitrate.automatic(width: 2268, height: 1474, refresh: 120, overWiFi: false), 70)
        XCTAssertEqual(VideoBitrate.automatic(width: 1512, height: 982, refresh: 120, overWiFi: false), 30)
        // Wi-Fi is capped; the range clamps both ends.
        XCTAssertEqual(VideoBitrate.automatic(width: 3024, height: 1964, refresh: 120, overWiFi: true), 80)
        XCTAssertEqual(VideoBitrate.automatic(width: 1512, height: 982, refresh: 60, overWiFi: true), 20)
        XCTAssertEqual(VideoBitrate.automatic(width: 6016, height: 3384, refresh: 120, overWiFi: false), 200)
        XCTAssertEqual(VideoBitrate.automatic(width: 640, height: 360, refresh: 60, overWiFi: false), 20)
    }

    @MainActor func testBitratePrefMigratesToAutomaticUnlessChosen() async {
        let suite = "RelayTests.VideoOptions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SessionPrefs.load(from: defaults).bitrateAutomatic)
        // Every save used to write the bitrate: the old default means "never chosen".
        defaults.set(120, forKey: "videoBitrateMbps")
        XCTAssertTrue(SessionPrefs.load(from: defaults).bitrateAutomatic)
        defaults.set(400, forKey: "videoBitrateMbps")
        XCTAssertFalse(SessionPrefs.load(from: defaults).bitrateAutomatic)
        // Saved explicitly from then on.
        var prefs = SessionPrefs.load(from: defaults)
        prefs.bitrateAutomatic = true
        prefs.save(to: defaults)
        XCTAssertTrue(SessionPrefs.load(from: defaults).bitrateAutomatic)
        // --bitrate is a choice for that launch.
        let launch = LaunchOptions.parse(["Relay", "--bitrate", "250"])
        let overridden = SessionPrefs.load(from: defaults).overridden(by: launch)
        XCTAssertFalse(overridden.bitrateAutomatic)
        XCTAssertEqual(overridden.bitrateMbps, 250)
    }

    @MainActor func testPictureOptionPrefsPersist() async {
        let suite = "RelayTests.VideoOptions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = SessionPrefs.load(from: defaults)
        XCTAssertEqual(fresh.encoderQuality, .fastest)
        XCTAssertFalse(fresh.fullColor)
        XCTAssertFalse(fresh.tenBit)
        var saved = SessionPrefs()
        saved.encoderQuality = .best
        saved.fullColor = true
        saved.tenBit = true
        saved.save(to: defaults)
        let loaded = SessionPrefs.load(from: defaults)
        XCTAssertEqual(loaded.encoderQuality, .best)
        XCTAssertTrue(loaded.fullColor)
        XCTAssertTrue(loaded.tenBit)
    }

    func testSPSReaderFindsChromaFormatAndBitDepth() throws {
        typealias Sets = VideoCapabilities.ParameterSets
        let cases: [([Data], Int, Int, OSType)] = [
            (Sets.main, 1, 8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (Sets.main10, 1, 10, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            (Sets.rext444, 3, 8, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
            (Sets.rext444TenBit, 3, 10, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange),
        ]
        for (sets, chroma, depth, pixelFormat) in cases {
            XCTAssertEqual(sets.count, 3)
            let format = try XCTUnwrap(HEVCStreamFormat(sps: sets[1]))
            XCTAssertEqual(format, HEVCStreamFormat(chromaFormat: chroma, bitDepth: depth))
            XCTAssertEqual(format.pixelFormat(fullRange: false), pixelFormat)
            XCTAssertEqual(VideoRenderer.outputFormat(codec: .hevc, sets: sets, description: nil), pixelFormat)
        }
        XCTAssertEqual(HEVCStreamFormat(chromaFormat: 3, bitDepth: 10).pixelFormat(fullRange: true),
                       kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        // H.264 and unreadable sets stay on 8-bit 4:2:0.
        XCTAssertEqual(VideoRenderer.outputFormat(codec: .h264, sets: Sets.rext444, description: nil),
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertNil(HEVCStreamFormat(sps: Data([0x42, 0x01, 0x01])))
    }

    func testThisMacDecodesTheCannedStreams() throws {
        // Every Apple silicon Mac decodes HEVC Main in hardware; the macos-14
        // CI VM has no media engine at all.
        guard VideoCapabilities.hardwareDecodes(VideoCapabilities.ParameterSets.main) else {
            throw XCTSkip("no hardware HEVC decoder (virtual machine)")
        }
        guard VideoCapabilities.supports444, VideoCapabilities.supports10Bit else {
            throw XCTSkip("this Mac's media engine lacks HEVC 4:4:4 or 10-bit")
        }
    }

    func testFeaturesFromTXTAndWhyAnOptionIsOff() {
        XCTAssertEqual(VideoFeatures(txt: "q,444,10"), [.encoderQuality, .fullColor, .tenBit])
        XCTAssertEqual(VideoFeatures(txt: "q, 10,av1"), [.encoderQuality, .tenBit])
        XCTAssertEqual(VideoFeatures(txt: ""), [])
        XCTAssertEqual(VideoOptionAvailability.of(.fullColor, pcFeatures: nil), .pcNeedsUpdate)
        XCTAssertEqual(VideoOptionAvailability.of(.fullColor, pcFeatures: [.encoderQuality]), .pcCannot)
        XCTAssertEqual(VideoOptionAvailability.of(.fullColor, pcFeatures: [.fullColor]), .available)
        XCTAssertEqual(VideoOptionAvailability.of(.fullColor, pcFeatures: [.fullColor], macDecodes: false), .macCannot)
        XCTAssertNil(VideoOptionAvailability.available.reason)
        XCTAssertEqual(VideoOptionAvailability.pcNeedsUpdate.reason, "Needs Relay to be updated on the PC.")
    }

    func testClientHelloDisplayScaleFollowsThePictureOptions() {
        func hello(video: Proto.VideoRequest?, scale: UInt16?) -> Data {
            Proto.clientHello(width: 3024, height: 1964, refresh: 120, bitrateMbps: 120,
                              wantsInput: true, codecs: 0b11, name: "Mac", video: video, displayScale: scale)
        }
        let plain = hello(video: nil, scale: nil)
        let afterName = { (m: Data) in Array(m.suffix(from: m.startIndex + plain.count)) }
        XCTAssertEqual(afterName(hello(video: nil, scale: 200)), [0, 0, 0, 200],
                       "the picture-option bytes are sent as 0, 0 when nothing is wanted")
        XCTAssertEqual(afterName(hello(video: .init(quality: 2, flags: VideoFlags.tenBit), scale: 150)),
                       [2, VideoFlags.tenBit, 0, 150])
        XCTAssertEqual(afterName(hello(video: nil, scale: 300)), [0, 0, 0x01, 0x2c], "big-endian")
        XCTAssertEqual(afterName(hello(video: nil, scale: 0)), [0, 0, 0, 0])
        XCTAssertEqual(afterName(hello(video: .init(quality: 1, flags: 0), scale: nil)), [1, 0],
                       "without the capability, today's CLIENT_HELLO")
        // Header: type, flags, two reserved bytes, u32 payload length.
        XCTAssertEqual(hello(video: nil, scale: 200).be32(at: 4), UInt32(plain.count - Proto.headerSize + 4))
    }

    func testClientHelloExtensionAndStreamStartFormat() {
        let plain = Proto.clientHello(width: 100, height: 50, refresh: 120, bitrateMbps: 120,
                                      wantsInput: true, codecs: 0b11, name: "Mac")
        let extended = Proto.clientHello(width: 100, height: 50, refresh: 120, bitrateMbps: 120,
                                         wantsInput: true, codecs: 0b11, name: "Mac",
                                         video: .init(quality: 2, flags: VideoFlags.fullColor | VideoFlags.tenBit))
        XCTAssertEqual(extended.count, plain.count + 2)
        XCTAssertEqual(Array(extended.suffix(2)), [2, 0b11])
        XCTAssertEqual(extended.prefix(4), plain.prefix(4)) // same type; length differs

        let hello = { (caps: [UInt8]) in Proto.ServerHello(Data([0, 4, 2]) + Data("PC".utf8) + Data([1]) + Data(caps)) }
        XCTAssertEqual(hello([0x07])?.supportsDisplayScale, false)
        XCTAssertEqual(hello([0x0f])?.supportsDisplayScale, true)
        XCTAssertEqual(hello([])?.supportsVideoOptions, false)
        XCTAssertEqual(hello([Proto.capPairName])?.supportsVideoOptions, false)
        XCTAssertEqual(hello([Proto.capPairName | Proto.capVideoOptions])?.supportsVideoOptions, true)

        let header: [UInt8] = [0x0b, 0xd0, 0x07, 0xac, 0, 120, 0, 120, 2]
        let old = Proto.StreamStart(Data(header + [0]))
        XCTAssertNil(old?.quality)
        XCTAssertEqual(old?.formatSettings, [])
        // Typed: Xcode 16's compiler infers Int for an OR of literals here.
        let format: UInt8 = 0x04 | 0x08 | 0x02
        let rich = Proto.StreamStart(Data(header + [format]))
        XCTAssertEqual(rich?.quality, .balanced)
        XCTAssertEqual(rich?.fullColor, true)
        XCTAssertEqual(rich?.tenBit, true)
        XCTAssertEqual(rich?.formatSettings, ["4:4:4", "10-bit", "Balanced"])
    }

    private func host(_ name: String, key: UInt8, enc: String?) -> DiscoveredHost {
        var host = DiscoveredHost(name: name, endpoint: .service(name: name, type: Proto.serviceType, domain: "local.", interface: nil),
                                  interfaces: [], publicKey: Data(repeating: key, count: 32))
        host.facts.videoFeatures = enc.map(VideoFeatures.init(txt:))
        return host
    }

    @MainActor func testPickerBitrateAndOptionGating() async {
        let model = PickerModel()
        model.connectsOverWiFi = { $0.name == "Air" }
        model.macDecodes = { $0 != .tenBit }
        model.configure(native: CGSize(width: 3024, height: 1964), maxRefresh: 120, initial: StreamMode(scale: 1, refresh: 120))
        let old = host("Old", key: 1, enc: nil), new = host("New", key: 2, enc: "q,444,10"), air = host("Air", key: 3, enc: "q")
        let known = [old.publicKey!: "Old", new.publicKey!: "New", air.publicKey!: "Air"]
        model.update(hosts: [old, new, air], known: known, nicknames: [:])

        // Automatic follows the mode and the selected PC's link.
        model.selection = "New"
        XCTAssertEqual(model.effectiveBitrate, 120)
        model.setMode(StreamMode(scale: 1, refresh: 60))
        XCTAssertEqual(model.effectiveBitrate, 60)
        model.selection = "Air"
        model.setMode(StreamMode(scale: 1, refresh: 120))
        XCTAssertEqual(model.effectiveBitrate, 80)
        // Turning Automatic off keeps the value shown; picking one ends it.
        model.setBitrateAutomatic(false)
        XCTAssertEqual(model.prefs.bitrateMbps, 80)
        XCTAssertEqual(model.effectiveBitrate, 80)
        model.setBitrateAutomatic(true)
        // The field committing the value it shows is not a choice.
        model.setBitrate(model.effectiveBitrate)
        XCTAssertTrue(model.prefs.bitrateAutomatic)
        model.setBitrate(300)
        XCTAssertFalse(model.prefs.bitrateAutomatic)
        XCTAssertEqual(model.effectiveBitrate, 300)

        // Options follow the selected PC's TXT and this Mac.
        model.selection = "Old"
        XCTAssertEqual(model.availability(.encoderQuality), .pcNeedsUpdate)
        model.selection = "Air"
        XCTAssertEqual(model.availability(.encoderQuality), .available)
        XCTAssertEqual(model.availability(.fullColor), .pcCannot)
        model.selection = "New"
        XCTAssertEqual(model.availability(.fullColor), .available)
        XCTAssertEqual(model.availability(.tenBit), .macCannot)
    }
}
