// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenLyrics",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenLyrics",
            path: "Sources/OpenLyrics"
        ),
        .testTarget(
            name: "OpenLyricsTests",
            dependencies: ["OpenLyrics"],
            path: "Tests/OpenLyricsTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
