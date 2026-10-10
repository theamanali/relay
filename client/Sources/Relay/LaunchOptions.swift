import AppKit
import Network

#if !arch(arm64)
#error("Relay supports Apple silicon Macs only.")
#endif

struct LaunchOptions {
    var fixedHost: NWEndpoint? = nil
    var maxFPS = 120
    var scale = 1.0
    /// Whether --max-fps / --scale were given; they override the remembered mode.
    var maxFPSGiven = false
    var scaleGiven = false
    var modifiers: ModifierMapping = .mac
    var modifiersGiven = false
    var noInput = false
    var pin: String? = nil
    var showLatency = false
    var metalVSync = false
    var bitrateMbps = VideoBitrate.defaultValue
    var bitrateGiven = false

    @MainActor
    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--host":
                // host:port or [v6]:port; skips Bonjour.
                if let v = it.next() {
                    let (host, port) = splitHostPort(v)
                    o.fixedHost = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .init(rawValue: Proto.defaultPort)!)
                }
            case "--max-fps":
                if let v = it.next(), let n = Int(v) { o.maxFPS = n; o.maxFPSGiven = true }
            case "--scale":
                if let v = it.next(), let s = Double(v) { o.scale = s; o.scaleGiven = true }
            case "--modifiers":
                if let v = it.next(), let m = ModifierMapping(rawValue: v) {
                    o.modifiers = m
                    o.modifiersGiven = true
                }
            case "--no-input":
                o.noInput = true
            case "--pin":
                if let v = it.next() { o.pin = v }
            case "--latency-stats":
                o.showLatency = true
            case "--bitrate":
                guard let value = it.next(), let bitrate = Int(value),
                      (VideoBitrate.minimum...VideoBitrate.maximum).contains(bitrate) else {
                    print("--bitrate requires a whole number from 1 through 1000 Mbps")
                    exit(2)
                }
                o.bitrateMbps = bitrate
                o.bitrateGiven = true
            case "--renderer":
                guard it.next() == "metal" else {
                    print("Relay now requires the Metal presenter; --renderer avsbdl is no longer supported")
                    exit(2)
                }
            case "--metal-vsync":
                o.metalVSync = true
            case "--render-icons":
                // Host tray icons from the picker's glyph; see host/assets/README.md.
                guard let dir = it.next() else {
                    print("--render-icons requires a directory")
                    exit(2)
                }
                exit(IconExport.run(into: dir))
            case "--render-app-icon":
                // AppIcon.icon and Relay.icns for bundle.sh; see client/Assets.
                guard let dir = it.next() else {
                    print("--render-app-icon requires a directory")
                    exit(2)
                }
                exit(IconExport.renderAppIcon(into: dir))
            case "--help", "-h":
                print("""
                Relay client
                  --host <addr[:port]>       connect directly instead of browsing Bonjour
                  --max-fps <n>              cap the requested refresh rate (default 120)
                  --scale <f>                request f x native pixel size (0.75 or 0.5 keep the aspect)
                                             (the picker offers both and remembers the last choice;
                                             these flags override it for this launch)
                  --modifiers mac|physical   mac: ⌘→Ctrl ⌥→Alt ⌃→Win (default); physical: by position
                  --no-input                 view only (toggle control with ⌃⌥⌘K)
                  --pin <digits>             pairing PIN shown by the host (asked for interactively otherwise)
                  --latency-stats            show live latency telemetry (toggle with ⌃⌥⌘L)
                  --bitrate <1...1000>       request this video bitrate in Mbps (default 120)
                  --metal-vsync              enable Metal VSync (default off; avoids tearing)
                  --render-icons <dir>       write the host's tray icons (relay-{light,dark}.ico) and exit
                  --render-app-icon <dir>    write the Mac app icon (AppIcon.icon, Relay.icns) and exit
                Exit with ⌃⌥⌘Q.
                """)
                exit(0)
            default:
                break
            }
        }
        return o
    }

    private static func splitHostPort(_ s: String) -> (String, UInt16) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? Proto.defaultPort : Proto.defaultPort
            return (host, port)
        }
        let parts = s.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) {
            return (String(parts[0]), port)
        }
        return (s, Proto.defaultPort)
    }
}

