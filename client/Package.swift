// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Relay",
            path: "Sources/Relay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(name: "RelayTests", dependencies: ["Relay"]),
    ]
)
