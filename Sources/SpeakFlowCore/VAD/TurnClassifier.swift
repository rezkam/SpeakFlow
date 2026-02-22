import Foundation

#if canImport(CoreML)
import CoreML
#endif

/// SmartTurn-style turn completion classifier.
///
/// The classifier prefers a CoreML model when available and falls back to a
/// deterministic heuristic that combines transcript structure + short-tail audio energy.
public actor TurnClassifier {
    public enum Backend: String, Sendable {
        case heuristic
        case coreML
    }

    private(set) var backend: Backend = .heuristic

    #if canImport(CoreML)
    private var model: MLModel?
    #endif

    public init() {}

    /// Attempts to load a bundled CoreML model (`smart_turn.mlmodelc` by default).
    /// If unavailable or invalid, classifier stays in heuristic mode.
    public func loadModelIfAvailable(
        bundle: Bundle = .main,
        resourceName: String = "smart_turn",
        extension ext: String = "mlmodelc"
    ) {
        #if canImport(CoreML)
        guard let url = bundle.url(forResource: resourceName, withExtension: ext),
              let loaded = try? MLModel(contentsOf: url) else {
            backend = .heuristic
            model = nil
            return
        }
        model = loaded
        backend = .coreML
        #else
        _ = bundle
        _ = resourceName
        _ = ext
        backend = .heuristic
        #endif
    }

    /// Returns completion probability in [0,1].
    public func classify(transcript: String, recentAudio: [Float], sampleRate: Double = 16_000) -> Float {
        #if canImport(CoreML)
        if let model, let score = runCoreML(model: model, recentAudio: recentAudio) {
            return clamp01(score)
        }
        #endif
        return heuristicScore(transcript: transcript, recentAudio: recentAudio, sampleRate: sampleRate)
    }

    private func heuristicScore(transcript: String, recentAudio: [Float], sampleRate: Double) -> Float {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0.2 }

        var score: Float = 0.5
        let words = lexicalWordCount(trimmed)

        if hasTerminalPunctuation(trimmed) { score += 0.25 }
        if words >= 5 { score += 0.10 }
        if words <= 1 && !hasTerminalPunctuation(trimmed) { score -= 0.20 }
        if ThinkingPauseDetector.isLikelyIncomplete(trimmed) { score -= 0.35 }

        // Short-tail silence after speech tends to indicate completion.
        let tailSeconds = 0.4
        let tailCount = max(1, Int(tailSeconds * sampleRate))
        let tail = recentAudio.suffix(tailCount)
        if !tail.isEmpty {
            let rms = sqrt(tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(tail.count))
            if rms < 0.003 {
                score += 0.08
            } else if rms > 0.02 {
                score -= 0.08
            }
        }

        return clamp01(score)
    }

    private func clamp01(_ value: Float) -> Float {
        max(0, min(1, value))
    }

    private func lexicalWordCount(_ text: String) -> Int {
        var count = 0
        var inToken = false
        for scalar in text.unicodeScalars {
            let isWord = CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
            if isWord {
                if !inToken {
                    count += 1
                    inToken = true
                }
            } else {
                inToken = false
            }
        }
        return count
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let trailingClosers = CharacterSet(charactersIn: "\"'”’)]}")
        let terminalPunctuation = CharacterSet(charactersIn: ".!?;:…")
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, trailingClosers.contains(last) {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return terminalPunctuation.contains(last)
    }
}

#if canImport(CoreML)
private extension TurnClassifier {
    /// Best-effort CoreML inference:
    /// - Uses first MultiArray input.
    /// - Fills with truncated/padded recent audio samples.
    /// - Reads first numeric output as completion probability.
    func runCoreML(model: MLModel, recentAudio: [Float]) -> Float? {
        guard let firstInput = model.modelDescription.inputDescriptionsByName.first,
              firstInput.value.type == .multiArray,
              let constraint = firstInput.value.multiArrayConstraint else {
            return nil
        }

        let shape = constraint.shape.map { $0.intValue }
        guard let array = try? MLMultiArray(shape: shape as [NSNumber], dataType: .float32) else {
            return nil
        }

        let count = array.count
        let src = Array(recentAudio.suffix(count))
        let padding = max(0, count - src.count)
        for i in 0..<count {
            let value: Float
            if i < padding {
                value = 0
            } else {
                value = src[i - padding]
            }
            array[i] = NSNumber(value: value)
        }

        let input = try? MLDictionaryFeatureProvider(dictionary: [firstInput.key: MLFeatureValue(multiArray: array)])
        guard let input else { return nil }
        guard let output = try? model.prediction(from: input) else { return nil }

        // First numeric output wins.
        for name in output.featureNames {
            let feature = output.featureValue(for: name)
            if let number = feature?.doubleValue {
                return Float(number)
            }
            if let outArray = feature?.multiArrayValue, outArray.count > 0 {
                return outArray[0].floatValue
            }
        }
        return nil
    }
}
#endif

#if DEBUG
extension TurnClassifier {
    // swiftlint:disable:next identifier_name
    public var _testBackend: Backend { backend }
}
#endif
