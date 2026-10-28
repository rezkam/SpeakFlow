import Darwin
import Foundation
import Testing
@testable import SpeakFlowCore

private enum FatalIOChild {
    static let key = "SPEAKFLOW_FATAL_IO_CHILD"

    static func isChild(_ suite: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == suite
    }

    static func run(_ suite: String) throws {
        let args = CommandLine.arguments
        let bundleIndex = try #require(args.firstIndex(of: "--test-bundle-path"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = ["--test-bundle-path", args[bundleIndex + 1],
                             "--testing-library", "swift-testing", "--no-parallel", "--filter", suite]
        var environment = ProcessInfo.processInfo.environment
        environment[key] = suite
        environment["SPEAKFLOW_ISOLATED_STORAGE"] = "1"
        environment["SPEAKFLOW_ISOLATE_TEST_AUDIO"] = "1"
        environment["SPEAKFLOW_MUTE_SOUNDS"] = "1"
        environment["SPEAKFLOW_OBSERVABILITY_DIR"] = "/dev/null/speakflow-observability"
        environment["SPEAKFLOW_RUN_LIVE_MISTRAL"] = nil
        environment["SPEAKFLOW_RUN_VAD_MODEL_TESTS"] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0,
                "I/O child terminated: status=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)")
        let completed = text.contains("Test run with 1 test in 1 suite passed")
        #expect(completed, "I/O child must complete assertions")
    }

    static func disableCoreDumps() {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &limit)
    }
}

struct OAuthResetPeerTests {
    @Test func resetPeerErrorResponseSurvivesDefaultSIGPIPE() throws {
        let suite = "OAuthResetPeerTests"
        guard FatalIOChild.isChild(suite) else {
            try FatalIOChild.run(suite)
            return
        }
        FatalIOChild.disableCoreDumps()
        signal(SIGPIPE, SIG_DFL)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        try #require(named == 0)
        let peer = socket(AF_INET, SOCK_STREAM, 0)
        try #require(peer >= 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(peer, $0, size) }
        }
        try #require(connected == 0)
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        defer { close(accepted) }
        let server = OAuthCallbackServer(expectedState: "synthetic-state")
        #expect(server.prepareClientSocket(-1) == false)
        try #require(server.prepareClientSocket(accepted))
        var noSignal: Int32 = 0
        var optionSize = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &optionSize) == 0)
        #expect(noSignal == 1)
        var reset = linger(l_onoff: 1, l_linger: 0)
        try #require(setsockopt(peer, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) == 0)
        close(peer)
        // Consume the reset synchronously so the error response deterministically
        // encounters EPIPE, rather than relying on packet timing or sleeps.
        var ready = pollfd(fd: accepted, events: Int16(POLLIN), revents: 0)
        try #require(poll(&ready, 1, 1_000) == 1)
        var byte: UInt8 = 0
        try #require(Darwin.read(accepted, &byte, 1) == -1)
        try #require(errno == ECONNRESET)
        server.handlePreparedClientForTesting(accepted)
    }
}

struct ObservabilityWriteFailureTests {
    @Test func kernelWriteFailureRemainsBestEffort() async throws {
        let suite = "ObservabilityWriteFailureTests"
        guard FatalIOChild.isChild(suite) else {
            try FatalIOChild.run(suite)
            return
        }
        FatalIOChild.disableCoreDumps()
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/tests/observability-failure/\(UUID().uuidString)")
        let store = ObservabilityStore(
            baseDirectory: base, maxFileBytes: 0,
            runtimeContext: ObservabilityRuntimeContext(
                profile: "fixture", processId: 0, processName: "fixture", systemContext: [:]
            )
        )
        await store.applyConfiguration(enabled: true, verbosity: .verbose,
                                       captureSettingsSnapshot: false, captureSystemContext: false,
                                       captureTextPayloads: false)
        let info = await store.pathInfoValue()
        let before = try Data(contentsOf: info.eventsFile)
        try await store.useReadOnlyEventsHandleForTesting()
        await store.record(component: "Test", name: "controlled_write_failure", level: .info)
        await store.record(component: "Test", name: "another_write_failure", level: .info)
        #expect(try Data(contentsOf: info.eventsFile) == before)
        #expect(await store.captureTextPayloadsEnabled() == false)
    }
}
