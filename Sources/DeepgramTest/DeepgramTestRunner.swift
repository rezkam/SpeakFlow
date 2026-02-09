import Foundation
import SpeakFlowCore
import AVFoundation

// ============================================================================
// DeepgramTest — Real Microphone + Deepgram Streaming E2E Tests
//
// These tests exercise the ACTUAL recording pipeline with a real microphone
// and live Deepgram WebSocket connection, exactly as the app uses it.
//
// Requires: DEEPGRAM_API_KEY env var + microphone permission
// ============================================================================

// Counters stored in enum to avoid top-level code (required for @main)
enum TestState {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var skipped = 0
}

@MainActor
func report(_ name: String, _ ok: Bool, _ reason: String = "") {
    if ok {
        TestState.passed += 1
        print("  ✅ PASS  \(name)")
    } else {
        TestState.failed += 1
        print("  ❌ FAIL  \(name)\(reason.isEmpty ? "" : " — \(reason)")")
    }
}

@MainActor
func skip(_ name: String, _ reason: String) {
    TestState.skipped += 1
    print("  ⏭️  SKIP  \(name) — \(reason)")
}

// MARK: - Helpers

@MainActor
func makeController() -> (LiveStreamingController, TestCallbacks) {
    let controller = LiveStreamingController()
    let cb = TestCallbacks()

    controller.onTextUpdate = { text, replacingChars, isFinal in
        cb.updates.append(TextUpdate(text: text, replacingChars: replacingChars, isFinal: isFinal))
    }
    controller.onUtteranceEnd = { cb.utteranceEnds += 1 }
    controller.onSpeechStarted = { cb.speechStarts += 1 }
    controller.onError = { error in cb.errors.append(error.localizedDescription) }
    controller.onSessionClosed = { cb.sessionClosed = true }

    return (controller, cb)
}

@MainActor
final class TestCallbacks {
    struct TextUpdateEntry {
        let text: String
        let replacingChars: Int
        let isFinal: Bool
    }
    var updates: [TextUpdateEntry] = []
    var utteranceEnds = 0
    var speechStarts = 0
    var errors: [String] = []
    var sessionClosed = false

    var finals: [TextUpdateEntry] { updates.filter { $0.isFinal } }
    var interims: [TextUpdateEntry] { updates.filter { !$0.isFinal } }
    var allText: String { finals.map(\.text).joined(separator: " ") }
}

typealias TextUpdate = TestCallbacks.TextUpdateEntry

// MARK: - Tests

/// 1. Start mic + Deepgram, verify no crash, stop cleanly.
@MainActor
func test01_StartStop() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, cb) = makeController()

    let started = await controller.start(provider: provider)
    guard started else { return false }

    // Let it run briefly with mic open
    try? await Task.sleep(for: .seconds(2))

    await controller.stop()

    // No crash, no errors = pass
    return cb.errors.isEmpty
}

/// 2. Rapid start/stop cycles — tests resource cleanup (engine, WebSocket, taps).
@MainActor
func test02_RapidStartStop() async -> Bool {
    let provider = DeepgramProvider()

    for i in 0..<3 {
        let (controller, cb) = makeController()
        let started = await controller.start(provider: provider)
        guard started else {
            print("    cycle \(i): failed to start")
            return false
        }
        try? await Task.sleep(for: .milliseconds(500))
        await controller.stop()
        if !cb.errors.isEmpty {
            print("    cycle \(i): errors: \(cb.errors)")
            return false
        }
    }
    return true
}

/// 3. Cancel mid-session — verify clean teardown.
@MainActor
func test03_Cancel() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, cb) = makeController()

    let started = await controller.start(provider: provider)
    guard started else { return false }

    try? await Task.sleep(for: .seconds(1))
    await controller.cancel()

    // Should not crash, no lingering errors
    try? await Task.sleep(for: .milliseconds(500))
    return cb.errors.isEmpty
}

/// 4. Silence only — mic open, nobody speaking.
///    Should get no finals, no transcription text.
@MainActor
func test04_SilenceOnly() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, cb) = makeController()

    let started = await controller.start(provider: provider)
    guard started else { return false }

    // 3 seconds of silence (don't speak!)
    try? await Task.sleep(for: .seconds(3))
    await controller.stop()

    // Silence should produce no meaningful transcription
    let meaningfulFinals = cb.finals.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    return meaningfulFinals.isEmpty
}

/// 5. Verify controller.recording reflects state correctly.
@MainActor
func test05_RecordingState() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, _) = makeController()

    guard !controller.recording else { return false }

    let started = await controller.start(provider: provider)
    guard started else { return false }
    guard controller.recording else { return false }

    await controller.stop()
    guard !controller.recording else { return false }

    return true
}

/// 6. Double-start is rejected.
@MainActor
func test06_DoubleStart() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, _) = makeController()

    let started1 = await controller.start(provider: provider)
    guard started1 else { return false }

    // Second start should return false
    let started2 = await controller.start(provider: provider)
    await controller.stop()

    return !started2
}

/// 7. Stop when not recording is a no-op (no crash).
@MainActor
func test07_StopWhenNotRecording() async -> Bool {
    let (controller, cb) = makeController()
    await controller.stop()
    return cb.errors.isEmpty
}

/// 8. Cancel when not recording is a no-op (no crash).
@MainActor
func test08_CancelWhenNotRecording() async -> Bool {
    let (controller, cb) = makeController()
    await controller.cancel()
    return cb.errors.isEmpty
}

/// 9. Bad API key → session should error or close shortly after start.
///    Deepgram accepts WebSocket connection then sends an error/close frame,
///    so start() may succeed but the session closes immediately after.
@MainActor
func test09_BadApiKey() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, cb) = makeController()

    // Temporarily set bad key
    let originalKey = ProviderSettings.shared.apiKey(for: "deepgram")
    ProviderSettings.shared.setApiKey("invalid_key_12345", for: "deepgram")

    let started = await controller.start(provider: provider)

    // Restore key
    ProviderSettings.shared.setApiKey(originalKey, for: "deepgram")

    if !started {
        // Failed at connect — good
        return true
    }

    // If start succeeded, the session should error or close within a few seconds
    try? await Task.sleep(for: .seconds(3))
    await controller.stop()

    return !cb.errors.isEmpty || cb.sessionClosed
}

/// 10. Provider settings persistence round-trip.
@MainActor
func test10_ProviderSettings() async -> Bool {
    let original = ProviderSettings.shared.activeProviderId

    ProviderSettings.shared.activeProviderId = "deepgram"
    let isDg = ProviderSettings.shared.activeProviderId == "deepgram"

    ProviderSettings.shared.activeProviderId = "gpt"
    let isGpt = ProviderSettings.shared.activeProviderId == "gpt"

    ProviderSettings.shared.activeProviderId = original
    return isDg && isGpt
}

/// 11. Validate key endpoint works for good key.
@MainActor
func test11_ValidateGoodKey() async -> Bool {
    guard let key = ProviderSettings.shared.apiKey(for: "deepgram") else { return false }
    let error = await ProviderSettings.shared.validateDeepgramKey(key)
    return error == nil
}

/// 12. Validate key endpoint rejects bad key.
@MainActor
func test12_ValidateBadKey() async -> Bool {
    let error = await ProviderSettings.shared.validateDeepgramKey("totally_invalid_key")
    return error != nil
}

/// 13. Long recording session — 10 seconds with mic open.
///     Verifies no resource leaks, no timeouts, no disconnects.
@MainActor
func test13_LongSession() async -> Bool {
    let provider = DeepgramProvider()
    let (controller, cb) = makeController()

    let started = await controller.start(provider: provider)
    guard started else { return false }

    try? await Task.sleep(for: .seconds(10))
    await controller.stop()

    // Should complete without errors or unexpected closure
    return cb.errors.isEmpty && !cb.sessionClosed
}

// MARK: - Runner

@MainActor
func runAllTests() async {
    guard let apiKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !apiKey.isEmpty else {
        print("❌ Set DEEPGRAM_API_KEY env var")
        exit(1)
    }

    // Check mic permission
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    if micStatus != .authorized {
        print("⚠️  Requesting microphone permission...")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
            print("❌ Microphone permission denied — cannot run tests")
            exit(1)
        }
    }

    ProviderSettings.shared.setApiKey(apiKey, for: "deepgram")

    print("═══════════════════════════════════════════════════")
    print("  DeepgramTest — Real Mic + Deepgram E2E Tests")
    print("═══════════════════════════════════════════════════")
    print()

    let tests: [(String, () async -> Bool)] = [
        ("Start/stop no crash",        test01_StartStop),
        ("Rapid start/stop (3x)",      test02_RapidStartStop),
        ("Cancel mid-session",         test03_Cancel),
        ("Silence only (no text)",     test04_SilenceOnly),
        ("Recording state tracking",   test05_RecordingState),
        ("Double-start rejected",      test06_DoubleStart),
        ("Stop when not recording",    test07_StopWhenNotRecording),
        ("Cancel when not recording",  test08_CancelWhenNotRecording),
        ("Bad API key fails",          test09_BadApiKey),
        ("Provider settings persist",  test10_ProviderSettings),
        ("Validate good key",          test11_ValidateGoodKey),
        ("Validate bad key",           test12_ValidateBadKey),
        ("Long session (10s)",         test13_LongSession),
    ]

    for (name, test) in tests {
        let ok = await test()
        report(name, ok)
    }

    print()
    print("═══════════════════════════════════════════════════")
    print("  Results: \(TestState.passed) passed, \(TestState.failed) failed, \(TestState.skipped) skipped")
    print("           out of \(TestState.passed + TestState.failed + TestState.skipped) tests")
    print("═══════════════════════════════════════════════════")

    if TestState.failed > 0 {
        exit(1)
    }
}

@main
enum DeepgramTestEntry {
    static func main() {
        // Schedule async work, then pump main dispatch queue for MainActor + URLSession
        Task { @MainActor in
            await runAllTests()
            exit(0)
        }
        dispatchMain()
    }
}
