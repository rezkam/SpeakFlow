// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
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
        // Test target that can import the core library
        .testTarget(
            name: "SpeakFlowTests",
            dependencies: [
                "SpeakFlowCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests"
        ),
    ]
)
