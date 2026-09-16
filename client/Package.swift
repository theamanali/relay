// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TravelDisplay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TravelDisplay",
            path: "Sources/TravelDisplay",
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
        .testTarget(name: "TravelDisplayTests", dependencies: ["TravelDisplay"]),
    ]
)
