// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SpeakFlow",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
