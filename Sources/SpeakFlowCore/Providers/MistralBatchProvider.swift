import Foundation
import OSLog

// MARK: - Mistral Batch Provider

/// Mistral Voxtral batch transcription provider.
/// Sends a complete audio file to `POST /v1/audio/transcriptions` and returns the text.
/// Uses the `voxtral-mini-latest` model (same endpoint as the Python SDK's
/// `client.audio.transcriptions.complete()`).
///
/// Audio is recorded locally as WAV (16kHz mono 16-bit PCM) and uploaded via
/// multipart/form-data — the same pipeline as ChatGPT batch transcription.
public final class MistralBatchProvider: BatchTranscriptionProvider, @unchecked Sendable {
    public let id = ProviderId.mistralBatch
    public let displayName = "Mistral"
    public let mode: ProviderMode = .batch
    public var authRequirement: ProviderAuthRequirement { .apiKey(providerId: ProviderId.mistral) }

    /// Shares the API key with the Mistral realtime provider — both use the same
    /// Mistral account. Keyed by `ProviderId.mistral` in `UnifiedAuthStorage`.
    public var isConfigured: Bool {
        UnifiedAuthStorage.shared.apiKey(for: ProviderId.mistral) != nil
    }

    private let logger = Logger(subsystem: "SpeakFlow", category: "MistralBatch")
    private let providerSettings: any ProviderSettingsProviding
    private let settings: any MistralSettingsProviding

    @MainActor
    public init(
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared,
        settings: any MistralSettingsProviding = Settings.shared
    ) {
        self.providerSettings = providerSettings
        self.settings = settings
    }

    public func transcribe(audio: Data) async throws -> String {
        // Read MainActor-isolated state in one hop
        let (apiKey, model, language, temperature, diarize, contextBias) = await MainActor.run {
            (
                providerSettings.apiKey(for: ProviderId.mistral),
                settings.mistralBatchModel,
                settings.mistralLanguage,
                settings.mistralTemperature,
                settings.mistralDiarize,
                settings.mistralContextBias
            )
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw MistralBatchError.missingApiKey
        }

        return try await performRequest(
            audio: audio,
            apiKey: apiKey,
            model: model,
            language: language,
            temperature: temperature,
            diarize: diarize,
            contextBias: contextBias
        )
    }

    // MARK: - Network

    /// Transcription endpoint URL.
    static let transcriptionEndpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!

    /// Build the multipart POST request to Mistral's transcription endpoint.
    /// Separated from execution for testability.
    func buildRequest(
        audio: Data,
        apiKey: String,
        model: String,
        language: String,
        temperature: Float = 0.0,
        diarize: Bool = false,
        contextBias: String = ""
    ) throws -> URLRequest {
        // Validate audio size
        guard audio.count <= Config.maxAudioSizeBytes else {
            throw MistralBatchError.audioTooLarge(size: audio.count)
        }

        let boundary = "----SpeakFlowBoundary\(UUID().uuidString)"

        var request = URLRequest(url: Self.transcriptionEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TranscriptionService.timeout(forDataSize: audio.count)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body matching the Python SDK's AudioTranscriptionRequest:
        //   - model (required)
        //   - file (file upload, WAV format)
        //   - language (optional, boosts accuracy)
        //   - temperature (optional, 0.0 = deterministic)
        //   - diarize (optional, speaker identification)
        var body = Data()

        // model field (required)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(model)\r\n".utf8))

        // language field
        if !language.isEmpty {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8))
            body.append(Data("\(language)\r\n".utf8))
        }

        // temperature field
        if temperature > 0 {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".utf8))
            body.append(Data("\(temperature)\r\n".utf8))
        }

        // diarize field (speaker identification — not compatible with realtime)
        if diarize {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n".utf8))
            body.append(Data("true\r\n".utf8))
        }

        // context_bias field: comma-separated terms to guide recognition (up to 100).
        // Optimised for English; other languages experimental per Mistral API docs.
        let trimmedBias = contextBias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBias.isEmpty {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"context_bias\"\r\n\r\n".utf8))
            body.append(Data("\(trimmedBias)\r\n".utf8))
        }

        // file field (WAV audio data from the recorder)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body
        return request
    }

    /// Build and execute the multipart POST to Mistral's transcription endpoint.
    /// Mirrors the Python SDK's `Transcriptions.complete()` method.
    private func performRequest(
        audio: Data,
        apiKey: String,
        model: String,
        language: String,
        temperature: Float = 0.0,
        diarize: Bool = false,
        contextBias: String = ""
    ) async throws -> String {
        let request = try buildRequest(
            audio: audio,
            apiKey: apiKey,
            model: model,
            language: language,
            temperature: temperature,
            diarize: diarize,
            contextBias: contextBias
        )

        let dataSize = String(format: "%.1f", Double(audio.count) / 1000.0)
        logger.info("Sending \(dataSize)KB to Mistral batch transcription (model: \(model, privacy: .public))")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw MistralBatchError.networkError(urlError.localizedDescription)
        } catch {
            throw MistralBatchError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MistralBatchError.invalidResponse("No HTTP response")
        }

        // Handle errors
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data.prefix(500), encoding: .utf8) ?? ""
            logger.error("Mistral API error HTTP \(http.statusCode): \(bodyText, privacy: .private(mask: .hash))")

            if http.statusCode == 429 {
                throw MistralBatchError.rateLimited
            }
            throw MistralBatchError.httpError(statusCode: http.statusCode, body: bodyText)
        }

        // Parse response — Python SDK model: TranscriptionResponse { text, model, usage, language }
        do {
            let result = try JSONDecoder().decode(MistralTranscriptionResponse.self, from: data)
            logger.info("Transcription complete: \(result.text.prefix(80), privacy: .private(mask: .hash))...")
            return result.text
        } catch {
            // Fallback: try extracting "text" from raw JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text
            }
            throw MistralBatchError.invalidResponse("Failed to decode response: \(error.localizedDescription)")
        }
    }
}

// MARK: - API Key Validation

extension MistralBatchProvider: APIKeyValidatable {
    /// Delegates to the same validation as the realtime provider (both use Mistral API keys).
    public nonisolated func validateAPIKey(_ key: String) async -> String? {
        await MistralProvider.validateMistralAPIKey(key)
    }
}

// MARK: - Response Model

/// Mistral transcription API response.
/// Matches the Python SDK's `TranscriptionResponse` model.
private struct MistralTranscriptionResponse: Decodable {
    let text: String
    let model: String?
    let language: String?
    // usage is present but we don't need it for text extraction
}

// MARK: - Errors

public enum MistralBatchError: Error, LocalizedError {
    case missingApiKey
    case audioTooLarge(size: Int)
    case networkError(String)
    case httpError(statusCode: Int, body: String)
    case rateLimited
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Mistral API key not configured"
        case .audioTooLarge(let size):
            return "Audio too large (\(size / 1_000_000)MB). Maximum is \(Config.maxAudioSizeBytes / 1_000_000)MB."
        case .networkError(let msg): return "Network error: \(msg)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .rateLimited: return "Rate limited — try again shortly"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        }
    }

    /// Whether this error is worth retrying.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .networkError: return true
        case .httpError(let code, _): return code >= 500
        default: return false
        }
    }
}
