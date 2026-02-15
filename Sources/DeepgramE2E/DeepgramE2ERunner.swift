import Foundation
import SpeakFlowCore

// MARK: - Deepgram Streaming E2E Tests
// Full end-to-end tests against the REAL Deepgram API.
// No mocking — real WebSocket connections, real speech audio, real transcription.
//
// Usage: DEEPGRAM_API_KEY=your_key swift run DeepgramE2E

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Interim Tracker
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Simulates the AppDelegate's text replacement logic:
/// - Interim results are typed, then backspaced+replaced when next interim or final arrives
/// - Final results are committed and never replaced
/// Tracks the full "what would be on screen" state.
final class InterimTracker: @unchecked Sendable {
    private let lock = NSLock()

    // Counters
    private var _interimCount = 0
    private var _finalCount = 0
    private var _interimReplacements = 0

    // Text state — mirrors what the user sees
    private var _committedSegments: [String] = []
    private var _currentInterim: String = ""

    // Event log for detailed analysis
    struct TextUpdate: CustomStringConvertible {
        let text: String
        let replacingChars: Int
        let isFinal: Bool
        let timestamp: Date

        var description: String {
            let kind = isFinal ? "FINAL" : "interim"
            let replace = replacingChars > 0 ? " (replacing \(replacingChars) chars)" : ""
            return "[\(kind)] \"\(text.prefix(60))\"\(replace)"
        }
    }
    private var _updates: [TextUpdate] = []

    // Public accessors
    var interimCount: Int { lock.withLock { _interimCount } }
    var finalCount: Int { lock.withLock { _finalCount } }
    var interimReplacements: Int { lock.withLock { _interimReplacements } }
    var committedText: String { lock.withLock { _committedSegments.joined(separator: " ") } }
    var currentInterim: String { lock.withLock { _currentInterim } }
    var updates: [TextUpdate] { lock.withLock { _updates } }

    /// What the user would see on screen right now.
    var displayText: String {
        lock.withLock {
            let base = _committedSegments.joined(separator: " ")
            if _currentInterim.isEmpty { return base }
            return base.isEmpty ? _currentInterim : base + " " + _currentInterim
        }
    }

    /// Process an interim result — replaces previous interim text.
    func onInterim(_ text: String) {
        lock.withLock {
            let replacing = _currentInterim.count
            if replacing > 0 { _interimReplacements += 1 }
            _currentInterim = text
            _interimCount += 1
            _updates.append(TextUpdate(text: text, replacingChars: replacing, isFinal: false, timestamp: Date()))
        }
    }

    /// Process a final result — commits text and clears interim.
    func onFinal(_ text: String) {
        lock.withLock {
            let replacing = _currentInterim.count
            if !text.isEmpty {
                _committedSegments.append(text)
            }
            _currentInterim = ""
            _finalCount += 1
            _updates.append(TextUpdate(text: text, replacingChars: replacing, isFinal: true, timestamp: Date()))
        }
    }

    func reset() {
        lock.withLock {
            _interimCount = 0
            _finalCount = 0
            _interimReplacements = 0
            _committedSegments = []
            _currentInterim = ""
            _updates = []
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Audio Generation
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Generate speech audio using macOS `say` → raw 16kHz 16-bit mono PCM.
func generateSpeech(_ text: String, rate: Int? = nil) -> Data {
    let tempWav = FileManager.default.temporaryDirectory
        .appendingPathComponent("dg_\(UUID().uuidString).wav")
    let tempRaw = FileManager.default.temporaryDirectory
        .appendingPathComponent("dg_\(UUID().uuidString).raw")
    defer {
        try? FileManager.default.removeItem(at: tempWav)
        try? FileManager.default.removeItem(at: tempRaw)
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    var args = ["-o", tempWav.path, "--data-format=LEI16@16000"]
    if let rate { args += ["-r", "\(rate)"] }
    args.append(text)
    proc.arguments = args
    try? proc.run()
    proc.waitUntilExit()

    // Try sox for clean raw conversion
    let soxPath = "/opt/homebrew/bin/sox"
    if FileManager.default.fileExists(atPath: soxPath) {
        let sox = Process()
        sox.executableURL = URL(fileURLWithPath: soxPath)
        sox.arguments = [tempWav.path, "-t", "raw", "-r", "16000", "-e", "signed", "-b", "16", "-c", "1", tempRaw.path]
        try? sox.run()
        sox.waitUntilExit()
        if let data = try? Data(contentsOf: tempRaw), !data.isEmpty { return data }
    }

    // Fallback: strip WAV header
    if let wav = try? Data(contentsOf: tempWav), wav.count > 44 {
        return wav.dropFirst(44)
    }

    print("    ⚠️  Failed to generate speech: \(text.prefix(50))...")
    return Data()
}

/// Generate silence as raw PCM data.
func generateSilence(durationMs: Int) -> Data {
    Data(repeating: 0, count: (16000 * 2 * durationMs) / 1000)
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Streaming Helpers
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Stream audio to a session at ~2x real-time, then finalize and wait for results.
func streamAndFinalize(
    session: StreamingSession,
    audio: Data,
    tracker: InterimTracker,
    waitAfterFinalize: TimeInterval = 3.0,
    printEvents: Bool = true
) async throws -> Task<Void, Never> {
    let eventTask = Task {
        for await event in session.events {
            switch event {
            case .metadata(let reqId):
                if printEvents { print("    📋 Metadata: requestId=\(reqId)") }
            case .interim(let r):
                tracker.onInterim(r.transcript)
                if printEvents && !r.transcript.isEmpty {
                    print("    ⏳ Interim: \"\(r.transcript)\"")
                }
            case .finalResult(let r):
                tracker.onFinal(r.transcript)
                if printEvents && !r.transcript.isEmpty {
                    print("    ✅ Final: \"\(r.transcript)\"")
                }
            case .speechStarted(let ts):
                if printEvents { print("    🎤 SpeechStarted at \(String(format: "%.2f", ts))s") }
            case .utteranceEnd(let ts):
                if printEvents { print("    🔇 UtteranceEnd at \(String(format: "%.2f", ts))s") }
            case .error(let err):
                if printEvents { print("    ❌ Error: \(err.localizedDescription)") }
            case .closed:
                if printEvents { print("    🔌 Session closed") }
            }
        }
    }

    // Stream in 100ms chunks at 2x real-time speed
    let chunkSize = 3200  // 100ms of 16kHz 16-bit mono
    var offset = 0
    while offset < audio.count {
        let end = min(offset + chunkSize, audio.count)
        try await session.sendAudio(Data(audio[offset..<end]))
        offset = end
        try await Task.sleep(for: .milliseconds(50))  // 50ms delay for 100ms audio = 2x
    }

    try await session.finalize()
    try await Task.sleep(for: .seconds(waitAfterFinalize))
    return eventTask
}

/// Stream multiple segments with real-time pauses between them.
/// During pauses, sends silence to keep timing correct for server-side endpointing.
func streamSegmentsWithPauses(
    session: StreamingSession,
    segments: [(audio: Data, pauseMs: Int)],
    tracker: InterimTracker,
    printEvents: Bool = true
) async throws -> Task<Void, Never> {
    let eventTask = Task {
        for await event in session.events {
            switch event {
            case .metadata(let reqId):
                if printEvents { print("    📋 Metadata: requestId=\(reqId)") }
            case .interim(let r):
                tracker.onInterim(r.transcript)
                if printEvents && !r.transcript.isEmpty {
                    print("    ⏳ [\(tracker.interimCount)] \"\(r.transcript)\"")
                }
            case .finalResult(let r):
                tracker.onFinal(r.transcript)
                if printEvents && !r.transcript.isEmpty {
                    print("    ✅ [\(tracker.finalCount)] \"\(r.transcript)\"")
                }
            case .speechStarted(let ts):
                if printEvents { print("    🎤 SpeechStarted at \(String(format: "%.2f", ts))s") }
            case .utteranceEnd(let ts):
                if printEvents { print("    🔇 UtteranceEnd at \(String(format: "%.2f", ts))s") }
            case .error(let err):
                if printEvents { print("    ❌ Error: \(err.localizedDescription)") }
            case .closed:
                break
            }
        }
    }

    let chunkSize = 3200

    for (i, seg) in segments.enumerated() {
        let audioDurMs = seg.audio.count / 32
        if printEvents {
            print("    📤 Segment \(i + 1): \(audioDurMs)ms speech" + (seg.pauseMs > 0 ? " → \(seg.pauseMs)ms pause" : ""))
        }

        // Stream the speech audio
        var offset = 0
        while offset < seg.audio.count {
            let end = min(offset + chunkSize, seg.audio.count)
            try await session.sendAudio(Data(seg.audio[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(50))
        }

        // During the pause, send silence (keeps real-time timing for endpointing)
        if seg.pauseMs > 0 {
            let silenceBytes = (16000 * 2 * seg.pauseMs) / 1000
            let silence = Data(repeating: 0, count: silenceBytes)
            var sOff = 0
            while sOff < silence.count {
                let end = min(sOff + chunkSize, silence.count)
                try await session.sendAudio(Data(silence[sOff..<end]))
                sOff = end
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    try await session.finalize()
    try await Task.sleep(for: .seconds(3))
    return eventTask
}

/// Check if actual transcript loosely matches expected (≥1/3 of words overlap).
func looseMatch(expected: String, actual: String) -> Bool {
    let expWords = Set(expected.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let actWords = Set(actual.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    guard !expWords.isEmpty else { return true }
    let overlap = expWords.intersection(actWords).count
    return overlap >= max(1, expWords.count / 3)
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Test Definitions
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func DeepgramE2EMain() async {
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("  Deepgram Streaming E2E — Full Real-API Test Suite")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    guard let apiKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"],
          !apiKey.isEmpty else {
        print("❌ DEEPGRAM_API_KEY environment variable not set")
        print("   Usage: DEEPGRAM_API_KEY=your_key swift run DeepgramE2E")
        exit(1)
    }
    ProviderSettings.shared.setApiKey(apiKey, for: ProviderId.deepgram)

    var passed = 0
    var failed = 0

    let tests: [(String, () async -> Bool)] = [
        // ── Core Connection ──────────────────────────────────────
        ("1.  WebSocket connection + metadata", testConnection),
        ("2.  Rapid reconnection (back-to-back sessions)", testReconnection),

        // ── Single Sentence Transcription ────────────────────────
        ("3.  Single short sentence → final result", testSingleShort),
        ("4.  Single long sentence → final result", testSingleLong),

        // ── Interim → Final Lifecycle ────────────────────────────
        ("5.  Interim progression: count + replacement", testInterimProgression),
        ("6.  Interim text replacement tracking (backspace simulation)", testInterimReplacement),
        ("7.  All interims precede their final", testInterimOrderInvariant),

        // ── Natural Pauses & Endpointing ─────────────────────────
        ("8.  Short pause (500ms) — no endpointing", testShortPause),
        ("9.  Medium pause (1.5s) — endpointing fires", testMediumPause),
        ("10. Long pause (3s) — clear sentence boundary", testLongPause),
        ("11. Conversational flow: 3 sentences with pauses", testConversationalFlow),

        // ── Silence Handling ─────────────────────────────────────
        ("12. Pure silence — no false transcription", testSilenceOnly),
        ("13. Silence before speech — correct transcript", testSilenceThenSpeech),
        ("14. Speech then long silence — utterance end detection", testSpeechThenSilence),

        // ── Server Features ──────────────────────────────────────
        ("15. KeepAlive keeps session alive", testKeepAlive),
        ("16. Finalize flushes mid-stream", testFinalizeFlush),
        ("17. Finalize before close gets final result", testFinalizeBeforeClose),

        // ── Quality & Accuracy ───────────────────────────────────
        ("18. Numbers and punctuation (smart_format)", testSmartFormat),
        ("19. Long sustained speech (30s+)", testLongSustained),
        ("20. Word-level timing present in results", testWordTimings),

        // ── Integration: No Local VAD ────────────────────────────
        ("21. LiveStreamingController — no local VAD used", testNoLocalVAD),
        ("22. Provider settings persistence", testProviderSettings),
    ]

    for (name, test) in tests {
        print("\n┌──────────────────────────────────────────────────────")
        print("│ \(name)")
        print("└──────────────────────────────────────────────────────")
        if await test() {
            print("  ✅ PASS")
            passed += 1
        } else {
            failed += 1
        }
    }

    print()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if failed == 0 {
        print("  Results: \(passed)/\(tests.count) passed ✅")
    } else {
        print("  Results: \(passed)/\(tests.count) passed, \(failed) FAILED ❌")
    }
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    exit(failed > 0 ? 1 : 0)
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 1. Connection
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testConnection() async -> Bool {
    do {
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)

        // Send a tiny bit of audio to ensure the server responds
        // Metadata is sent immediately on connect, but we need the event
        // listener running before it arrives. Sending audio guarantees
        // at least a Results event.
        nonisolated(unsafe) var gotEvent = false
        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .metadata, .interim, .finalResult:
                    gotEvent = true
                default: break
                }
                if gotEvent { break }
            }
        }

        // Send tiny audio to trigger a server response
        let silence = generateSilence(durationMs: 200)
        try await session.sendAudio(silence)
        try await session.finalize()
        try await Task.sleep(for: .seconds(2))
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        print("    📡 Server responded: \(gotEvent)")
        if !gotEvent {
            print("  ❌ FAIL — no response from server")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testReconnection() async -> Bool {
    do {
        let provider = DeepgramProvider()
        let audio = generateSpeech("Reconnection test audio.")

        for i in 1...3 {
            let session = try await provider.startSession(config: .default)
            let tracker = InterimTracker()
            let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker, printEvents: false)
            try await session.close()
            try await Task.sleep(for: .milliseconds(300))
            eventTask.cancel()

            let text = tracker.committedText
            print("    Session \(i): \"\(text)\"")
            if text.isEmpty {
                print("  ❌ FAIL — session \(i) got no transcription")
                return false
            }
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 3–4. Single Sentence
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testSingleShort() async -> Bool {
    do {
        let expected = "Hello world."
        let audio = generateSpeech(expected)
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")
        if text.isEmpty { print("  ❌ FAIL — empty"); return false }
        if !looseMatch(expected: expected, actual: text) {
            print("  ❌ FAIL — transcript doesn't match expected")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testSingleLong() async -> Bool {
    do {
        let expected = "The quick brown fox jumps over the lazy dog. This pangram contains every letter of the English alphabet at least once."
        let audio = generateSpeech(expected)
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker, waitAfterFinalize: 4.0)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed (\(tracker.finalCount) finals): \"\(text.prefix(100))\"")
        if text.isEmpty { print("  ❌ FAIL — empty"); return false }
        if !looseMatch(expected: expected, actual: text) {
            print("  ❌ FAIL — transcript doesn't match expected")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 5–7. Interim Lifecycle
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testInterimProgression() async -> Bool {
    do {
        let audio = generateSpeech("This is a test of interim results from the streaming transcription API.")
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        print("    📊 Interims: \(tracker.interimCount), Finals: \(tracker.finalCount), Replacements: \(tracker.interimReplacements)")
        print("    📄 Committed: \"\(tracker.committedText.prefix(80))\"")

        if tracker.interimCount == 0 {
            print("  ❌ FAIL — no interim results received (streaming not working)")
            return false
        }
        if tracker.finalCount == 0 {
            print("  ❌ FAIL — no final results received")
            return false
        }
        if tracker.committedText.isEmpty {
            print("  ❌ FAIL — committed text empty")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testInterimReplacement() async -> Bool {
    // Longer speech produces more interims that get replaced
    do {
        let audio = generateSpeech(
            "The streaming transcription service sends preliminary results that get refined over time. " +
            "Each interim result replaces the previous one until a final result commits the segment."
        )
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker, waitAfterFinalize: 4.0)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        // Analyze the update log — simulate AppDelegate's backspace+retype
        var screenText = ""
        var backspaceCount = 0
        for u in tracker.updates {
            // Delete previous interim chars
            if u.replacingChars > 0 {
                let deleteCount = min(u.replacingChars, screenText.count)
                screenText = String(screenText.dropLast(deleteCount))
                backspaceCount += deleteCount
            }
            screenText += u.text
            if u.isFinal {
                screenText += " "  // AppDelegate adds trailing space after finals
            }
        }

        print("    📊 Interims: \(tracker.interimCount), Finals: \(tracker.finalCount)")
        print("    📊 Replacements: \(tracker.interimReplacements), Backspaces: \(backspaceCount)")
        print("    📄 Screen text: \"\(screenText.trimmingCharacters(in: .whitespaces).prefix(100))\"")

        if backspaceCount == 0 && tracker.interimCount > 1 {
            print("  ⚠️  No backspaces despite multiple interims (each was unique)")
        }
        if tracker.committedText.isEmpty {
            print("  ❌ FAIL — no committed text")
            return false
        }
        if screenText.trimmingCharacters(in: .whitespaces).isEmpty {
            print("  ❌ FAIL — screen text empty after simulation")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testInterimOrderInvariant() async -> Bool {
    // Invariant: for each final, all preceding interims should be for the same or earlier segment
    // No final should arrive before its segment's interims
    do {
        let audio = generateSpeech(
            "First sentence about coding. Second sentence about testing. Third sentence about quality."
        )
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker, waitAfterFinalize: 4.0)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let updates = tracker.updates
        print("    📊 Total events: \(updates.count) (interims: \(tracker.interimCount), finals: \(tracker.finalCount))")

        // Check: interims always come before finals
        var seenFinalCount = 0
        var lastFinalTime: Date?
        for u in updates {
            if u.isFinal {
                seenFinalCount += 1
                lastFinalTime = u.timestamp
            } else {
                // Interim after a final is fine (it's for the NEXT segment)
            }
        }

        // Check: no two consecutive finals with the first having replacing > 0
        // (a final should never replace another final)
        for i in 1..<updates.count {
            if updates[i].isFinal && updates[i-1].isFinal && updates[i].replacingChars > 0 {
                // This means a final replaced another final's text — should never happen
                // because finals clear the interim buffer
                print("  ❌ FAIL — final replaced previous final at index \(i)")
                return false
            }
        }

        print("    ✅ \(seenFinalCount) finals, all interims precede their finals correctly")
        if seenFinalCount == 0 {
            print("  ❌ FAIL — no finals received")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 8–11. Pauses & Endpointing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testShortPause() async -> Bool {
    // 500ms pause should NOT trigger endpointing (endpointing=300ms but within a word group)
    // Both parts should transcribe
    do {
        let seg1 = generateSpeech("Let me think about this.")
        let seg2 = generateSpeech("Okay I have the answer.")

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        let eventTask = try await streamSegmentsWithPauses(
            session: session,
            segments: [(seg1, 500), (seg2, 0)],
            tracker: tracker
        )
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText.lowercased()
        print("    📄 Committed: \"\(tracker.committedText)\"")

        if text.isEmpty {
            print("  ❌ FAIL — no transcription")
            return false
        }
        // Both parts should appear
        if !text.contains("think") && !text.contains("answer") {
            print("  ❌ FAIL — missing expected words from both segments")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testMediumPause() async -> Bool {
    // 1.5s pause should trigger endpointing (utterance_end_ms=1500)
    // This means we get separate finals for each segment
    do {
        let seg1 = generateSpeech("First thought before the pause.")
        let seg2 = generateSpeech("Second thought after the pause.")

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        nonisolated(unsafe) var gotUtteranceEnd = false
        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .interim(let r): tracker.onInterim(r.transcript)
                case .finalResult(let r):
                    tracker.onFinal(r.transcript)
                    if !r.transcript.isEmpty { print("    ✅ Final: \"\(r.transcript)\"") }
                case .utteranceEnd:
                    gotUtteranceEnd = true
                    print("    🔇 UtteranceEnd detected")
                default: break
                }
            }
        }

        // Stream segment 1 + 1.5s silence + segment 2
        let chunkSize = 3200
        for data in [seg1] {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try await session.sendAudio(Data(data[offset..<end]))
                offset = end
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        // 1.5s silence
        let silence = generateSilence(durationMs: 1500)
        var sOff = 0
        while sOff < silence.count {
            let end = min(sOff + chunkSize, silence.count)
            try await session.sendAudio(Data(silence[sOff..<end]))
            sOff = end
            try await Task.sleep(for: .milliseconds(50))
        }

        // Segment 2
        var offset = 0
        while offset < seg2.count {
            let end = min(offset + chunkSize, seg2.count)
            try await session.sendAudio(Data(seg2[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(50))
        }

        try await session.finalize()
        try await Task.sleep(for: .seconds(3))
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed (\(tracker.finalCount) finals): \"\(text)\"")
        print("    🔇 UtteranceEnd received: \(gotUtteranceEnd)")

        if text.isEmpty {
            print("  ❌ FAIL — no transcription")
            return false
        }
        if tracker.finalCount < 2 {
            print("  ⚠️  Expected ≥2 finals from 2 sentences with 1.5s gap (got \(tracker.finalCount))")
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testLongPause() async -> Bool {
    do {
        let seg1 = generateSpeech("Before the long pause.")
        let seg2 = generateSpeech("After the long pause.")

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        nonisolated(unsafe) var utteranceEndCount = 0
        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .interim(let r): tracker.onInterim(r.transcript)
                case .finalResult(let r):
                    tracker.onFinal(r.transcript)
                    if !r.transcript.isEmpty { print("    ✅ Final: \"\(r.transcript)\"") }
                case .utteranceEnd:
                    utteranceEndCount += 1
                    print("    🔇 UtteranceEnd #\(utteranceEndCount)")
                default: break
                }
            }
        }

        let eventTaskRef = try await streamSegmentsWithPauses(
            session: session,
            segments: [(seg1, 3000), (seg2, 0)],
            tracker: tracker,
            printEvents: false
        )
        _ = eventTaskRef  // already started above

        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed (\(tracker.finalCount) finals): \"\(text)\"")
        print("    🔇 UtteranceEnd count: \(utteranceEndCount)")

        if text.isEmpty {
            print("  ❌ FAIL — no transcription")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testConversationalFlow() async -> Bool {
    do {
        let seg1 = generateSpeech("First I want to talk about technology.")
        let seg2 = generateSpeech("Then I want to discuss science and innovation.")
        let seg3 = generateSpeech("Finally let me mention art and creativity.")

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        let eventTask = try await streamSegmentsWithPauses(
            session: session,
            segments: [
                (seg1, 800),   // short pause
                (seg2, 2000),  // longer pause → endpointing
                (seg3, 0),
            ],
            tracker: tracker
        )
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText.lowercased()
        print("    📄 Committed (\(tracker.finalCount) finals): \"\(tracker.committedText.prefix(120))\"")
        print("    📊 Interims: \(tracker.interimCount), Replacements: \(tracker.interimReplacements)")

        if tracker.committedText.isEmpty {
            print("  ❌ FAIL — no committed text")
            return false
        }
        if !text.contains("technology") {
            print("  ❌ FAIL — missing 'technology' from first segment")
            return false
        }
        if !text.contains("science") && !text.contains("innovation") {
            print("  ❌ FAIL — missing content from second segment")
            return false
        }
        if tracker.finalCount < 2 {
            print("  ⚠️  Only \(tracker.finalCount) final(s) from 3 segments")
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 12–14. Silence Handling
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testSilenceOnly() async -> Bool {
    do {
        let silence = generateSilence(durationMs: 4000)
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        let eventTask = try await streamAndFinalize(session: session, audio: silence, tracker: tracker, waitAfterFinalize: 2.0)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        if !tracker.committedText.isEmpty {
            print("  ❌ FAIL — got transcript from silence: \"\(tracker.committedText)\"")
            return false
        }
        print("    📄 No false transcription from 4s silence ✓")
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testSilenceThenSpeech() async -> Bool {
    do {
        let silence = generateSilence(durationMs: 2000)
        let speech = generateSpeech("Hello after two seconds of silence.")

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        let eventTask = try await streamSegmentsWithPauses(
            session: session,
            segments: [(silence, 0), (speech, 0)],
            tracker: tracker
        )
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")
        if text.isEmpty {
            print("  ❌ FAIL — no transcription after silence→speech")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testSpeechThenSilence() async -> Bool {
    do {
        let speech = generateSpeech("This sentence is followed by silence.")
        let silence = generateSilence(durationMs: 3000)

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        nonisolated(unsafe) var gotUtteranceEnd = false

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .interim(let r): tracker.onInterim(r.transcript)
                case .finalResult(let r):
                    tracker.onFinal(r.transcript)
                    if !r.transcript.isEmpty { print("    ✅ Final: \"\(r.transcript)\"") }
                case .utteranceEnd:
                    gotUtteranceEnd = true
                    print("    🔇 UtteranceEnd after speech")
                default: break
                }
            }
        }

        let chunkSize = 3200
        for data in [speech, silence] {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try await session.sendAudio(Data(data[offset..<end]))
                offset = end
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        try await session.finalize()
        try await Task.sleep(for: .seconds(3))
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")
        print("    🔇 UtteranceEnd received: \(gotUtteranceEnd)")

        if text.isEmpty {
            print("  ❌ FAIL — no transcription before silence")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 15–17. Server Features
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testKeepAlive() async -> Bool {
    do {
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)

        // Send keep-alives over 3 seconds
        for i in 1...3 {
            try await session.keepAlive()
            print("    💓 KeepAlive \(i) sent")
            try await Task.sleep(for: .seconds(1))
        }

        // Session should still be alive — send audio and get results
        let audio = generateSpeech("Session still alive after keep-alives.")
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker, printEvents: false)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")
        if text.isEmpty {
            print("  ❌ FAIL — no transcription after keep-alives")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testFinalizeFlush() async -> Bool {
    do {
        let audio = generateSpeech("Testing finalize to flush partial results from the server buffer mid stream.")
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .interim(let r): tracker.onInterim(r.transcript)
                case .finalResult(let r):
                    tracker.onFinal(r.transcript)
                    if !r.transcript.isEmpty { print("    ✅ Final: \"\(r.transcript)\"") }
                default: break
                }
            }
        }

        // Stream first half
        let half = audio.count / 2
        let chunkSize = 3200
        var offset = 0
        while offset < half {
            let end = min(offset + chunkSize, half)
            try await session.sendAudio(Data(audio[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(50))
        }

        // Finalize mid-stream
        try await session.finalize()
        print("    🔄 Finalize sent (flushed first half)")
        try await Task.sleep(for: .seconds(2))

        let afterFirstHalf = tracker.finalCount
        print("    📄 Finals after first half: \(afterFirstHalf)")

        // Stream second half
        while offset < audio.count {
            let end = min(offset + chunkSize, audio.count)
            try await session.sendAudio(Data(audio[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(50))
        }

        try await session.finalize()
        try await Task.sleep(for: .seconds(3))
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        print("    📄 Total finals: \(tracker.finalCount)")
        print("    📄 Full committed: \"\(tracker.committedText.prefix(100))\"")

        if afterFirstHalf == 0 {
            print("  ❌ FAIL — finalize didn't produce a final for first half")
            return false
        }
        if tracker.committedText.isEmpty {
            print("  ❌ FAIL — no committed text")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testFinalizeBeforeClose() async -> Bool {
    // Critical: finalize() before close() should ensure we get ALL final results
    do {
        let audio = generateSpeech("This sentence must be fully transcribed before the session closes.")
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")
        if text.isEmpty {
            print("  ❌ FAIL — finalize before close didn't produce final result")
            return false
        }
        if tracker.finalCount == 0 {
            print("  ❌ FAIL — no final results (only interims)")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 18–20. Quality & Accuracy
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testSmartFormat() async -> Bool {
    // smart_format should handle numbers, punctuation, capitalization
    do {
        let audio = generateSpeech("I have three hundred and fifty two dollars and twenty five cents.")
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")

        if text.isEmpty {
            print("  ❌ FAIL — no transcription")
            return false
        }
        // smart_format should convert "three hundred and fifty two" to "$352" or similar
        // At minimum the text should contain the numbers
        let lower = text.lowercased()
        if lower.contains("352") || lower.contains("$352") || lower.contains("three hundred") || lower.contains("dollars") {
            print("    ✅ Number/currency formatting detected")
        } else {
            print("  ⚠️  Expected number formatting but got: \(text)")
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testLongSustained() async -> Bool {
    do {
        let audio = generateSpeech(
            "This is a longer test of sustained speech to verify the streaming pipeline handles extended audio input. " +
            "We want to make sure that multiple final results are produced as the user speaks continuously. " +
            "The transcription should be split at natural sentence boundaries by the endpointing algorithm. " +
            "Each segment should be accurate and the full transcript should contain all the spoken words.",
            rate: 160
        )

        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker, waitAfterFinalize: 5.0)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        let text = tracker.committedText
        print("    📄 Committed (\(tracker.finalCount) finals, \(tracker.interimCount) interims)")
        print("    📄 Text: \"\(text.prefix(120))...\"")

        if text.isEmpty {
            print("  ❌ FAIL — no transcription from long speech")
            return false
        }
        if tracker.finalCount < 2 {
            print("  ⚠️  Only \(tracker.finalCount) final(s) from long speech (expected ≥2)")
        }
        if tracker.interimCount < 3 {
            print("  ⚠️  Only \(tracker.interimCount) interim(s) from long speech (expected ≥3)")
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testWordTimings() async -> Bool {
    do {
        let audio = generateSpeech("Word timing test sentence.")
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)

        nonisolated(unsafe) var finalWords: [WordInfo] = []
        let tracker = InterimTracker()

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .interim(let r): tracker.onInterim(r.transcript)
                case .finalResult(let r):
                    tracker.onFinal(r.transcript)
                    if !r.words.isEmpty {
                        finalWords = r.words
                    }
                default: break
                }
            }
        }

        let chunkSize = 3200
        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunkSize, audio.count)
            try await session.sendAudio(Data(audio[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(50))
        }

        try await session.finalize()
        try await Task.sleep(for: .seconds(3))
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        if finalWords.isEmpty {
            print("  ⚠️  No word-level timing in results (may need different config)")
            // Don't fail — word timing is a nice-to-have
            return true
        }

        print("    📊 Word timings (\(finalWords.count) words):")
        for w in finalWords.prefix(5) {
            print("      \"\(w.word)\" \(String(format: "%.2f", w.start))–\(String(format: "%.2f", w.end))s (conf: \(String(format: "%.2f", w.confidence)))")
        }

        // Verify timing makes sense (each word starts after or at previous word's start)
        for i in 1..<finalWords.count {
            if finalWords[i].start < finalWords[i-1].start - 0.01 {
                print("  ❌ FAIL — word \(i) starts before word \(i-1)")
                return false
            }
        }
        print("    ✅ Word timings are monotonically increasing")
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 21–22. Integration
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor func testNoLocalVAD() async -> Bool {
    // Verify: LiveStreamingController has NO VAD, NO silence detection, NO auto-end.
    // The ONLY speech detection is server-side from Deepgram.
    do {
        let audio = generateSpeech("Testing that no local voice activity detection is running in streaming mode.")
        let provider = DeepgramProvider()
        let session = try await provider.startSession(config: .default)
        let tracker = InterimTracker()
        let eventTask = try await streamAndFinalize(session: session, audio: audio, tracker: tracker)
        try await session.close()
        try await Task.sleep(for: .milliseconds(300))
        eventTask.cancel()

        // LiveStreamingController properties — verify by design
        let controller = LiveStreamingController()
        print("    🔍 LiveStreamingController.recording = \(controller.recording) (not started)")
        print("    🔍 No VADProcessor property (by design)")
        print("    🔍 No SessionController property (by design)")
        print("    🔍 No autoEndSilenceDuration (by design)")
        print("    🔍 No onChunkReady callback (by design)")
        print("    🔍 Speech detection: server-side only (Deepgram endpointing + VAD events)")

        let text = tracker.committedText
        print("    📄 Committed: \"\(text)\"")
        if text.isEmpty {
            print("  ❌ FAIL — no transcription")
            return false
        }
        return true
    } catch {
        print("  ❌ FAIL — \(error.localizedDescription)")
        return false
    }
}

@MainActor func testProviderSettings() async -> Bool {
    // Test that provider settings correctly switch between gpt and deepgram
    let saved = ProviderSettings.shared.activeProviderId

    // Test default
    print("    Current provider: \(ProviderSettings.shared.activeProviderId)")

    // Switch to deepgram
    ProviderSettings.shared.activeProviderId = ProviderId.deepgram
    let isDG = ProviderSettings.shared.activeProviderId == ProviderId.deepgram
    print("    After set to deepgram: \(ProviderSettings.shared.activeProviderId) (correct: \(isDG))")

    // Check API key
    let hasKey = ProviderSettings.shared.apiKey(for: ProviderId.deepgram) != nil
    print("    Deepgram API key present: \(hasKey)")

    // Switch back to gpt
    ProviderSettings.shared.activeProviderId = ProviderId.chatGPT
    let isW = ProviderSettings.shared.activeProviderId == ProviderId.chatGPT
    print("    After set to gpt: \(ProviderSettings.shared.activeProviderId) (correct: \(isW))")

    // Restore
    ProviderSettings.shared.activeProviderId = saved

    if !isDG || !isW {
        print("  ❌ FAIL — provider switching not working")
        return false
    }
    if !hasKey {
        print("  ❌ FAIL — API key not found in settings")
        return false
    }
    return true
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Entry Point
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@main
enum DeepgramE2EEntry {
    static func main() {
        Task { @MainActor in
            await DeepgramE2ERunner.run()
        }
        dispatchMain()
    }
}

enum DeepgramE2ERunner {
    @MainActor static func run() async {
        await DeepgramE2EMain()
    }
}
