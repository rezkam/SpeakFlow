import Foundation

/// A `SPEAKFLOW_E2E_*` variable that is present but unusable. The runner
/// fails instead of silently falling back to defaults.
public enum LiveE2EConfigError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

/// One live E2E scenario, as requested by a wrapper script through
/// `SPEAKFLOW_E2E_*` environment variables. This is the single configuration
/// interface between the wrappers and the runner.
public struct LiveE2EScenarioConfig: Equatable, Sendable {
    public enum Audio: Equatable, Sendable {
        /// Speech generated with macOS `say`, optionally in two parts.
        case speech(text: String, secondText: String?, gapSeconds: Double, rate: Int?)
        /// A pre-recorded audio file (noise rejection).
        case file(path: String)
    }

    public enum AutoEndExpectation: Equatable, Sendable {
        /// Wait for auto-end; it must fire, within the window when given.
        case mustFire(minSeconds: Double?, maxSeconds: Double?)
    }

    public var audio: Audio
    public var chunkSeconds: Double?
    /// Total time to record when not waiting for auto-end.
    public var recordSeconds: Double?
    /// Upper bound on the whole scenario.
    public var timeoutSeconds: Double?
    public var expectPhrase: String?
    public var autoEnd: AutoEndExpectation?
    /// Non-speech audio: no chunk may be sent for transcription.
    public var noiseRejection = false
    public var minChunks: Int?
    public var maxChunks: Int?

    /// Reads the scenario from the environment. Returns nil when no scenario
    /// is requested (the runner then runs its built-in suite).
    public static func fromEnvironment(_ environment: [String: String]) throws -> LiveE2EScenarioConfig? {
        let env = EnvironmentReader(environment)
        let text = env.string("SPEAKFLOW_E2E_AUTO_SPEAK_TEXT")
        let filePath = env.string("SPEAKFLOW_E2E_AUDIO_FILE_PATH")
        let noiseRejection = try env.flag("SPEAKFLOW_E2E_TEST_NOISE_REJECTION")
        guard text != nil || filePath != nil || noiseRejection else { return nil }

        let audio: Audio
        if let filePath {
            audio = .file(path: filePath)
        } else if let text {
            audio = .speech(
                text: text,
                secondText: env.string("SPEAKFLOW_E2E_AUTO_SPEAK_TEXT_PART2"),
                gapSeconds: try env.double("SPEAKFLOW_E2E_AUTO_SPEAK_GAP_SECONDS") ?? 0,
                rate: try env.int("SPEAKFLOW_E2E_AUTO_SPEAK_RATE")
            )
        } else {
            throw LiveE2EConfigError.invalid("SPEAKFLOW_E2E_TEST_NOISE_REJECTION needs SPEAKFLOW_E2E_AUDIO_FILE_PATH")
        }

        var config = LiveE2EScenarioConfig(audio: audio)
        config.chunkSeconds = try env.double("SPEAKFLOW_E2E_CHUNK_DURATION")
        config.recordSeconds = try env.double("SPEAKFLOW_E2E_RECORD_SECONDS")
        config.timeoutSeconds = try env.double("SPEAKFLOW_E2E_TIMEOUT_SECONDS")
        config.expectPhrase = env.string("SPEAKFLOW_E2E_EXPECT_PHRASE")
        config.noiseRejection = noiseRejection
        config.minChunks = try env.int("SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS")
        config.maxChunks = try env.int("SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS")
        if try env.flag("SPEAKFLOW_E2E_TEST_AUTO_END") {
            config.autoEnd = .mustFire(
                minSeconds: try env.double("SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS"),
                maxSeconds: try env.double("SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS")
            )
        }
        return config
    }

    public init(audio: Audio) {
        self.audio = audio
    }

    /// Whether this scenario needs the transcription API.
    public var needsTranscription: Bool { expectPhrase != nil }

    /// Applies every requested assertion to what the run observed. An
    /// assertion that could not execute is a failure, and a scenario that
    /// requested no assertion cannot pass.
    public func evaluate(_ observation: LiveE2EObservation) -> LiveE2EVerdict {
        var outcome = AssertionOutcome()
        checkPhrase(observation, into: &outcome)
        checkAutoEnd(observation, into: &outcome)
        checkChunks(observation, into: &outcome)
        if outcome.executed.isEmpty && outcome.failures.isEmpty {
            outcome.failures.append("no assertions requested")
        }
        return LiveE2EVerdict(
            executed: outcome.executed,
            failures: outcome.failures,
            chunks: observation.chunks,
            autoEndSeconds: observation.autoEndSeconds
        )
    }

    private struct AssertionOutcome {
        var executed: [String] = []
        var failures: [String] = []
    }

    private func checkPhrase(_ observation: LiveE2EObservation, into outcome: inout AssertionOutcome) {
        guard let expectPhrase else { return }
        guard let transcript = observation.transcript else {
            outcome.failures.append("phrase: transcription did not run (ChatGPT login required)")
            return
        }
        outcome.executed.append("phrase")
        if !Self.phraseMatches(expected: expectPhrase, actual: transcript) {
            outcome.failures.append("phrase: expected \"\(expectPhrase)\" in \"\(transcript)\"")
        }
    }

    private func checkAutoEnd(_ observation: LiveE2EObservation, into outcome: inout AssertionOutcome) {
        guard case let .mustFire(minSeconds, maxSeconds)? = autoEnd else { return }
        outcome.executed.append("autoEndFired")
        guard let seconds = observation.autoEndSeconds else {
            outcome.failures.append("autoEndFired: auto-end did not fire")
            return
        }
        guard minSeconds != nil || maxSeconds != nil else { return }
        outcome.executed.append("autoEndWindow")
        if let minSeconds, seconds < minSeconds {
            outcome.failures.append("autoEndWindow: fired at \(seconds)s, before \(minSeconds)s")
        }
        if let maxSeconds, seconds > maxSeconds {
            outcome.failures.append("autoEndWindow: fired at \(seconds)s, after \(maxSeconds)s")
        }
    }

    private func checkChunks(_ observation: LiveE2EObservation, into outcome: inout AssertionOutcome) {
        if noiseRejection {
            outcome.executed.append("noChunks")
            if observation.chunks != 0 {
                outcome.failures.append("noChunks: \(observation.chunks) chunk(s) sent for non-speech audio")
            }
        }
        guard minChunks != nil || maxChunks != nil else { return }
        outcome.executed.append("chunkRange")
        if let minChunks, observation.chunks < minChunks {
            outcome.failures.append("chunkRange: \(observation.chunks) chunk(s), fewer than \(minChunks)")
        }
        if let maxChunks, observation.chunks > maxChunks {
            outcome.failures.append("chunkRange: \(observation.chunks) chunk(s), more than \(maxChunks)")
        }
    }

    /// At least three quarters of the distinct expected words appear in the
    /// transcript, ignoring case and punctuation.
    static func phraseMatches(expected: String, actual: String) -> Bool {
        let expectedWords = words(expected)
        guard !expectedWords.isEmpty else { return true }
        let found = expectedWords.intersection(words(actual)).count
        return found * 4 >= expectedWords.count * 3
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

/// What a scenario run observed.
public struct LiveE2EObservation: Sendable {
    public let chunks: Int
    public let autoEndSeconds: Double?
    /// nil when transcription did not run.
    public let transcript: String?

    public init(chunks: Int, autoEndSeconds: Double?, transcript: String?) {
        self.chunks = chunks
        self.autoEndSeconds = autoEndSeconds
        self.transcript = transcript
    }
}

public struct LiveE2EVerdict: Sendable {
    /// Assertions that ran, in order.
    public let executed: [String]
    public let failures: [String]
    let chunks: Int
    let autoEndSeconds: Double?

    public var passed: Bool { failures.isEmpty }

    /// The line wrappers check: status and the assertions that executed.
    public var resultLine: String {
        let autoEnd = autoEndSeconds.map { String(format: "%.1f", $0) } ?? "none"
        return "E2E_RESULT status=\(passed ? "pass" : "fail") assertions=\(executed.joined(separator: ",")) "
            + "chunks=\(chunks) auto_end_seconds=\(autoEnd)"
    }
}

/// Machine-readable progress lines, printed at column 0 for wrapper scripts.
public enum LiveE2EOutput {
    public static func chunkLine(index: Int, seconds: Double, speechPercent: Int) -> String {
        "E2E_CHUNK index=\(index) seconds=\(String(format: "%.1f", seconds)) speech=\(speechPercent)"
    }

    public static func autoEndLine(seconds: Double) -> String {
        "E2E_AUTO_END seconds=\(String(format: "%.1f", seconds))"
    }

    public static func transcriptLine(_ transcript: String) -> String {
        "E2E_TRANSCRIPT \(transcript.replacingOccurrences(of: "\n", with: " "))"
    }
}

private struct EnvironmentReader {
    let environment: [String: String]

    init(_ environment: [String: String]) {
        self.environment = environment
    }

    func string(_ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    func double(_ key: String) throws -> Double? {
        guard let raw = string(key) else { return nil }
        guard let value = Double(raw), value >= 0 else {
            throw LiveE2EConfigError.invalid("\(key)=\(raw) is not a non-negative number")
        }
        return value
    }

    func int(_ key: String) throws -> Int? {
        guard let raw = string(key) else { return nil }
        guard let value = Int(raw), value >= 0 else {
            throw LiveE2EConfigError.invalid("\(key)=\(raw) is not a non-negative integer")
        }
        return value
    }

    func flag(_ key: String) throws -> Bool {
        switch string(key)?.lowercased() {
        case nil, "0", "false", "no": return false
        case "1", "true", "yes": return true
        case let other?: throw LiveE2EConfigError.invalid("\(key)=\(other) is not a boolean")
        }
    }
}
