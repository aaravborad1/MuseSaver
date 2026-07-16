// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuseSaver",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MuseSaver",
            path: "Sources/MuseSaver"
        )
    ]
)
