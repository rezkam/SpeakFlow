import Foundation
import OSLog

// MARK: - SessionController
//
// ## Role
//
// SessionController is the timing brain for a recording session. It answers two questions:
//
//   1. "Should I send a chunk to the transcription API now?"  → `shouldSendChunk()`
//   2. "Should I end this recording session?"                 → `shouldAutoEndSession()`
//
// It receives speech events from ``VADProcessor`` (via ``StreamingRecorder``) and uses
// the timing information to make these decisions.
//
// ## Safety timeout for stuck `isUserSpeaking`
//
// If FluidAudio fires `speechStart` but never fires `speechEnd` (continuous background
// noise, model error, VAD drift), `isUserSpeaking` stays `true` forever. Both
// `shouldAutoEndSession()` and `shouldSendChunk()` guard on `!isUserSpeaking` and return
// `false` permanently. The session hangs until the user manually stops recording.
//
// We track `speakingStartTime` when `speechStart` fires. Every time
// `shouldAutoEndSession()` is called (every 0.5s by StreamingRecorder's check timer), we
// check: has the user been continuously "speaking" for longer than
// `autoEndConfig.maxContinuousSpeechDuration` (default 3 minutes)? If so, we force-
// synthesise a speech-end event. No real dictation has truly unbroken speech for 3 min.
//
// ## Thinking pause detection
//
// Auto-end is purely time-based. A user who says "I want to order a..." and pauses to
// read the menu will trigger auto-end at the configured silence threshold, even though
// the transcript is clearly incomplete.
//
// `SessionController` accepts a `lastTranscript` property that callers update as new
// text arrives. In `shouldAutoEndSession()`, if the thinking pause feature is enabled
// AND the transcript looks incomplete, the effective silence threshold is extended by
// `thinkingPauseExtensionSeconds`.
//
// ## Thread safety
//
// `SessionController` is an `actor` — all mutations are isolated. The date provider
// injectable (`dateProvider`) enables deterministic testing without `Task.sleep`.

public actor SessionController {
    private let logger = Logger(subsystem: "SpeakFlow", category: "Session")
    private let vadConfig: VADConfiguration
    private let autoEndConfig: AutoEndConfiguration
    private let maxChunkDuration: TimeInterval
    private let dateProvider: () -> Date

    // MARK: - Core state

    private var isUserSpeaking = false
    private var lastSpeechEndTime: Date?
    private var chunkStartTime: Date?
    private var sessionStartTime: Date?
    private var hasSpeechOccurredInSession = false

    // MARK: - Safety timeout state
    //
    // Tracks when the current continuous speaking period began.
    // Used to detect stuck `isUserSpeaking=true` state.

    /// When the current continuous speaking period started. Nil when not speaking.
    private var speakingStartTime: Date?

    // MARK: - Thinking pause state
    //
    // Updated externally by StreamingRecorder when new transcript text arrives.
    // Read in shouldAutoEndSession() to check for incomplete linguistic patterns.

    /// The most recent transcript text for this session. Updated by StreamingRecorder
    /// as new partial or final transcription results arrive. Used by
    /// `ThinkingPauseDetector` to determine if the user is mid-thought.
    public var lastTranscript: String = ""

    // MARK: - Turn completion classifier state

    /// Latest completion probability for the current post-speech silence window.
    private var lastTurnCompletionProbability: Float?
    /// Tracks which speech-end boundary has already been evaluated.
    private var lastTurnCompletionEvaluatedSpeechEnd: Date?

    /// Update the transcript text. Called by StreamingRecorder when new transcription
    /// results arrive (both interim and final). Actor-isolated, safe to call from any task.
    public func set(lastTranscript text: String) {
        lastTranscript = text
    }

    // MARK: - Init

    public init(
        vadConfig: VADConfiguration = .default,
        autoEndConfig: AutoEndConfiguration = .default,
        maxChunkDuration: TimeInterval = 30.0,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.vadConfig = vadConfig
        self.maxChunkDuration = maxChunkDuration
        self.dateProvider = dateProvider

        // Safety clamp: ensure auto-end silence duration is never below the minimum
        // that FluidAudio's VAD can physically produce. FluidAudio only fires `speechEnd`
        // after `minSilenceAfterSpeech` (currently 3.0s) of confirmed silence. Setting
        // `silenceDuration` below 3.0s would create unreachable thresholds.
        var safeAutoEndConfig = autoEndConfig
        if safeAutoEndConfig.enabled && safeAutoEndConfig.silenceDuration < 3.0 {
            safeAutoEndConfig.silenceDuration = 3.0
        }
        self.autoEndConfig = safeAutoEndConfig
    }

    // MARK: - Session lifecycle

    public func startSession() {
        sessionStartTime = dateProvider()
        chunkStartTime = dateProvider()
        hasSpeechOccurredInSession = false
        isUserSpeaking = false
        lastSpeechEndTime = nil
        speakingStartTime = nil
        lastTranscript = ""
        lastTurnCompletionProbability = nil
        lastTurnCompletionEvaluatedSpeechEnd = nil

        let silence = String(format: "%.1f", autoEndConfig.silenceDuration)
        let minSess = String(format: "%.1f", autoEndConfig.minSessionDuration)
        let noSpeech = String(format: "%.1f", autoEndConfig.noSpeechTimeout)
        let maxChunk = String(format: "%.1f", maxChunkDuration)
        let maxSpeak = String(format: "%.1f", autoEndConfig.maxContinuousSpeechDuration)
        let thinking = autoEndConfig.thinkingPauseEnabled
        let thinkExt = String(format: "%.1f", autoEndConfig.thinkingPauseExtensionSeconds)
        let turnClassifier = autoEndConfig.turnClassifierEnabled
        let turnClassifierSil = String(format: "%.1f", autoEndConfig.turnClassifierMinimumSilence)
        let turnClassifierExt = String(format: "%.1f", autoEndConfig.turnClassifierIncompleteExtensionSeconds)
        // swiftlint:disable:next line_length
        logger.info("SESSION START: autoEnd=\(self.autoEndConfig.enabled, privacy: .public) silence=\(silence, privacy: .public)s minSession=\(minSess, privacy: .public)s requireSpeech=\(self.autoEndConfig.requireSpeechFirst, privacy: .public) noSpeechTimeout=\(noSpeech, privacy: .public)s maxChunk=\(maxChunk, privacy: .public)s maxSpeak=\(maxSpeak, privacy: .public)s thinkingPause=\(thinking, privacy: .public)(+\(thinkExt, privacy: .public)s) turnClassifier=\(turnClassifier, privacy: .public) minSil=\(turnClassifierSil, privacy: .public)s ext=\(turnClassifierExt, privacy: .public)s")
    }

    // MARK: - Speech events

    /// Update session state when a VAD speech event fires.
    ///
    /// - For `.started`: marks the user as speaking, records when speaking began.
    /// - For `.ended`: marks the user as not speaking, records the end time, clears
    ///   the safety timeout tracker.
    public func onSpeechEvent(_ event: SpeechEvent) {
        switch event {
        case .started:
            isUserSpeaking = true
            hasSpeechOccurredInSession = true
            speakingStartTime = dateProvider()                  // ← Safety timeout tracking
            lastTurnCompletionProbability = nil
            lastTurnCompletionEvaluatedSpeechEnd = nil
            if chunkStartTime == nil { chunkStartTime = dateProvider() }
            logger.info("🎤 SPEECH START: sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s")

        case .ended:
            isUserSpeaking = false
            speakingStartTime = nil                            // ← Clear safety timeout tracker
            lastSpeechEndTime = dateProvider()
            lastTurnCompletionProbability = nil
            lastTurnCompletionEvaluatedSpeechEnd = nil
            logger.info("🔇 SPEECH END: sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s")
        }
    }

    // MARK: - Chunk decision

    /// Returns `true` when it is a good time to drain the audio buffer and send a chunk
    /// to the transcription API.
    ///
    /// Conditions:
    /// 1. The chunk has accumulated at least `maxChunkDuration` of audio.
    /// 2. The user is not currently speaking (don't interrupt mid-utterance).
    /// 3. Either enough silence has followed speech (clean boundary), or VAD never fired
    ///    speech-end (fallback: send anyway).
    public func shouldSendChunk() -> Bool {
        guard let start = chunkStartTime else { return false }
        let now = dateProvider()
        let duration = now.timeIntervalSince(start)

        guard duration >= maxChunkDuration else { return false }
        guard !isUserSpeaking else { return false }

        // Clean boundary: confirmed silence after speech end
        if let lastEnd = lastSpeechEndTime,
           now.timeIntervalSince(lastEnd) >= vadConfig.minSilenceAfterSpeech {
            return true
        }

        // Fallback: VAD never detected speech end — send anyway
        if lastSpeechEndTime == nil {
            logger.debug("Fallback chunk send: VAD never detected speech end, duration=\(String(format: "%.1f", duration))s")
            return true
        }

        return false
    }

    public func chunkSent() { chunkStartTime = dateProvider() }

    // MARK: - Auto-end decision

    /// Returns `true` when the session should be automatically terminated.
    ///
    /// ## Safety timeout check
    ///
    /// Before any other logic, we check whether `isUserSpeaking` has been `true` for
    /// longer than `maxContinuousSpeechDuration`. If so, we force-synthesise a speech-end
    /// event. This prevents the session from hanging permanently if VAD gets stuck.
    ///
    /// **Why here and not in a background Task?** SessionController is a poll-based actor
    /// (StreamingRecorder calls `shouldAutoEndSession()` every 0.5s). Checking here keeps
    /// all state mutations actor-isolated without requiring a separate Task or timer.
    ///
    /// ## Thinking pause check
    ///
    /// After the user stops speaking, if `lastTranscript` ends with a linguistically
    /// incomplete pattern (trailing conjunction, preposition, filler word), the effective
    /// silence threshold is extended by `thinkingPauseExtensionSeconds`.
    public func shouldAutoEndSession() -> Bool {
        guard autoEndConfig.enabled else {
            logger.debug("autoEnd: BLOCKED (disabled)")
            return false
        }

        let now = dateProvider()

        // ── Safety timeout: force-clear stuck speaking state ────────────────────
        // safety timeout: force-clear stuck speaking state
        if isUserSpeaking,
           autoEndConfig.maxContinuousSpeechDuration > 0,
           let start = speakingStartTime,
           now.timeIntervalSince(start) > autoEndConfig.maxContinuousSpeechDuration {
            let dur = String(format: "%.0f", now.timeIntervalSince(start))
            let max = String(format: "%.0f", autoEndConfig.maxContinuousSpeechDuration)
            logger.warning("⚠️ SAFETY: isUserSpeaking stuck for \(dur, privacy: .public)s > \(max, privacy: .public)s — force-clearing (VAD likely stuck). VAD likely stuck")
            // Force-synthesise a speech-end event
            isUserSpeaking = false
            speakingStartTime = nil
            lastSpeechEndTime = now
        }

        // ── Idle timeout: end if no speech after N seconds ──────────────────────
        if !hasSpeechOccurredInSession && autoEndConfig.noSpeechTimeout > 0,
           let start = sessionStartTime {
            let idleDuration = now.timeIntervalSince(start)
            if idleDuration >= autoEndConfig.noSpeechTimeout {
                logger.warning("🛑 AUTO-END IDLE: no speech detected after \(String(format: "%.1f", idleDuration), privacy: .public)s (timeout=\(String(format: "%.1f", self.autoEndConfig.noSpeechTimeout), privacy: .public)s)")
                return true
            }
        }

        // ── requireSpeechFirst guard ──────────────────────────────────────────
        if autoEndConfig.requireSpeechFirst && !hasSpeechOccurredInSession {
            logger.debug("autoEnd: BLOCKED (requireSpeechFirst, no speech yet, sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s)")
            return false
        }

        // ── Active speaking guard ─────────────────────────────────────────────
        guard !isUserSpeaking else {
            logger.debug("autoEnd: BLOCKED (user currently speaking)")
            return false
        }

        // ── Minimum session duration guard ────────────────────────────────────
        if let start = sessionStartTime, now.timeIntervalSince(start) < autoEndConfig.minSessionDuration {
            logger.debug("autoEnd: BLOCKED (session too short: \(String(format: "%.1f", now.timeIntervalSince(start)), privacy: .public)s < min=\(String(format: "%.1f", self.autoEndConfig.minSessionDuration), privacy: .public)s)")
            return false
        }

        // ── Normal: silence after confirmed speech end ────────────────────────
        if let lastEnd = lastSpeechEndTime {
            let silenceSoFar = now.timeIntervalSince(lastEnd)

            // Thinking pause check
            // If the transcript ends with a linguistically incomplete pattern, extend
            // the silence threshold to avoid cutting off mid-thought utterances.
            let effectiveSilenceThreshold = effectiveSilenceDuration()
            let thinkingDetected = effectiveSilenceThreshold > autoEndConfig.silenceDuration
            let classifierExtendedThreshold = turnClassifierExtendedThreshold(
                baseThreshold: effectiveSilenceThreshold
            )
            let classifierActive = classifierExtendedThreshold > effectiveSilenceThreshold

            if silenceSoFar >= classifierExtendedThreshold {
                logger.warning("🛑 AUTO-END NORMAL: silence=\(String(format: "%.1f", silenceSoFar), privacy: .public)s >= threshold=\(String(format: "%.1f", classifierExtendedThreshold), privacy: .public)s (thinkingPauseExtended=\(thinkingDetected, privacy: .public) turnClassifierExtended=\(classifierActive, privacy: .public))")
                return true
            }

            if classifierActive {
                logger.debug("autoEnd: TURN CLASSIFIER HOLD (silence=\(String(format: "%.1f", silenceSoFar), privacy: .public)s / extended=\(String(format: "%.1f", classifierExtendedThreshold), privacy: .public)s prob=\(String(format: "%.2f", self.lastTurnCompletionProbability ?? -1), privacy: .public))")
            } else if thinkingDetected {
                logger.debug("autoEnd: THINKING PAUSE (silence=\(String(format: "%.1f", silenceSoFar), privacy: .public)s / extended=\(String(format: "%.1f", effectiveSilenceThreshold), privacy: .public)s)")
            } else {
                logger.debug("autoEnd: WAITING (silence=\(String(format: "%.1f", silenceSoFar), privacy: .public)s / required=\(String(format: "%.1f", self.autoEndConfig.silenceDuration), privacy: .public)s)")
            }
            return false
        }

        // ── Fallback: VAD never fired speechEnd ───────────────────────────────
        if let start = sessionStartTime {
            let sessionDuration = now.timeIntervalSince(start)
            let requiredDuration = autoEndConfig.silenceDuration + autoEndConfig.minSessionDuration
            if sessionDuration >= requiredDuration {
                let dur = String(format: "%.1f", sessionDuration)
                let req = String(format: "%.1f", requiredDuration)
                // swiftlint:disable:next line_length
                logger.warning("AUTO-END FALLBACK: sessionDur=\(dur, privacy: .public)s >= required=\(req, privacy: .public)s hasSpeech=\(self.hasSpeechOccurredInSession, privacy: .public) speaking=\(self.isUserSpeaking, privacy: .public)")
                return true
            }
        }

        logger.debug("autoEnd: WAITING (no lastSpeechEndTime, sessionDur=\(String(format: "%.1f", self.currentSessionDuration), privacy: .public)s)")
        return false
    }

    // MARK: - Computed properties

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

    /// One-line diagnostic summary for periodic heartbeat logging.
    public var diagnosticSummary: String {
        let sessionDur = String(format: "%.1f", currentSessionDuration)
        let chunkDur = String(format: "%.1f", currentChunkDuration)
        let silDur = currentSilenceDuration.map { String(format: "%.1f", $0) } ?? "nil"
        let hasEnd = lastSpeechEndTime != nil ? "yes" : "no"
        let thinkingActive = !lastTranscript.isEmpty && autoEndConfig.thinkingPauseEnabled
            && ThinkingPauseDetector.isLikelyIncomplete(lastTranscript)
        return "session=\(sessionDur)s chunk=\(chunkDur)s speaking=\(isUserSpeaking) hasSpeech=\(hasSpeechOccurredInSession) silence=\(silDur)s lastEnd=\(hasEnd) thinkingPause=\(thinkingActive)"
    }

    // MARK: - Private helpers

    /// Returns the effective silence duration threshold, accounting for any thinking
    /// pause extension when the transcript is linguistically incomplete.
    ///
    /// ## Why this is a separate method
    ///
    /// This computation is called from `shouldAutoEndSession()` and from
    /// `diagnosticSummary`. Extracting it makes both call sites cleaner and
    /// keeps the extension logic in one place for testing.
    private func effectiveSilenceDuration() -> TimeInterval {
        guard autoEndConfig.thinkingPauseEnabled,
              !lastTranscript.isEmpty,
              ThinkingPauseDetector.isLikelyIncomplete(lastTranscript) else {
            return autoEndConfig.silenceDuration
        }
        let extended = autoEndConfig.silenceDuration + autoEndConfig.thinkingPauseExtensionSeconds
        if let pattern = ThinkingPauseDetector.incompletePattern(lastTranscript) {
            logger.debug("Thinking pause detected: pattern='\(pattern, privacy: .private(mask: .hash))' extending silence to \(String(format: "%.1f", extended), privacy: .public)s")
        }
        return extended
    }

    private func turnClassifierExtendedThreshold(baseThreshold: TimeInterval) -> TimeInterval {
        guard autoEndConfig.turnClassifierEnabled,
              let probability = lastTurnCompletionProbability,
              probability < autoEndConfig.turnClassifierThreshold else {
            return baseThreshold
        }
        return max(
            baseThreshold,
            autoEndConfig.silenceDuration + autoEndConfig.turnClassifierIncompleteExtensionSeconds
        )
    }

    /// Whether turn completion should be evaluated for the current speech-end boundary.
    public func shouldEvaluateTurnCompletion() -> Bool {
        guard autoEndConfig.turnClassifierEnabled,
              let lastEnd = lastSpeechEndTime else {
            return false
        }
        guard lastTurnCompletionEvaluatedSpeechEnd != lastEnd else { return false }
        let silence = dateProvider().timeIntervalSince(lastEnd)
        return silence >= autoEndConfig.turnClassifierMinimumSilence
    }

    /// Store classifier output for current boundary.
    public func setTurnCompletionProbability(_ probability: Float?) {
        lastTurnCompletionProbability = probability
    }

    /// Mark current speech-end as evaluated to avoid re-running classifier repeatedly.
    public func markTurnCompletionEvaluated() {
        lastTurnCompletionEvaluatedSpeechEnd = lastSpeechEndTime
    }
}

// MARK: - Test Helpers

#if DEBUG
extension SessionController {
    /// Test helper: Set chunk start time to simulate elapsed duration.
    // swiftlint:disable:next identifier_name
    public func _testSetChunkStartTime(_ date: Date?) {
        chunkStartTime = date
    }

    /// Test helper: Check if lastSpeechEndTime is nil (VAD never fired).
    // swiftlint:disable:next identifier_name
    public var _testLastSpeechEndTimeIsNil: Bool {
        lastSpeechEndTime == nil
    }

    /// Test helper: Get maxChunkDuration for verification.
    // swiftlint:disable:next identifier_name
    public var _testMaxChunkDuration: TimeInterval {
        maxChunkDuration
    }

    /// Test helper: Check if `isUserSpeaking` is currently true.
    // swiftlint:disable:next identifier_name
    public var _testIsUserSpeaking: Bool {
        isUserSpeaking
    }

    /// Test helper: Check if `speakingStartTime` is set.
    // swiftlint:disable:next identifier_name
    public var _testSpeakingStartTimeIsSet: Bool {
        speakingStartTime != nil
    }

    /// Test helper: Read back the effective silence duration (includes thinking pause).
    // swiftlint:disable:next identifier_name
    public func _testEffectiveSilenceDuration() -> TimeInterval {
        effectiveSilenceDuration()
    }
}
#endif
