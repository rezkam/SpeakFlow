// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0")
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
        // Test executable (runs without XCTest/swift-testing)
        .executableTarget(
            name: "SpeakFlowTestRunner",
            dependencies: ["SpeakFlowCore"],
            path: "Tests",
            sources: ["TestRunner.swift"]
        ),
    ]
)
