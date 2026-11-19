// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlipperFiles",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FlipperFiles", path: "Sources/FlipperFiles")
    ]
)
