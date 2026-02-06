import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Config Constants Tests

struct ConfigTests {
    
    @Test("maxAudioSizeBytes is 25MB")
    func testMaxAudioSizeConfig() {
        #expect(Config.maxAudioSizeBytes == 25_000_000, "Max audio size should be 25MB")
    }
    
    @Test("maxFullRecordingDuration is 1 hour")
    func testMaxRecordingDuration() {
        #expect(Config.maxFullRecordingDuration == 3600.0, "Max recording should be 1 hour")
    }
    
    @Test("minRecordingDurationMs is 250ms")
    func testMinRecordingDuration() {
        #expect(Config.minRecordingDurationMs == 250, "Min recording should be 250ms")
    }
    
    @Test("Rate limiting settings are correct")
    func testRateLimitingConfig() {
        #expect(Config.minTimeBetweenRequests == 10.0, "Should have 10s between requests")
        #expect(Config.maxRetries == 3, "Should have max 3 retries")
        #expect(Config.retryBaseDelay == 1.5, "Base retry delay should be 1.5s")
    }
    
    @Test("Timeout allows retries within 30 seconds")
    func testTimeoutForFastRetries() {
        // Worst case: timeout + delay + timeout + delay*2 + timeout
        // = 8 + 1.5 + 8 + 3 + 8 = 28.5 seconds
        let worstCase = Config.timeout + Config.retryBaseDelay + 
                        Config.timeout + (Config.retryBaseDelay * 2) + 
                        Config.timeout
        #expect(worstCase <= 30.0, "Worst case retry should complete within 30 seconds")
    }
    
    @Test("maxQueuedTextInsertions has reasonable bounds")
    func testMaxQueuedTextInsertions() {
        #expect(Config.maxQueuedTextInsertions > 0, "Must have positive limit")
        #expect(Config.maxQueuedTextInsertions <= 50, "Limit should be reasonable (not too high)")
        #expect(Config.maxQueuedTextInsertions >= 5, "Limit should allow some buffering")
    }
}

// MARK: - ChunkDuration Tests

struct ChunkDurationTests {
    
    @Test("fullRecording is 1 hour")
    func testFullRecordingDuration() {
        #expect(ChunkDuration.fullRecording.rawValue == 3600.0, "Full recording should be 1 hour")
        #expect(ChunkDuration.fullRecording.isFullRecording == true, "Should be identified as full recording")
    }
    
    @Test("minDuration equals selected duration for chunks")
    func testChunkMinDuration() {
        #expect(ChunkDuration.minute1.minDuration == 60.0, "1 min chunk should have 60s min")
        #expect(ChunkDuration.seconds30.minDuration == 30.0, "30s chunk should have 30s min")
        #expect(ChunkDuration.minute5.minDuration == 300.0, "5 min chunk should have 300s min")
        #expect(ChunkDuration.fullRecording.minDuration == 0.25, "Full recording should have 250ms min")
    }
    
    @Test("All chunk durations have display names")
    func testChunkDurationDisplayNames() {
        for duration in ChunkDuration.allCases {
            #expect(!duration.displayName.isEmpty, "\(duration) should have a display name")
        }
    }
}

// MARK: - AccessibilityPermissionManager Tests

struct AccessibilityPermissionManagerTests {
    
    @Test("maxPollAttempts has finite limit")
    func testPermissionPollingLimit() {
        #expect(AccessibilityPermissionManager.maxPollAttempts == 60, "Max poll attempts should be 60")
        #expect(AccessibilityPermissionManager.maxPollAttempts > 0, "Must have positive limit")
        #expect(AccessibilityPermissionManager.maxPollAttempts < 1000, "Limit should be reasonable")
    }
}

// MARK: - Statistics Tests

@MainActor
struct StatisticsTests {
    
    @Test("Statistics tracks API calls")
    func testApiCallTracking() async {
        Statistics.shared.recordApiCall()
        Statistics.shared.recordApiCall()
        
        let summary = Statistics.shared.summary
        #expect(summary.contains("API"), "Summary should mention API calls")
    }
    
    @Test("Statistics tracks transcription data")
    func testTranscriptionTracking() async {
        Statistics.shared.recordTranscription(text: "Hello world test", audioDurationSeconds: 5.0)
        
        let summary = Statistics.shared.summary
        #expect(summary.contains("word") || summary.contains("Words"), "Should track words")
    }
}
