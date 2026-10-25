// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras.git", from: "1.4.3"),
    ],
    targets: [
        // Core library with testable business logic
        .target(
            name: "SpeakFlowCore",
            dependencies: [
                "FluidAudio"
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
        // Configuration and assertion contract shared by the live E2E runner
        // and its wrapper scripts
        .target(
            name: "LiveE2EKit",
            path: "Sources/LiveE2EKit"
        ),
        // End-to-end test runner (mock audio + real transcription API)
        .executableTarget(
            name: "SpeakFlowLiveE2E",
            dependencies: ["SpeakFlowCore", "LiveE2EKit"],
            path: "Sources/LiveE2E"
        ),
        // Deepgram streaming E2E tests (requires DEEPGRAM_API_KEY env var)
        .executableTarget(
            name: "DeepgramE2E",
            dependencies: ["SpeakFlowCore"],
            path: "Sources/DeepgramE2E"
        ),
        // Real mic + Deepgram streaming test (requires mic permission + DEEPGRAM_API_KEY)
        .executableTarget(
            name: "DeepgramTest",
            dependencies: ["SpeakFlowCore"],
            path: "Sources/DeepgramTest"
        ),
        .testTarget(
            name: "SpeakFlowCoreTests",
            dependencies: [
                "SpeakFlowCore",
                "SpeakFlow",
                "LiveE2EKit",
                "SpeakFlowLiveE2E",
                "DeepgramE2E",
                "DeepgramTest",
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
            ],
            path: "Tests"
        ),
    ]
)
