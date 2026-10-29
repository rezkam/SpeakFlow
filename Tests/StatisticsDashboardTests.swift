import Foundation
import AppKit
import SwiftUI
import CryptoKit
import Observation
import Testing
import os
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Statistics dashboard observation and history")
struct StatisticsDashboardTests {
    @Test @MainActor
    func failedStartsDoNotCountAsRecordings() async {
        let history = StatisticsSessionHistory { _ in
            ["START_FAILED", "HOTKEY", "ESCAPE"].map {
                SessionMetrics(sessionId: UUID(), providerId: "test-provider", mode: .batch, endReason: $0)
            }
        }
        await history.refresh { .distantPast }
        #expect(history.sessions.count == 2)
        #expect(!history.sessions.contains { $0.endReason == "START_FAILED" })
    }

    @Test(arguments: ["words", "provider", "reset"]) @MainActor
    func statisticsMutationsInvalidateObservedDashboardValues(field: String) {
        let stats = Statistics.shared
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            switch field {
            case "words": _ = stats.totalWords
            case "provider": _ = stats.providerUsage
            default: _ = stats.lastResetDate
            }
        } onChange: { invalidated.withLock { $0 = true } }
        switch field {
        case "words": stats.recordTranscription(text: "synthetic words", audioDurationSeconds: 1)
        case "provider": stats.recordRecording(providerId: "test-provider", language: "en")
        default: stats.reset()
        }
        #expect(invalidated.withLock { $0 }, "SwiftUI must receive invalidation when dashboard values change")
    }

    @Test @MainActor
    func olderFetchCannotOverwriteNewerHistory() async throws {
        let gate = AsyncStream<Void>.makeStream()
        var calls = 0
        let history = StatisticsSessionHistory { _ in
            calls += 1
            let call = calls
            if call == 1 { for await _ in gate.stream {} }
            return [SessionMetrics(sessionId: UUID(), providerId: "provider-\(call)", mode: .batch)]
        }
        defer { gate.continuation.finish() }
        let old = Task { await history.refresh { .distantPast } }
        try await waitUntil { calls == 1 }
        await history.refresh { .distantPast }
        #expect(history.sessions.first?.providerId == "provider-2")
        gate.continuation.finish()
        await old.value
        #expect(history.sessions.first?.providerId == "provider-2")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func visibleDashboardRedrawsWithoutReplacingItsRootView() async throws {
        let stats = Statistics.shared
        stats.reset()
        var fetches = 0
        let history = StatisticsSessionHistory { _ in fetches += 1; return [] }
        let host = NSHostingView(rootView: StatisticsSettingsView(history: history).environment(\.statistics, stats))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Statistics test"
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await waitUntil { fetches == 1 }
        try await Task.sleep(for: .milliseconds(300))
        func imageDigest() throws -> String {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            return SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        }
        let before = try imageDigest()
        stats.recordTranscription(text: String(repeating: "sample ", count: 1234), audioDurationSeconds: 12)
        try await Task.sleep(for: .milliseconds(300))
        let after = try imageDigest()
        #expect(before != after, "The visible dashboard must redraw after a statistics mutation")
        stats.reset()
        try await waitUntil { fetches == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try imageDigest() != after, "Reset must redraw counts and refresh the fallback query")
    }

    @Test(arguments: [false, true]) @MainActor
    func heldFetchCannotRepopulateHistoryAfterReset(explicitClear: Bool) async throws {
        let gate = AsyncStream<Void>.makeStream()
        var started = false
        var resetDate = Date(timeIntervalSince1970: 1)
        let history = StatisticsSessionHistory { _ in
            started = true
            for await _ in gate.stream {}
            return [SessionMetrics(sessionId: UUID(), providerId: "test-provider", mode: .batch)]
        }
        defer { gate.continuation.finish() }
        let refresh = Task { await history.refresh { resetDate } }
        try await waitUntil { started }
        resetDate = Date(timeIntervalSince1970: 2)
        if explicitClear { history.reset() }
        gate.continuation.finish()
        await refresh.value
        #expect(history.sessions.isEmpty, "A response fetched before reset must not restore historical counts")
    }
}
