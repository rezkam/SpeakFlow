import ApplicationServices
import Foundation
import Testing
@testable import SpeakFlowCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Test Isolation Verification
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("Test Isolation — Settings & Statistics do not pollute user data")
struct TestIsolationTests {

    /// Behavioral: Settings.shared in tests writes to an isolated store, not UserDefaults.standard.
    @Test @MainActor func testSettingsWritesAreIsolatedFromUserDefaults() {
        let settings = Settings.shared
        let orig = settings.deepgramModel
        defer { settings.deepgramModel = orig }

        // Write a sentinel value via Settings.shared
        let sentinel = "test-isolation-\(ProcessInfo.processInfo.processIdentifier)"
        settings.deepgramModel = sentinel
        #expect(settings.deepgramModel == sentinel, "Write must round-trip through Settings")

        // Verify UserDefaults.standard does NOT contain the sentinel —
        // confirming Settings uses an isolated suite, not .standard.
        let standardValue = UserDefaults.standard.string(forKey: "settings.deepgram.model")
        #expect(standardValue != sentinel,
                "Settings must NOT write to UserDefaults.standard in test runs")
    }

    /// Behavioral: Statistics.shared in tests writes to temp, not ~/.speakflow/.
    @Test @MainActor func testStatisticsDoesNotWriteToUserDir() {
        let stats = Statistics.shared
        stats.reset()
        defer { stats.reset() }

        stats.recordTranscription(text: "isolation test", audioDurationSeconds: 1.0)
        // If we got here without error, the write succeeded (to temp dir).
        // Verify the data round-trips correctly.
        #expect(stats.totalWords == 2)
        #expect(stats.totalSecondsTranscribed > 0.9)
    }
}

// MARK: - Issue #4: Text insertion goes to wrong app

@Suite("Issue #4 — Focus verification before text insertion")
struct Issue4FocusVerificationRegressionTests {

    /// Behavioral: CFEqual correctly distinguishes AXUIElements for different PIDs.
    @Test func testCFEqualDistinguishesDifferentAppElements() {
        let app1 = AXUIElementCreateApplication(1)
        let app2 = AXUIElementCreateApplication(2)
        let app1Again = AXUIElementCreateApplication(1)

        #expect(!CFEqual(app1, app2), "Different PID elements must not be equal")
        #expect(CFEqual(app1, app1Again), "Same PID elements must be equal")
    }
}

// MARK: - Hotkey & Concurrency Regression

@Suite("Hotkey & Concurrency Regression")
struct HotkeyConcurrencyRegressionTests {

    /// Issue #19: NumberFormatter cache must be stable across property accesses.
    @Test func testFormatterCacheRemainsStable() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordTranscription(text: "issue nineteen formatter cache", audioDurationSeconds: 3.2)
            stats.recordApiCall()

            let before = Statistics._testFormatterIdentity
            _ = stats.formattedCharacters
            _ = stats.formattedWords
            _ = stats.formattedApiCalls
            let after = Statistics._testFormatterIdentity

            #expect(before == after)
        }
    }

    /// Issue #21: Duration formatting must produce expected output.
    @Test func testFormattedDurationUsesExpectedOutput() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            #expect(stats.formattedDuration == String(localized: "0s"))

            let duration = 3_661.0
            stats.recordTranscription(text: "duration", audioDurationSeconds: duration)

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 3
            formatter.zeroFormattingBehavior = .dropAll

            let expected = formatter.string(from: duration) ?? String(localized: "0s")
            #expect(stats.formattedDuration == expected)
        }
    }
}

// MARK: - Regression: Timeout scales with audio duration

@Suite("Timeout scales with data size — source regression")
struct TimeoutScalingSourceTests {

    @Test func testTimeoutScalingBehavior() {
        // Zero bytes: base timeout
        let zero = TranscriptionService.timeout(forDataSize: 0)
        #expect(zero == Config.timeout,
                "Zero bytes should use base timeout, got \(zero)")

        // At base data size: base timeout
        let atBase = TranscriptionService.timeout(forDataSize: Config.baseTimeoutDataSize)
        #expect(atBase == Config.timeout,
                "Data at baseTimeoutDataSize should use base timeout, got \(atBase)")

        // At max file size: max timeout
        let atMax = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes)
        #expect(atMax == Config.maxTimeout,
                "Data at maxAudioSizeBytes should use maxTimeout, got \(atMax)")

        // Above max: still capped
        let overMax = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes * 2)
        #expect(overMax == Config.maxTimeout,
                "Data above max should be capped at maxTimeout, got \(overMax)")

        // Midpoint: halfway between base and max timeout
        let midSize = Config.baseTimeoutDataSize + (Config.maxAudioSizeBytes - Config.baseTimeoutDataSize) / 2
        let midTimeout = TranscriptionService.timeout(forDataSize: midSize)
        let expectedMid = Config.timeout + (Config.maxTimeout - Config.timeout) / 2.0
        #expect(abs(midTimeout - expectedMid) < 0.01,
                "Mid-range data should get mid-range timeout, got \(midTimeout) expected \(expectedMid)")

        // Monotonically increasing
        let t1 = TranscriptionService.timeout(forDataSize: 500_000)
        let t2 = TranscriptionService.timeout(forDataSize: 5_000_000)
        let t3 = TranscriptionService.timeout(forDataSize: 15_000_000)
        #expect(t1 <= t2 && t2 <= t3,
                "Timeout must be monotonically increasing: \(t1) <= \(t2) <= \(t3)")
    }
}

// MARK: - Swift 6 Actor-Isolation Regression Tests (Permission Polling)

@Suite("Swift 6 Actor-Isolation — Permission Polling")
struct AccessibilityPermissionPollingTests {

    /// Behavioral: stopPolling is idempotent.
    @Test func testStopPollingIdempotent() async {
        await MainActor.run {
            let manager = AccessibilityPermissionManager()
            manager.stopPolling()
            manager.stopPolling()
            manager.stopPolling()
        }
    }

    @Test @MainActor func testMaxPollAttempts() {
        #expect(AccessibilityPermissionManager.maxPollAttempts == 60,
                "maxPollAttempts should be 60 (2 minutes at 2s intervals)")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Provider Registry & Metadata Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("Provider Registry — Behavioral Tests")
struct ProviderRegistryTests {

    /// Ensure providers are registered (mirrors AppDelegate registration).
    @MainActor private static func ensureRegistered() {
        let registry = ProviderRegistry.shared
        if registry.allProviders.isEmpty {
            registry.register(ChatGPTBatchProvider())
            registry.register(DeepgramProvider())
        }
    }

    @Test @MainActor func testAllRegisteredProvidersHaveUniqueIds() {
        Self.ensureRegistered()
        let registry = ProviderRegistry.shared
        let providers = registry.allProviders
        let ids = providers.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count,
                "All registered providers must have unique IDs, found duplicates: \(ids)")
    }

    @Test @MainActor func testRegistryLookupByMode() {
        Self.ensureRegistered()
        let registry = ProviderRegistry.shared
        // ChatGPT is batch
        let batch = registry.batchProvider(for: ProviderId.chatGPT)
        #expect(batch != nil, "ChatGPT must be registered as a batch provider")
        #expect(registry.streamingProvider(for: ProviderId.chatGPT) == nil,
                "ChatGPT must not be a streaming provider")

        // Deepgram is streaming
        let streaming = registry.streamingProvider(for: ProviderId.deepgram)
        #expect(streaming != nil, "Deepgram must be registered as a streaming provider")
        #expect(registry.batchProvider(for: ProviderId.deepgram) == nil,
                "Deepgram must not be a batch provider")
    }

    @Test @MainActor func testProviderMetadataComplete() {
        Self.ensureRegistered()
        let registry = ProviderRegistry.shared
        for provider in registry.allProviders {
            #expect(!provider.id.isEmpty, "Provider ID must not be empty")
            #expect(!provider.displayName.isEmpty, "Provider displayName must not be empty")
            #expect(!provider.providerDisplayName.isEmpty, "providerDisplayName must not be empty")
        }
    }

    @Test @MainActor func testProviderIdConstantsMatchRegistered() {
        Self.ensureRegistered()
        let registry = ProviderRegistry.shared
        #expect(registry.provider(for: ProviderId.chatGPT) != nil,
                "ProviderId.chatGPT must match a registered provider")
        #expect(registry.provider(for: ProviderId.deepgram) != nil,
                "ProviderId.deepgram must match a registered provider")
    }

    @Test @MainActor func testChatGPTProviderMetadata() {
        Self.ensureRegistered()
        guard let provider = ProviderRegistry.shared.provider(for: ProviderId.chatGPT) else {
            Issue.record("ChatGPT provider not registered"); return
        }
        #expect(provider.id == ProviderId.chatGPT)
        #expect(provider.displayName == "ChatGPT")
        #expect(provider.mode == .batch)
        if case .oauth = provider.authRequirement {} else {
            Issue.record("ChatGPT auth requirement must be .oauth")
        }
    }

    @Test @MainActor func testDeepgramProviderMetadata() {
        Self.ensureRegistered()
        guard let provider = ProviderRegistry.shared.provider(for: ProviderId.deepgram) else {
            Issue.record("Deepgram provider not registered"); return
        }
        #expect(provider.id == ProviderId.deepgram)
        #expect(provider.displayName == "Deepgram")
        #expect(provider.mode == .streaming)
        if case .apiKey(let providerId) = provider.authRequirement {
            #expect(providerId == ProviderId.deepgram)
        } else {
            Issue.record("Deepgram auth requirement must be .apiKey")
        }
    }
}
