import Foundation

// MARK: - AutoEndConfiguration
//
// ## Why this struct exists
//
// Auto-end controls when a recording session finishes automatically without the user
// pressing the hotkey. Every field is user-configurable because the right values are
// highly environment-dependent:
//
//   - A professional transcriptionist thinks in long complex sentences → needs long silence.
//   - A quick note-taker fires off short bursts → short silence is fine.
//   - A user in a noisy environment needs VAD robustness guards turned up.
//   - A user with perfect acoustics can afford tight thresholds.
//
// All fields include documentation explaining their rationale and default values.

/// Configuration for automatic session termination.
///
/// Passed to ``SessionController`` at recording start. Immutable during a session —
/// changing settings mid-session requires stopping and restarting.
///
/// ## Configurable fields
///
/// | Field | Default | What it controls |
/// |---|---|---|
/// | `enabled` | `true` | Master switch for all auto-end behaviour |
/// | `silenceDuration` | `10.0s` | Seconds of confirmed silence before ending |
/// | `minSessionDuration` | `2.0s` | Minimum session length before any auto-end fires |
/// | `requireSpeechFirst` | `true` | Do not end if no speech was ever detected |
/// | `noSpeechTimeout` | `10.0s` | End after N seconds if no speech detected at all |
/// | `maxContinuousSpeechDuration` | `180.0s` | Safety: force-clear stuck speaking state |
/// | `thinkingPauseEnabled` | `true` | Extend silence threshold when mid-thought detected |
/// | `thinkingPauseExtensionSeconds` | `5.0s` | Extra seconds to allow for thinking pauses |
/// | `turnClassifierEnabled` | `false` | Enable SmartTurn-style completion gating |
/// | `turnClassifierMinimumSilence` | `1.5s` | Minimum silence before classifier evaluation |
/// | `turnClassifierIncompleteExtensionSeconds` | `3.0s` | Extra wait when classifier predicts incomplete |
/// | `turnClassifierThreshold` | `0.5` | Completion probability threshold |
public struct AutoEndConfiguration: Sendable {

    // MARK: - Core auto-end fields

    /// Master switch. When `false`, no automatic session termination occurs.
    public var enabled: Bool

    /// Seconds of confirmed post-speech silence required before the session auto-ends.
    ///
    /// Clamped to a minimum of 3.0s in ``SessionController`` to prevent accidental
    /// premature auto-end caused by the 3.0s `minSilenceAfterSpeech` in FluidAudio VAD.
    /// (FluidAudio only fires `speechEnd` after 3.0s of confirmed silence, so values
    /// below 3.0s can never actually be reached through the normal VAD path.)
    public var silenceDuration: TimeInterval

    /// Minimum total session duration before auto-end is even considered.
    /// Prevents sub-second sessions from auto-ending before the user has a chance to speak.
    public var minSessionDuration: TimeInterval

    /// When `true`, auto-end is blocked until at least one `speechStart` event has fired.
    /// Prevents sessions from auto-ending in pure silence with no dictation at all.
    public var requireSpeechFirst: Bool

    /// Maximum idle time (from session start) with no speech before ending the session.
    /// Guards against the "user started recording, got distracted" scenario.
    /// Set to `0` to disable.
    public var noSpeechTimeout: TimeInterval

    // MARK: - Safety: stuck speaking state
    //
    // We track `speakingStartTime` in SessionController. If the user has been continuously
    // marked as "speaking" for longer than `maxContinuousSpeechDuration`, we force-clear
    // the state (log a warning, synthesise a speech-end event). This is physiologically
    // justified: no human dictation session involves truly unbroken speech for 3 minutes.
    // Any such state indicates a stuck VAD, not real continuous speech.
    //
    // Default: 180 seconds (3 minutes). Set higher for edge cases (e.g., reading a very
    // long passage without pause), lower for stricter safety (e.g., 60s in noisy environments).

    /// Maximum duration (in seconds) that `isUserSpeaking` can remain `true` without
    /// a `speechEnd` event before it is force-cleared as a safety measure.
    ///
    /// Prevents the session from hanging permanently if VAD gets stuck in "speaking" state
    /// due to continuous background noise, model error, or FluidAudio internal state issues.
    ///
    /// Set to `0` to disable (not recommended).
    public var maxContinuousSpeechDuration: TimeInterval

    // MARK: - Thinking pause detection
    //
    // `ThinkingPauseDetector` applies a rule-based heuristic: if the last word(s) of the
    // current transcript are linguistically incomplete (trailing conjunction, preposition,
    // article, modal verb, or filler word), the session is very likely to continue. We
    // extend the silence threshold by `thinkingPauseExtensionSeconds` before firing auto-end.
    //
    // This prevents the common frustration of "I was mid-sentence and the session ended."
    // The extension adds at most 5 extra seconds, which is imperceptible compared to the
    // disruption of losing an incomplete utterance.

    /// When `true`, the session controller will check ``ThinkingPauseDetector`` before
    /// firing auto-end. If the current transcript ends with an incomplete pattern, the
    /// silence threshold is extended by ``thinkingPauseExtensionSeconds``.
    ///
    public var thinkingPauseEnabled: Bool

    /// Additional seconds of silence allowed when ``ThinkingPauseDetector`` determines
    /// the transcript is likely incomplete.
    ///
    /// Total effective threshold when thinking pause fires:
    /// `silenceDuration + thinkingPauseExtensionSeconds`
    ///
    /// Default: 5.0s. Increase for deliberate speakers; decrease for quick-note users.
    public var thinkingPauseExtensionSeconds: TimeInterval

    // MARK: - Turn completion classifier

    /// Enables SmartTurn-style turn completion gating in ``SessionController``.
    public var turnClassifierEnabled: Bool

    /// Minimum silence after speech end before classifier output is considered.
    public var turnClassifierMinimumSilence: TimeInterval

    /// Extra silence allowance when the classifier predicts an incomplete turn.
    public var turnClassifierIncompleteExtensionSeconds: TimeInterval

    /// Completion threshold in [0,1]. Probabilities below this are treated as incomplete.
    public var turnClassifierThreshold: Float

    // MARK: - Init

    public init(
        enabled: Bool = true,
        silenceDuration: TimeInterval = 10.0,
        minSessionDuration: TimeInterval = 2.0,
        requireSpeechFirst: Bool = true,
        noSpeechTimeout: TimeInterval = 10.0,
        maxContinuousSpeechDuration: TimeInterval = 180.0,
        thinkingPauseEnabled: Bool = true,
        thinkingPauseExtensionSeconds: TimeInterval = 5.0,
        turnClassifierEnabled: Bool = false,
        turnClassifierMinimumSilence: TimeInterval = 1.5,
        turnClassifierIncompleteExtensionSeconds: TimeInterval = 3.0,
        turnClassifierThreshold: Float = 0.5
    ) {
        self.enabled = enabled
        self.silenceDuration = silenceDuration
        self.minSessionDuration = minSessionDuration
        self.requireSpeechFirst = requireSpeechFirst
        self.noSpeechTimeout = noSpeechTimeout
        self.maxContinuousSpeechDuration = maxContinuousSpeechDuration
        self.thinkingPauseEnabled = thinkingPauseEnabled
        self.thinkingPauseExtensionSeconds = thinkingPauseExtensionSeconds
        self.turnClassifierEnabled = turnClassifierEnabled
        self.turnClassifierMinimumSilence = turnClassifierMinimumSilence
        self.turnClassifierIncompleteExtensionSeconds = turnClassifierIncompleteExtensionSeconds
        self.turnClassifierThreshold = turnClassifierThreshold
    }

    // MARK: - Presets

    /// Balanced defaults suitable for most dictation use cases.
    public static let `default` = AutoEndConfiguration()

    /// Tighter silence threshold (3s) for quick-note users.
    public static let quick = AutoEndConfiguration(silenceDuration: 3.0)

    /// Relaxed silence threshold (10s) for deliberate speakers or noisy environments.
    public static let relaxed = AutoEndConfiguration(silenceDuration: 10.0)

    /// Auto-end fully disabled. The user must press the hotkey to stop.
    public static let disabled = AutoEndConfiguration(enabled: false)
}
