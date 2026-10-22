// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeSessionBar", path: "Sources/ClaudeSessionBar")
    ]
)
