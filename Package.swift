// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BabylonAudio",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "BabylonAudio",
            targets: ["BabylonAudio"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(name: "BabylonAudio"),
        .testTarget(
            name: "BabylonAudioTests",
            dependencies: ["BabylonAudio"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

