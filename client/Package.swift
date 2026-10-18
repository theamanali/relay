// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Relay",
            path: "Sources/Relay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(name: "RelayTests", dependencies: ["Relay"]),
    ],
    swiftLanguageModes: [.v6]
)
