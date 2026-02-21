import Foundation
import os

// MARK: - ThinkingPauseDetector
//
// ## Why this exists
//
// SpeakFlow's auto-end logic is purely time-based: after N seconds of silence following
// the last `speechEnd` event, the session ends. This is simple and usually correct, but
// it has a critical blind spot: it cannot distinguish between two very different silences:
//
//   (A) "I'm done dictating." — user finished, silence is real
//   (B) "I want to order a..."  — user is thinking, silence is a cognitive pause
//
// Both silences look identical acoustically. But they are linguistically very different.
// A transcript that ends with a conjunction ("and", "but", "because"), a preposition
// ("to", "for", "with"), an article ("a", "the"), a coordinating word, or a known filler
// ("um", "hmm", "let me think") is overwhelmingly likely to continue. The user paused
// to gather their thoughts, not to end the session.
//
// ## Why rule-based instead of LLM-based?
//
// An LLM-based approach could classify every response as complete or incomplete using
// semantic markers. This works well for a voice chatbot where an LLM is already in the
// pipeline. For SpeakFlow — a dictation app with no LLM in the loop — a local
// rule-based heuristic is more appropriate:
//
//   "If the last word(s) of the transcript are linguistically incomplete, extend the
//    silence threshold before auto-ending."
//
// This is a zero-cost local decision (no network, no model) that runs in microseconds.
//
// ## Design
//
// `ThinkingPauseDetector` is a pure function namespace (enum with no cases). It has no
// state; callers pass the transcript text and get back a boolean. This makes it trivially
// testable and injectable into `SessionController` without any actor complexity.
//
// ## Configuration
//
// Enabled/disabled and extension seconds live in `AutoEndConfiguration.thinkingPause*`
// fields so users can tune or disable this behaviour in the app's advanced settings.
//
// ## Limitations and intentional trade-offs
//
// - False positives: sentences ending in "so" or "for" will be held open even if the
//   user meant them as complete clauses ("...and that's all I wanted to say for now").
//   We accept this: a brief extra wait (5s) is less disruptive than premature session end.
//
// - False negatives: a user who genuinely finishes on "the" or "a" will be held open
//   briefly. This is rare in natural dictation because complete thoughts rarely end on
//   articles or bare prepositions.
//
// - No language awareness: the word lists are English-only. Future work could add
//   per-language word sets behind the same API.

/// Detects linguistic patterns in a transcript that suggest the user has paused
/// mid-thought rather than finished dictating.
///
/// Use `isLikelyIncomplete(_:)` in ``SessionController`` to extend the auto-end
/// silence threshold when the transcript ends with an incomplete pattern. All
/// timing parameters live in ``AutoEndConfiguration`` so users can tune or disable
/// this behaviour in the app's settings.
///
/// ## Design rationale
/// Adapts the concept of LLM-based turn-completion detection (where ✓/○/◐ markers
/// classify completeness) into a zero-cost local rule-based approach suitable for a
/// dictation app without an LLM in the pipeline.
public enum ThinkingPauseDetector {

    // MARK: - Word lists

    /// Filler words and hesitation phrases that always indicate the speaker is still
    /// formulating their next thought. These appear mid-sentence and signal "more to come".
    ///
    /// Source: common English discourse markers and hesitation phenomena.
    /// - Note: Multi-word phrases are checked via suffix matching of the lowercased transcript.
    private static let thinkingFillers: Set<String> = [
        // Single-word hesitations
        "um", "uh", "hmm", "hm", "er", "ah", "eh",
        // Explicit thinking signals
        "wait", "so", "anyway", "basically", "actually", "literally",
        "right", "okay", "ok", "well", "now",
        // Fragment discourse markers
        "like", "just",
    ]

    /// Multi-word phrases that strongly predict continuation. Checked as suffix of the
    /// full lowercased transcript (after punctuation stripping).
    private static let thinkingPhrases: [String] = [
        "let me think", "let me see", "let me check", "let me look",
        "hold on", "one moment", "one second", "give me a second",
        "give me a moment", "give me a sec",
        "where was i", "what was i saying", "where were we",
        "how do i say this", "how should i put this",
        "i mean", "you know", "i guess", "i think",
        "in other words", "that is to say",
    ]

    /// Words that when appearing at the END of a transcript almost certainly signal
    /// the sentence is structurally incomplete — the next clause or phrase is pending.
    ///
    /// Organised by grammatical category for readability and maintainability.
    private static let incompleteTerminals: Set<String> = [
        // ── Coordinating conjunctions (FANBOYS) ──
        // A sentence ending on any of these is almost never grammatically complete.
        "for", "and", "nor", "but", "or", "yet", "so",

        // ── Common subordinating conjunctions ──
        // These open dependent clauses; the main clause hasn't arrived yet.
        "because", "since", "while", "although", "though",
        "if", "unless", "until", "when", "where", "whereas",
        "after", "before", "as", "that", "which", "who",
        "once", "whether", "though", "even",

        // ── Prepositions at end of clause (dangling) ──
        // English allows preposition-stranding; a bare preposition at end is incomplete.
        "to", "of", "in", "on", "at", "by", "with", "from",
        "into", "through", "over", "under", "between", "among",
        "about", "around", "against", "along", "across", "behind",
        "beyond", "beside", "beneath", "above", "within", "without",
        "during", "despite", "upon", "onto", "off",

        // ── Articles / determiners (before a noun that hasn't been said yet) ──
        "the", "a", "an",
        "this", "that", "these", "those",
        "my", "your", "his", "her", "their", "our", "its",
        "each", "every", "some", "any", "no", "all",
        "both", "either", "neither", "another", "other",

        // ── Modal verbs without main verb ──
        // "I would", "she can", "they must" — all need a verb phrase to follow.
        "would", "could", "should", "will", "can",
        "might", "must", "shall", "may", "ought",

        // ── Comparative / degree words expecting a complement ──
        "more", "less", "rather", "quite", "very", "too",
        "such", "enough", "further", "additional",
    ]

    // MARK: - Cached constants

    /// Trailing punctuation characters to strip during normalisation.
    ///
    /// ## Performance
    ///
    /// Previous implementation built this `CharacterSet` from scratch on every
    /// `normalize()` call using 6 `formUnion` operations — allocating and copying
    /// an 8 KB bitmap 7 times per invocation. `normalize()` is called every 0.5s
    /// (from `shouldAutoEndSession()`) and every 2s (from `diagnosticSummary`).
    ///
    /// `static let` initialises once at first use and is shared for the lifetime
    /// of the process — zero allocation on every subsequent call.
    private static let trailingPunctuation: CharacterSet = {
        CharacterSet(charactersIn:
            ".,;:?!"                                    // common sentence terminators
            + "\u{2026}"                                // … ellipsis
            + "\u{201C}\u{201D}\u{2018}\u{2019}\"'"    // curly and straight quotes
            + "\u{2013}\u{2014}-"                       // en-dash, em-dash, hyphen
        )
    }()

    /// Multi-word thinking phrases grouped by their last word for O(1) pre-filter.
    ///
    /// ## Performance
    ///
    /// Previous implementation linearly scanned `thinkingPhrases` (22 entries) on
    /// every `isLikelyIncomplete()` call, calling `hasSuffix` on each. `hasSuffix`
    /// is O(|phrase|) Unicode-scalar comparison.
    ///
    /// With this dictionary, the lookup path becomes:
    ///   1. O(1) dictionary lookup by last word  (0 `hasSuffix` calls on miss)
    ///   2. ≤ 3 `hasSuffix` calls on hit (most last words map to exactly one phrase)
    ///
    /// Built once at first use as a `static let`; zero allocation on every call.
    private static let phrasesByLastWord: [String: [String]] = {
        var map: [String: [String]] = [:]
        for phrase in thinkingPhrases {
            // Use the last component of each phrase as the lookup key
            let lastWord = phrase.components(separatedBy: " ").last ?? phrase
            map[lastWord, default: []].append(phrase)
        }
        return map
    }()

    // MARK: - Normalisation cache

    /// Thread-safe cache for the last normalise + tokenise result.
    ///
    /// Between consecutive 0.5s polling calls the transcript rarely changes, so the
    /// common path is a single string-equality check — zero allocations.
    ///
    /// Uses `OSAllocatedUnfairLock` (same pattern as `AudioSampleQueue` and
    /// `AudioSessionRef`) for safe concurrent access. In production, calls are
    /// serialised through `SessionController` (an actor), but swift-testing runs
    /// tests in parallel and statics are shared global state.
    private struct NormCache {
        var input:      String   = ""
        var normalized: String   = ""
        var words:      [String] = []
    }
    private static let _cache = OSAllocatedUnfairLock(initialState: NormCache())

    // MARK: - Public API

    /// Returns `true` if the transcript is linguistically likely to continue.
    ///
    /// Checks (in order of specificity):
    /// 1. Multi-word thinking phrases (highest confidence, O(1) dict lookup + ≤3 suffix checks)
    /// 2. Single-word filler at end
    /// 3. Grammatically incomplete terminal word
    ///
    /// - Parameter transcript: The most recent full transcript from the current session.
    ///   May contain punctuation — it is cleaned before analysis.
    /// - Returns: `true` when the transcript ends with an incomplete linguistic pattern;
    ///   the caller should extend the silence threshold before auto-ending.
    public static func isLikelyIncomplete(_ transcript: String) -> Bool {
        let (cleaned, words) = normalizeWithWords(transcript)
        guard !cleaned.isEmpty else { return false }

        // 1. Multi-word thinking phrases — O(1) dict lookup, ≤3 hasSuffix on hit
        if let lastWord = words.last,
           let candidates = phrasesByLastWord[lastWord] {
            for phrase in candidates where cleaned.hasSuffix(phrase) {
                return true
            }
        }

        // 2. Tokenise and inspect the last word (already done inside normalizeWithWords)
        guard let lastWord = words.last else { return false }

        // 3. Single-word filler check
        if thinkingFillers.contains(lastWord) { return true }

        // 4. Grammatically incomplete terminal
        if incompleteTerminals.contains(lastWord) { return true }

        return false
    }

    /// Returns the specific pattern that caused an incomplete detection, or `nil` if
    /// the transcript looks complete. Used for logging and debugging.
    public static func incompletePattern(_ transcript: String) -> String? {
        let (cleaned, words) = normalizeWithWords(transcript)
        guard !cleaned.isEmpty else { return nil }

        if let lastWord = words.last,
           let candidates = phrasesByLastWord[lastWord] {
            for phrase in candidates where cleaned.hasSuffix(phrase) {
                return "phrase:\(phrase)"
            }
        }

        guard let lastWord = words.last else { return nil }

        if thinkingFillers.contains(lastWord) { return "filler:\(lastWord)" }
        if incompleteTerminals.contains(lastWord) { return "terminal:\(lastWord)" }

        return nil
    }

    // MARK: - Private helpers

    /// Strips trailing punctuation, lowercases, and tokenises the transcript.
    ///
    /// Returns both the normalised string and the token array so callers that need
    /// both avoid double work.
    ///
    /// ## Performance
    ///
    /// Caches the last result. Between consecutive 0.5s polling calls the transcript
    /// rarely changes, so the common path is a single string-equality check — zero
    /// allocations.
    ///
    /// Keeps apostrophes (contractions) and hyphens (compound words) intact.
    /// Strips: period, comma, semicolon, colon, question mark, exclamation, ellipsis,
    ///         em/en dash at word boundary, quote characters.
    private static func normalizeWithWords(_ text: String) -> (normalized: String, words: [String]) {
        // Fast path: same input as last call — return cached result (0 allocations).
        // Lock scope is minimal: read-check, then early return or compute + write.
        let cached: (String, [String])? = _cache.withLock { state -> (String, [String])? in
            if text == state.input { return (state.normalized, state.words) }
            return nil
        }
        if let cached { return cached }

        var s = text.lowercased()

        // Strip trailing punctuation using pre-built static CharacterSet
        while let last = s.unicodeScalars.last, trailingPunctuation.contains(last) {
            s.removeLast()
        }

        // Tokenise with split(separator:) — avoids empty elements, no `.filter { !$0.isEmpty }`
        let words = s.split(separator: " ").map(String.init)

        // Update cache under lock — capture immutable copies for Sendable
        let result = (s, words)
        _cache.withLock { state in
            state.input      = text
            state.normalized = result.0
            state.words      = result.1
        }

        return result
    }

    /// Legacy entry point kept for any call sites that only need the normalised string.
    private static func normalize(_ text: String) -> String {
        normalizeWithWords(text).normalized
    }
}
