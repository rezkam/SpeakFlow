import Foundation
import OSLog

public actor SessionController {
    private let logger = Logger(subsystem: "SpeakFlow", category: "Session")
    private let vadConfig: VADConfiguration
    private let autoEndConfig: AutoEndConfiguration
    private let maxChunkDuration: TimeInterval

    private var isUserSpeaking = false
    private var lastSpeechEndTime: Date?
    private var chunkStartTime: Date?
    private var sessionStartTime: Date?
    private var hasSpeechOccurredInSession = false

    private let dateProvider: () -> Date
    
    // Safety clamp is now 3.0s minimum
    public init(vadConfig: VADConfiguration = .default, autoEndConfig: AutoEndConfiguration = .default,
                maxChunkDuration: TimeInterval = 30.0, dateProvider: @escaping () -> Date = Date.init) {
        self.vadConfig = vadConfig
        self.maxChunkDuration = maxChunkDuration
        self.dateProvider = dateProvider
        
        // Safety clamp: Ensure auto-end silence duration is never dangerously short
        var safeAutoEndConfig = autoEndConfig
        if safeAutoEndConfig.enabled && safeAutoEndConfig.silenceDuration < 3.0 {
            safeAutoEndConfig.silenceDuration = 3.0
        }
        self.autoEndConfig = safeAutoEndConfig
    }

    public func startSession() {
        sessionStartTime = dateProvider()
        chunkStartTime = dateProvider()
        hasSpeechOccurredInSession = false
        isUserSpeaking = false
        lastSpeechEndTime = nil
        logger.info("📋 SESSION START: autoEnd=\(self.autoEndConfig.enabled, privacy: .public), silenceDuration=\(String(format: "%.1f", self.autoEndConfig.silenceDuration), privacy: .public)s (effective/clamped), minSession=\(String(format: "%.1f", self.autoEndConfig.minSessionDuration), privacy: .public)s, requireSpeechFirst=\(self.autoEndConfig.requireSpeechFirst, privacy: .public), noSpeechTimeout=\(String(format: "%.1f", self.autoEndConfig.noSpeechTimeout), privacy: .public)s, maxChunk=\(String(format: "%.1f", self.maxChunkDuration), privacy: .public)s")
    }

    public func onSpeechEvent(_ event: SpeechEvent) {
        switch event {
        case .started:
            isUserSpeaking = true
            hasSpeechOccurredInSession = true
            if chunkStartTime == nil { chunkStartTime = dateProvider() }
            logger.info("🎤 SPEECH START: sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s")
        case .ended:
            isUserSpeaking = false
            lastSpeechEndTime = dateProvider()
            logger.info("🔇 SPEECH END: sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s")
        }
    }

    public func shouldSendChunk() -> Bool {
        guard let start = chunkStartTime else { return false }
        let now = dateProvider()
        let duration = now.timeIntervalSince(start)

        // Don't send any chunks until the configured chunk duration has elapsed.
        // This respects the user's setting (e.g. 1 minute) and avoids expensive
        // API calls every few seconds on speech pauses.
        guard duration >= maxChunkDuration else { return false }

        // Don't interrupt active speech — wait for a natural pause
        guard !isUserSpeaking else { return false }

        // Case 1: Speech occurred, confirmed silence after it → clean breakpoint
        if let lastEnd = lastSpeechEndTime,
           now.timeIntervalSince(lastEnd) >= vadConfig.minSilenceAfterSpeech {
            return true
        }

        // Case 2: FALLBACK - VAD never detected speech end, but max duration reached
        if lastSpeechEndTime == nil {
            logger.debug("Fallback chunk send: VAD never detected speech end, duration=\(String(format: "%.1f", duration))s")
            return true
        }
        
        return false
    }

    public func chunkSent() { chunkStartTime = dateProvider() }

    public func shouldAutoEndSession() -> Bool {
        guard autoEndConfig.enabled else {
            logger.debug("autoEnd: BLOCKED (disabled)")
            return false
        }
        let now = dateProvider()

        // Idle timeout: if no speech detected at all after generous timeout, end session.
        if !hasSpeechOccurredInSession && autoEndConfig.noSpeechTimeout > 0,
           let start = sessionStartTime {
            let idleDuration = now.timeIntervalSince(start)
            if idleDuration >= autoEndConfig.noSpeechTimeout {
                logger.warning("🛑 AUTO-END IDLE: no speech detected after \(String(format: "%.1f", idleDuration), privacy: .public)s (timeout=\(String(format: "%.1f", self.autoEndConfig.noSpeechTimeout), privacy: .public)s)")
                return true
            }
        }

        if autoEndConfig.requireSpeechFirst && !hasSpeechOccurredInSession {
            logger.debug("autoEnd: BLOCKED (requireSpeechFirst, no speech yet, sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s)")
            return false
        }
        guard !isUserSpeaking else {
            logger.debug("autoEnd: BLOCKED (user currently speaking)")
            return false
        }
        if let start = sessionStartTime, now.timeIntervalSince(start) < autoEndConfig.minSessionDuration {
            logger.debug("autoEnd: BLOCKED (session too short: \(String(format: "%.1f", now.timeIntervalSince(start)), privacy: .public)s < min=\(String(format: "%.1f", self.autoEndConfig.minSessionDuration), privacy: .public)s)")
            return false
        }
        
        // Normal case: silence after detected speech
        if let lastEnd = lastSpeechEndTime {
            let silenceSoFar = now.timeIntervalSince(lastEnd)
            if silenceSoFar >= autoEndConfig.silenceDuration {
                logger.warning("🛑 AUTO-END NORMAL: silence=\(String(format: "%.1f", silenceSoFar), privacy: .public)s >= required=\(String(format: "%.1f", self.autoEndConfig.silenceDuration), privacy: .public)s")
                return true
            }
            logger.debug("autoEnd: WAITING (silence=\(String(format: "%.1f", silenceSoFar), privacy: .public)s / required=\(String(format: "%.1f", self.autoEndConfig.silenceDuration), privacy: .public)s)")
            return false
        }
        
        // FALLBACK: VAD never detected speech end, but session has been running long enough
        if let start = sessionStartTime {
            let sessionDuration = now.timeIntervalSince(start)
            let requiredDuration = autoEndConfig.silenceDuration + autoEndConfig.minSessionDuration
            if sessionDuration >= requiredDuration {
                logger.warning("🛑 AUTO-END FALLBACK: sessionDur=\(String(format: "%.1f", sessionDuration), privacy: .public)s >= required=\(String(format: "%.1f", requiredDuration), privacy: .public)s, lastSpeechEnd=nil, hasSpeech=\(self.hasSpeechOccurredInSession, privacy: .public), speaking=\(self.isUserSpeaking, privacy: .public)")
                return true
            }
        }

        logger.debug("autoEnd: WAITING (no lastSpeechEndTime, sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s)")
        return false
    }

    public var currentChunkDuration: TimeInterval {
        guard let start = chunkStartTime else { return 0 }
        return dateProvider().timeIntervalSince(start)
    }

    public var currentSessionDuration: TimeInterval {
        guard let start = sessionStartTime else { return 0 }
        return dateProvider().timeIntervalSince(start)
    }

    public var hasSpoken: Bool { hasSpeechOccurredInSession }

    public var currentSilenceDuration: TimeInterval? {
        guard !isUserSpeaking, let lastEnd = lastSpeechEndTime else { return nil }
        return dateProvider().timeIntervalSince(lastEnd)
    }

    /// One-line diagnostic summary for periodic heartbeat logging
    public var diagnosticSummary: String {
        let sessionDur = String(format: "%.1f", currentSessionDuration)
        let chunkDur = String(format: "%.1f", currentChunkDuration)
        let silDur = currentSilenceDuration.map { String(format: "%.1f", $0) } ?? "nil"
        let hasEnd = lastSpeechEndTime != nil ? "yes" : "no"
        return "session=\(sessionDur)s chunk=\(chunkDur)s speaking=\(isUserSpeaking) hasSpeech=\(hasSpeechOccurredInSession) silence=\(silDur)s lastEnd=\(hasEnd)"
    }
}

#if DEBUG
extension SessionController {
    /// Test helper: Set chunk start time to simulate elapsed duration
    public func _testSetChunkStartTime(_ date: Date?) {
        chunkStartTime = date
    }
    
    /// Test helper: Check if lastSpeechEndTime is nil (VAD never fired)
    public var _testLastSpeechEndTimeIsNil: Bool {
        lastSpeechEndTime == nil
    }
    
    /// Test helper: Get maxChunkDuration for verification
    public var _testMaxChunkDuration: TimeInterval {
        maxChunkDuration
    }
}
#endif
