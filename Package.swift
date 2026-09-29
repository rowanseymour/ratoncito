// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ratoncito",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ratoncito", path: "Sources/ratoncito")
    ]
)
