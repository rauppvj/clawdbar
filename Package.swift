// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ClawdBar",
            path: "Sources/ClawdBar",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "ClawdBarTests",
            dependencies: ["ClawdBar"],
            path: "Tests/ClawdBarTests"
        ),
    ]
)
