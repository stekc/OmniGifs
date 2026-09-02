// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OmniGifs",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "OmniGifs", targets: ["OmniGifs"])
    ],
    targets: [
        .executableTarget(
            name: "OmniGifs",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreML"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Vision"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "OmniGifsTests",
            dependencies: ["OmniGifs"]
        ),
    ]
)
