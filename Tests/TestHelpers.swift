import Darwin
import Foundation
import os
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
    settings: SpySettings = SpySettings(),
    transcription: SpyTranscription = SpyTranscription()
) -> (RecordingController, SpyKeyInterceptor, SpyTextInserter, SpyBannerPresenter) {
    SoundEffect.isMuted = true
    let ki = SpyKeyInterceptor()
    let ti = SpyTextInserter()
    let bp = SpyBannerPresenter()
    let c = RecordingController(
        keyInterceptor: ki, textInserter: ti, appState: bp,
        providerSettings: providerSettings, providerRegistry: providerRegistry,
        settings: settings, transcription: transcription
    )
    c.testMode = .live
    // Mirror AppDelegate: wire transcription callbacks so onAllComplete
    // and onTextReady behave correctly in tests.
    c.setupTranscriptionCallbacks()
    return (c, ki, ti, bp)
}

// MARK: - Shared Test Helpers

/// Controllable clock for deterministic time-based tests.
/// Used by SessionController tests to advance time without real waits.
final class MockDateProvider: @unchecked Sendable {
    var now = Date()
    func date() -> Date { now }
}

// MARK: - HTTPDataProvider / Testability Tests

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

/// Assigns unique ports to each OAuth test to prevent bind collisions when tests
/// run concurrently. An atomic counter offsets from a random base so different
/// test processes also avoid colliding.
private let oauthPortCounter = OSAllocatedUnfairLock(initialState: UInt16.random(in: 20_000...50_000))
func randomOAuthTestPort() -> UInt16 {
    oauthPortCounter.withLock { counter in
        let port = counter
        counter &+= 1
        return port
    }
}

func hitOAuthCallback(port: UInt16, query: String) async throws -> Int {
    let url = URL(string: "http://127.0.0.1:\(port)/auth/callback?\(query)")!
    // Retry with back-off — CI runners may need extra time for the server to bind.
    for attempt in 0..<5 {
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch let error as URLError where error.code == .cannotConnectToHost && attempt < 4 {
            try? await Task.sleep(for: .milliseconds(100 * (1 << attempt)))
        }
    }
    // Final attempt — let it throw on failure.
    let (_, response) = try await URLSession.shared.data(from: url)
    return (response as? HTTPURLResponse)?.statusCode ?? -1
}

/// Sends a raw HTTP callback in two writes to simulate packet fragmentation.
/// Used to validate that OAuthCallbackServer handles partial request reads.
func hitOAuthCallbackFragmented(port: UInt16, query: String, splitAt: Int) async throws -> Int {
    try await Task.detached(priority: .userInitiated) {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw URLError(.cannotCreateFile) }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        // Retry connect briefly while server accept loop comes up.
        var connected = false
        for _ in 0..<20 {
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                connected = true
                break
            }
            usleep(50_000)
        }
        guard connected else { throw URLError(.cannotConnectToHost) }

        let request = "GET /auth/callback?\(query) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        let bytes = Array(request.utf8)
        let split = max(1, min(splitAt, bytes.count - 1))

        _ = bytes[..<split].withUnsafeBytes { ptr in
            Darwin.write(sock, ptr.baseAddress, split)
        }
        usleep(20_000)
        _ = bytes[split...].withUnsafeBytes { ptr in
            Darwin.write(sock, ptr.baseAddress, bytes.count - split)
        }

        var response = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(sock, &response, response.count)
        guard n > 0,
              let text = String(bytes: response.prefix(n), encoding: .utf8),
              let firstLine = text.split(separator: "\r\n").first,
              let statusToken = firstLine.split(separator: " ").dropFirst().first,
              let status = Int(statusToken) else {
            return -1
        }
        return status
    }.value
}

/// Opens a localhost OAuth callback socket and sends a partial HTTP request without
/// terminating headers. Caller owns the returned socket and should close it.
func openOAuthPartialConnection(port: UInt16, partialRequest: String) throws -> Int32 {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw URLError(.cannotCreateFile) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    var connected = false
    for _ in 0..<20 {
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            connected = true
            break
        }
        usleep(50_000)
    }

    guard connected else {
        Darwin.close(socket)
        throw URLError(.cannotConnectToHost)
    }

    let bytes = Array(partialRequest.utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(socket, ptr.baseAddress, bytes.count)
    }
    return socket
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
/// Use this instead of direct `Task.sleep` for timer-based assertions
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

/// Async variant of `waitUntil` for conditions that require `await`.
func waitUntilAsync(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(50),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
}
