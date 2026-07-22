import Foundation
import Testing

@Suite("Regression script contracts", .serialized)
struct RegressionScriptTests {
    @Test func testUnavailableVADPlatformAcceptsExplicitIntegrationSkip() throws {
        let result = try runRegressionScript(vadIntegrationWasExplicitlySkipped: true)

        #expect(result.terminationStatus == 0,
                "An unavailable VAD platform must accept the suite's explicit skip. Output:\n\(result.output)")
        #expect(result.output.contains("VAD integration.. skipped (VAD is unavailable on this platform)"))
        #expect(!result.output.contains("VADIntegrationTests matched 0 tests"))
    }

    @Test func testUnavailableVADPlatformRejectsUnverifiedZeroTestResult() throws {
        let result = try runRegressionScript(vadIntegrationWasExplicitlySkipped: false)

        #expect(result.terminationStatus != 0,
                "A zero-test VAD result without the exact suite-skip marker must fail")
        #expect(result.output.contains("FAILED: VADIntegrationTests should skip when VAD is unavailable"))
    }

    private func runRegressionScript(
        vadIntegrationWasExplicitlySkipped: Bool
    ) throws -> (terminationStatus: Int32, output: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakflow-regression-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        try writeExecutable(
            named: "uname",
            in: fixtureDirectory,
            contents: """
            #!/usr/bin/env bash
            printf 'x86_64\\n'
            """
        )

        let explicitSkipOutput = vadIntegrationWasExplicitlySkipped
            ? "echo '◇ Suite \"VAD Integration — Volume Gate + Smoothing + State Reset\" skipped.'"
            : "echo '◇ VAD integration suite produced no test cases.'"
        try writeExecutable(
            named: "swift",
            in: fixtureDirectory,
            contents: """
            #!/usr/bin/env bash
            set -euo pipefail

            suite=""
            while (($#)); do
              if [[ "$1" == "--filter" ]]; then
                shift
                suite="${1:-}"
                break
              fi
              shift
            done

            if [[ "$suite" == "VADIntegrationTests" ]]; then
              \(explicitSkipOutput)
              echo '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'
            elif [[ "$suite" == "VADModelCacheTests" ]]; then
              echo '◇ Test testWarmUpIsIdempotent() skipped.'
              echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'
            else
              echo '◇ Test testPlaceholder() started.'
              echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'
            fi
            """
        )

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repositoryRoot.appendingPathComponent("scripts/test-regression-core.sh").path]
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fixtureDirectory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["SPEAKFLOW_REGRESSION_SKIP_BUILD"] = "1"
        environment["SPEAKFLOW_REGRESSION_STRESS_RUNS"] = "1"
        environment["SPEAKFLOW_REGRESSION_LOG_FILE"] = fixtureDirectory.appendingPathComponent("regression.log").path
        environment["SPEAKFLOW_OBSERVABILITY_DIR"] = fixtureDirectory.appendingPathComponent("observability").path
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    private func writeExecutable(named name: String, in directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
