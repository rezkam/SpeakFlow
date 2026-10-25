import Foundation
import Testing

@Suite("Regression script contracts", .serialized)
struct RegressionScriptTests {
    #if DEBUG
    @Test(arguments: [
        "scripts/test-e2e-runtime-policy.sh", "scripts/test-e2e-fixture-lifecycle.sh",
        "scripts/test-provider-executable-policy.sh", "scripts/test-e2e-store-isolation.sh"
    ])
    func liveExecutablePolicyAndFixtureLifecycle(script: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Executable probe failed: \(output)")
        #expect(output.contains("PASS:"))
    }
    #endif

    @Test(arguments: ["scripts/test-chunk-wrapper.sh", "scripts/test-noise-wrapper.sh", "scripts/test-modern-e2e-wrappers.sh"])
    func legacyWrappersRequireExecutedAssertionsAndSuccessfulExit(script: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Offline wrapper probes failed: \(output)")
        let expected = script.contains("noise") ? 14 : 15
        #expect(output.split(separator: "\n").filter { $0.hasPrefix("PASS:") }.count == expected)
    }

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

    @Test func regressionScriptPreservesFailureThroughRedaction() throws {
        let result = try runRegressionScript(vadIntegrationWasExplicitlySkipped: true, testProcessFails: true)
        #expect(result.terminationStatus != 0)
        #expect(result.output.contains("FAILED: DictationReadinessTests"))
    }

    @Test func regressionPrefetchAndModelSuitesShareAnIsolatedCache() throws {
        let result = try runRegressionScript(vadIntegrationWasExplicitlySkipped: false, vadPlatformAvailable: true)
        #expect(result.terminationStatus == 0, "\(result.output)")
        #expect(result.output.contains("Status: ALL OK"))
    }

    @Test func regressionCanSuppressSharedDiagnosticsWithoutSkippingModelGates() throws {
        let result = try runRegressionScript(
            vadIntegrationWasExplicitlySkipped: false, vadPlatformAvailable: true,
            suppressSharedDiagnostics: true
        )
        #expect(result.terminationStatus == 0, "\(result.output)")
    }

    private func runRegressionScript(
        vadIntegrationWasExplicitlySkipped: Bool,
        testProcessFails: Bool = false,
        vadPlatformAvailable: Bool = false,
        suppressSharedDiagnostics: Bool = false
    ) throws -> (terminationStatus: Int32, output: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureDirectory = repositoryRoot
            .appendingPathComponent(".agents/tests/regression-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        try writeExecutable(
            named: "uname",
            in: fixtureDirectory,
            contents: """
            #!/usr/bin/env bash
            printf '\(vadPlatformAvailable ? "arm64" : "x86_64")\\n'
            """
        )

        let explicitSkipOutput = vadPlatformAvailable
            ? "echo '◇ Test testSyntheticModelIntegration() started.'"
            : vadIntegrationWasExplicitlySkipped
            ? "echo '◇ Suite \"VAD Integration — Volume Gate + Smoothing + State Reset\" skipped.'"
            : "echo '◇ VAD integration suite produced no test cases.'"
        try writeExecutable(
            named: "swift",
            in: fixtureDirectory,
            contents: """
            #!/usr/bin/env bash
            set -euo pipefail

            [[ -z "${SPEAKFLOW_RUN_LIVE_MISTRAL:-}" ]] || exit 64
            [[ "${SPEAKFLOW_ISOLATED_STORAGE:-}" == 1 ]] || exit 65
            [[ "${SPEAKFLOW_VAD_MODEL_CACHE_ROOT:-}" == "$EXPECTED_MODEL_CACHE_ROOT" ]] || exit 66
            [[ "${SPEAKFLOW_OBSERVABILITY_DIR:-}" == "$EXPECTED_OBSERVABILITY_DIR" ]] || exit 68
            echo '/Users/example-user/fixture.swift: synthetic diagnostic'
            echo 'Host environment: synthetic-host-context'
            echo 'Compiled model fixture.mlmodelc in 1 ms :: macOS Version synthetic-system, chip=synthetic-chip'
            echo 'synthetic-process[12345:67890]: diagnostic'
            echo 'Process 12345 stopped'
            suite=""
            while (($#)); do
              if [[ "$1" == "--filter" ]]; then
                shift
                suite="${1:-}"
                break
              fi
              shift
            done

            if [[ "$suite" == "VADModelPrefetchTests" ]]; then
              mkdir -p "$SPEAKFLOW_VAD_MODEL_CACHE_ROOT"
              : > "$SPEAKFLOW_VAD_MODEL_CACHE_ROOT/prefetched"
            fi
            if [[ "$suite" == "VADIntegrationTests" ]]; then
              if [[ "\(vadPlatformAvailable ? "1" : "0")" == 1 ]]; then
                [[ -f "$SPEAKFLOW_VAD_MODEL_CACHE_ROOT/prefetched" ]] || exit 67
              fi
              \(explicitSkipOutput)
              echo '✔ Test run with \(vadPlatformAvailable ? 1 : 0) tests in 1 suite passed after 0.001 seconds.'
            elif [[ "$suite" == "VADModelCacheTests" ]]; then
              echo '◇ Test testWarmUpIsIdempotent() \(vadPlatformAvailable ? "started" : "skipped").'
              echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'
            else
              echo '◇ Test testPlaceholder() started.'
              echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'
            fi
            exit \(testProcessFails ? 23 : 0)
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
        let modelRoot = fixtureDirectory.appendingPathComponent("vad-models").path
        environment["SPEAKFLOW_VAD_MODEL_CACHE_ROOT"] = modelRoot
        environment["EXPECTED_MODEL_CACHE_ROOT"] = modelRoot
        environment["SPEAKFLOW_RUN_LIVE_MISTRAL"] = "1"
        environment["SPEAKFLOW_REGRESSION_STRESS_RUNS"] = "1"
        environment["SPEAKFLOW_REGRESSION_LOG_FILE"] = fixtureDirectory.appendingPathComponent("regression.log").path
        let observabilityDirectory = fixtureDirectory.appendingPathComponent("observability")
        environment["SPEAKFLOW_OBSERVABILITY_DIR"] = observabilityDirectory.path
        environment["SPEAKFLOW_REGRESSION_SUPPRESS_DIAGNOSTICS"] = suppressSharedDiagnostics ? "1" : "0"
        environment["EXPECTED_OBSERVABILITY_DIR"] = suppressSharedDiagnostics
            ? "/dev/null/speakflow-observability" : observabilityDirectory.path
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let log = try String(contentsOf: fixtureDirectory.appendingPathComponent("regression.log"), encoding: .utf8)
        #expect(!log.contains("/Users/example-user"), "Diagnostics must be redacted before persistence")
        #expect(log.contains("<HOME>/fixture.swift"))
        #expect(!log.contains("synthetic-host-context"))
        #expect(!log.contains("synthetic-system"))
        #expect(!log.contains("synthetic-chip"))
        #expect(log.contains("Compiled model fixture.mlmodelc in 1 ms :: <HOST_CONTEXT_REDACTED>"))
        #expect(log.contains("<HOST_CONTEXT_REDACTED>"))
        #expect(!log.contains("12345"))
        #expect(!log.contains("67890"))
        #expect(log.contains("synthetic-process[PID:TID]: diagnostic"))
        #expect(log.contains("Process <PID> stopped"))
        if suppressSharedDiagnostics {
            #expect(!FileManager.default.fileExists(atPath: observabilityDirectory.path))
        }
        return (process.terminationStatus, output)
    }

    private func writeExecutable(named name: String, in directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
