// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MrPerfect",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MrPerfect", path: "Sources/MrPerfect"),
        .testTarget(name: "MrPerfectTests", dependencies: ["MrPerfect"], path: "Tests"),
    ]
)
