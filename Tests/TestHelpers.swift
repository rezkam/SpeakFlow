import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - RecordingController Test Factory

/// Creates a RecordingController with spy dependencies for isolated testing.
/// Mutes system sounds and sets test mode so permission checks are skipped.
@MainActor
func makeTestRecordingController(
    providerSettings: SpyProviderSettings = SpyProviderSettings(),
    providerRegistry: SpyProviderRegistry = SpyProviderRegistry(),
    settings: SpySettings = SpySettings()
) -> (RecordingController, SpyKeyInterceptor, SpyTextInserter, SpyBannerPresenter) {
    SoundEffect.isMuted = true
    let ki = SpyKeyInterceptor()
    let ti = SpyTextInserter()
    let bp = SpyBannerPresenter()
    let c = RecordingController(
        keyInterceptor: ki, textInserter: ti, appState: bp,
        providerSettings: providerSettings, providerRegistry: providerRegistry,
        settings: settings
    )
    c.testMode = .live
    return (c, ki, ti, bp)
}

// MARK: - Shared Test Helpers

/// Controllable clock for deterministic time-based tests.
/// Used by SessionController tests to advance time without real waits.
final class MockDateProvider: @unchecked Sendable {
    var now = Date()
    func date() -> Date { now }
}

// MARK: - HTTPDataProvider / Testability Tests (Issue #22)

/// A mock HTTP data provider that returns canned responses.
final class MockHTTPProvider: HTTPDataProvider, @unchecked Sendable {
    let responseData: Data
    let statusCode: Int
    private let lock = NSLock()
    private var _requestCount = 0

    var requestCount: Int { lock.withLock { _requestCount } }

    init(responseData: Data = Data(), statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _requestCount += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }
}

// MARK: - OAuth Callback Server Tests

func randomOAuthTestPort() -> UInt16 {
    UInt16.random(in: 20_000...59_999)
}

func hitOAuthCallback(port: UInt16, query: String) async throws -> Int {
    let url = URL(string: "http://127.0.0.1:\(port)/auth/callback?\(query)")!
    let (_, response) = try await URLSession.shared.data(from: url)
    return (response as? HTTPURLResponse)?.statusCode ?? -1
}

/// Thread-safe box for collecting chunks across actor boundaries.
final class ChunkBox: @unchecked Sendable {
    private var chunks: [AudioChunk] = []
    private let lock = NSLock()

    func append(_ chunk: AudioChunk) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    var all: [AudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

/// Helper to collect onTextUpdate calls from LiveStreamingController.
@MainActor
final class TextUpdateCollector {
    struct Entry {
        let textToType: String
        let replacingChars: Int
        let isFinal: Bool
        let fullText: String
    }
    var entries: [Entry] = []
    var autoEndCount = 0
    var utteranceEndCount = 0
    var speechStartCount = 0

    /// Wire all callbacks. If `simulateActive` is true, sets `isActive = true`
    /// so the silence timer can fire (normally set by `start()`).
    func wire(_ c: LiveStreamingController, simulateActive: Bool = false) {
        if simulateActive { c.isActive = true }
        c.onTextUpdate = { [weak self] textToType, replacingChars, isFinal, fullText in
            self?.entries.append(Entry(textToType: textToType, replacingChars: replacingChars, isFinal: isFinal, fullText: fullText))
        }
        c.onAutoEnd = { [weak self] in self?.autoEndCount += 1 }
        c.onUtteranceEnd = { [weak self] in self?.utteranceEndCount += 1 }
        c.onSpeechStarted = { [weak self] in self?.speechStartCount += 1 }
    }

    /// Simulate what the screen would show: apply all entries' keystrokes.
    var screenText: String {
        var text = ""
        for e in entries {
            if e.replacingChars > 0 {
                let removeCount = min(e.replacingChars, text.count)
                text = String(text.dropLast(removeCount))
            }
            text += e.textToType
            if e.isFinal && !e.fullText.isEmpty {
                text += " "
            }
        }
        return text
    }

    var finals: [Entry] { entries.filter(\.isFinal) }
    var interims: [Entry] { entries.filter { !$0.isFinal } }
}

// MARK: - Polling Assertion

/// Polls a condition until it becomes true, or times out.
/// Use this instead of fixed `Task.sleep` for timer-based assertions
/// where main-actor contention can delay Task continuations.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(50),
    condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: interval)
    }
}
