// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        // Core library with testable business logic
        .target(
            name: "SpeakFlowCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
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
        // End-to-end test runner (mock audio + real transcription API)
        .executableTarget(
            name: "SpeakFlowLiveE2E",
            dependencies: ["SpeakFlowCore"],
            path: "Sources/LiveE2E"
        ),
        .testTarget(
            name: "SpeakFlowCoreTests",
            dependencies: ["SpeakFlowCore"],
            path: "Tests",
            sources: ["VADTests.swift"]
        ),
    ]
)
