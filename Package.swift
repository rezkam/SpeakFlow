// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Core library with testable business logic
        .target(
            name: "SpeakFlowCore",
            path: "Sources/SpeakFlowCore"
        ),
        // Main executable
        .executableTarget(
            name: "SpeakFlow",
            dependencies: ["SpeakFlowCore"],
            path: "Sources/App",
            resources: [
                .process("../Resources")
            ]
        ),
    ]
)
