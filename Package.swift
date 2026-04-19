// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "game-art-generator",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "game-art-generator",
            targets: ["GameArtGenerator"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GameArtGenerator"
        )
    ]
)
