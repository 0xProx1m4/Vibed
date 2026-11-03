// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tide",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Tide", path: "Sources/Tide")
    ]
)
