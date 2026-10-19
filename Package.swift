// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Talk007",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Talk007",
            path: "Sources/Talk007",
            linkerSettings: [.linkedFramework("AVKit"), .linkedFramework("AVFoundation")]
        )
    ]
)
