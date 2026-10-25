import Foundation
import Testing

/// AppKit button activation can stop the Swift async-main queue drain on this
/// runtime. Keep those native interactions in their own test process, and require
/// a completed test summary, not merely a successful process exit.
enum NativeUIProbeSupport {
    private static let childKey = "SPEAKFLOW_NATIVE_UI_CHILD"

    static func isChild(for suite: String) -> Bool {
        ProcessInfo.processInfo.environment[childKey] == suite
    }

    static func runChild(suite: String, environmentOverrides: [String: String] = [:]) throws {
        let arguments = CommandLine.arguments
        let bundleOption = try #require(arguments.firstIndex(of: "--test-bundle-path"))
        try #require(arguments.indices.contains(bundleOption + 1))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = [
            "--test-bundle-path", arguments[bundleOption + 1],
            "--testing-library", "swift-testing", "--no-parallel", "--filter", suite
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(environmentOverrides) { _, override in override }
        environment[childKey] = suite
        environment["SPEAKFLOW_RUN_UI_PROBES"] = "1"
        environment["SPEAKFLOW_ISOLATED_STORAGE"] = "1"
        environment["SPEAKFLOW_ISOLATE_TEST_AUDIO"] = "1"
        environment["SPEAKFLOW_MUTE_SOUNDS"] = "1"
        environment["SPEAKFLOW_OBSERVABILITY_DIR"] = "/dev/null/speakflow-observability"
        environment["SPEAKFLOW_RUN_LIVE_MISTRAL"] = nil
        environment["SPEAKFLOW_RUN_VAD_MODEL_TESTS"] = nil
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Native UI child failed: \(output)")
        #expect(output.contains("Test run with 1 test in 1 suite passed"),
                "Native UI child did not complete its assertions: \(output)")
    }
}
