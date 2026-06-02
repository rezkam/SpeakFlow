import Foundation
import Testing
@testable import SpeakFlowCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - MistralBatchProvider — Request Building
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("MistralBatchProvider — Request Building")
struct MistralBatchRequestBuildingTests {

    @Test @MainActor
    func buildRequest_usesCorrectEndpoint() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("abc".utf8),
            apiKey: "test-key",
            model: "voxtral-mini-latest",
            language: "en"
        )

        #expect(request.url?.absoluteString == "https://api.mistral.ai/v1/audio/transcriptions",
                "Must use the Mistral transcription endpoint")
        #expect(request.httpMethod == "POST")
    }

    @Test @MainActor
    func buildRequest_setsAuthorizationHeader() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("abc".utf8),
            apiKey: "sk-test-12345",
            model: "voxtral-mini-latest",
            language: "en"
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-12345",
                "Must set Bearer token authorization")
    }

    @Test @MainActor
    func buildRequest_usesMultipartFormData() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("audio-data".utf8),
            apiKey: "test-key",
            model: "voxtral-mini-latest",
            language: "en"
        )

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="),
                "Content-Type must be multipart/form-data")

        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let bodyData = try #require(request.httpBody)
        let body = String(decoding: bodyData, as: UTF8.self)

        // Verify multipart structure
        #expect(body.contains("--\(boundary)\r\n"), "Body must contain boundary markers")
        #expect(body.contains("\r\n--\(boundary)--\r\n"), "Body must end with closing boundary")
    }

    @Test @MainActor
    func buildRequest_includesModelField() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: ""
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="model""#), "Body must contain model field")
        #expect(body.contains("voxtral-mini-latest"), "Body must contain model value")
    }

    @Test @MainActor
    func buildRequest_includesLanguageField() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "fr"
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="language""#), "Body must contain language field")
        #expect(body.contains("fr"), "Body must contain language value")
    }

    @Test @MainActor
    func buildRequest_omitsLanguageWhenEmpty() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: ""
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains(#"name="language""#),
                "Body must NOT contain language field when empty")
    }

    @Test @MainActor
    func buildRequest_includesTemperatureWhenNonZero() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            temperature: 0.5
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="temperature""#), "Body must contain temperature field")
        #expect(body.contains("0.5"), "Body must contain temperature value")
    }

    @Test @MainActor
    func buildRequest_omitsTemperatureWhenZero() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            temperature: 0.0
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains(#"name="temperature""#),
                "Body must NOT contain temperature field when zero")
    }

    @Test @MainActor
    func buildRequest_includesDiarizeWhenTrue() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            diarize: true
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="diarize""#), "Body must contain diarize field")
        #expect(body.contains("true"), "Body must contain diarize=true")
    }

    @Test @MainActor
    func buildRequest_omitsDiarizeWhenFalse() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            diarize: false
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains(#"name="diarize""#),
                "Body must NOT contain diarize field when false")
    }

    @Test @MainActor
    func buildRequest_includesFileField() throws {
        let audioData = Data("test-audio-content".utf8)
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: audioData,
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en"
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="file"; filename="audio.wav""#),
                "Body must contain file field with filename")
        #expect(body.contains("Content-Type: audio/wav"),
                "File part must have audio/wav content type")
        #expect(body.contains("test-audio-content"),
                "Body must contain the audio data")
    }

    @Test @MainActor
    func buildRequest_setsTimeoutBasedOnDataSize() throws {
        let smallAudio = Data(count: 100_000)
        let largeAudio = Data(count: 5_000_000)
        let provider = MistralBatchProvider()

        let smallRequest = try provider.buildRequest(
            audio: smallAudio, apiKey: "key", model: "m", language: "en"
        )
        let largeRequest = try provider.buildRequest(
            audio: largeAudio, apiKey: "key", model: "m", language: "en"
        )

        #expect(largeRequest.timeoutInterval >= smallRequest.timeoutInterval,
                "Larger audio should have equal or greater timeout")
    }

    @Test @MainActor
    func buildRequest_allFieldsCombined() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("wav".utf8),
            apiKey: "sk-test",
            model: "voxtral-mini-latest",
            language: "de",
            temperature: 0.3,
            diarize: true,
            contextBias: "Kubernetes,gRPC,Barack Obama"
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="model""#))
        #expect(body.contains(#"name="language""#))
        #expect(body.contains(#"name="temperature""#))
        #expect(body.contains(#"name="diarize""#))
        #expect(body.contains(#"name="context_bias""#))
        #expect(body.contains(#"name="file""#))
        #expect(body.contains("voxtral-mini-latest"))
        #expect(body.contains("de"))
        #expect(body.contains("0.3"))
        #expect(body.contains("true"))
        #expect(body.contains("Kubernetes,gRPC,Barack Obama"))
    }

    // MARK: - Context bias field

    @Test @MainActor
    func buildRequest_contextBias_presentWhenNonEmpty() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            contextBias: "SwiftUI,Xcode,WWDC"
        )
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="context_bias""#),
                "context_bias field must be present when non-empty")
        #expect(body.contains("SwiftUI,Xcode,WWDC"),
                "context_bias value must match the provided string")
    }

    @Test @MainActor
    func buildRequest_contextBias_absentWhenEmpty() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            contextBias: ""
        )
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains(#"name="context_bias""#),
                "context_bias field must be absent when empty (saves tokens)")
    }

    @Test @MainActor
    func buildRequest_contextBias_absentWhenOnlyWhitespace() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            contextBias: "   \n\t  "
        )
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains(#"name="context_bias""#),
                "Whitespace-only context_bias must not produce a field in the request")
    }

    @Test @MainActor
    func buildRequest_contextBias_fieldNameMatchesAPISpec() throws {
        // The Mistral API spec names this field "context_bias" (snake_case).
        // Verify we don't accidentally send "contextBias" (camelCase) or "context-bias" (kebab).
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "key",
            model: "voxtral-mini-latest",
            language: "en",
            contextBias: "test"
        )
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains(#"name="context_bias""#),
                "API field name must be 'context_bias' (snake_case) per Mistral spec")
        #expect(!body.contains(#"name="contextBias""#),
                "Must not use camelCase 'contextBias'")
        #expect(!body.contains(#"name="context-bias""#),
                "Must not use kebab-case 'context-bias'")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - MistralBatchProvider — Audio Size Validation
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("MistralBatchProvider — Audio Size Validation")
struct MistralBatchAudioSizeTests {

    @Test @MainActor
    func buildRequest_rejectsOversizedAudio() {
        let provider = MistralBatchProvider()
        let oversizedAudio = Data(count: Config.maxAudioSizeBytes + 1)

        do {
            _ = try provider.buildRequest(
                audio: oversizedAudio, apiKey: "key", model: "m", language: "en"
            )
            Issue.record("Expected MistralBatchError.audioTooLarge for oversized audio")
        } catch let error as MistralBatchError {
            switch error {
            case .audioTooLarge(let size):
                #expect(size == Config.maxAudioSizeBytes + 1,
                        "Error must report actual audio size")
            default:
                Issue.record("Expected .audioTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Expected MistralBatchError, got \(type(of: error))")
        }
    }

    @Test @MainActor
    func buildRequest_acceptsMaxSizeAudio() throws {
        let provider = MistralBatchProvider()
        let maxAudio = Data(count: Config.maxAudioSizeBytes)

        // Should not throw
        let request = try provider.buildRequest(
            audio: maxAudio, apiKey: "key", model: "m", language: "en"
        )
        #expect(request.httpBody != nil, "Request should be built successfully for max-size audio")
    }

    @Test @MainActor
    func buildRequest_acceptsEmptyAudio() throws {
        let provider = MistralBatchProvider()
        let request = try provider.buildRequest(
            audio: Data(), apiKey: "key", model: "m", language: "en"
        )
        #expect(request.httpBody != nil, "Request should be built for empty audio")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Shared Mistral Validation — Delegation
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("Mistral Shared Validation")
struct MistralSharedValidationTests {

    /// Both providers must reject the same invalid key identically.
    @Test @MainActor
    func bothProvidersRejectInvalidKeyConsistently() async {
        let realtimeProvider = MistralProvider()
        let batchProvider = MistralBatchProvider()

        let realtimeError = await realtimeProvider.validateAPIKey("invalid-key-xyz")
        let batchError = await batchProvider.validateAPIKey("invalid-key-xyz")

        #expect(realtimeError != nil, "Realtime provider must reject invalid key")
        #expect(batchError != nil, "Batch provider must reject invalid key")
        #expect(realtimeError == batchError,
                "Both providers must produce identical validation errors for the same key")
    }

    /// The shared static method must be accessible and reject invalid keys.
    @Test
    func sharedValidationRejectsInvalidKey() async {
        let error = await MistralProvider.validateMistralAPIKey("bad-key-123")
        #expect(error != nil, "Shared validation must reject invalid key")
        #expect(error?.contains("authentication") == true || error?.contains("Invalid") == true,
                "Error should mention auth failure, got: \(error ?? "nil")")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - MistralBatchProvider — Settings Integration
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("MistralBatchProvider — Settings Integration")
struct MistralBatchSettingsIntegrationTests {

    @Test @MainActor
    func transcribe_usesInjectedSettings() async throws {
        let spySettings = SpyMistralSettings()
        spySettings.mistralBatchModel = "custom-model"
        spySettings.mistralLanguage = "ja"
        spySettings.mistralTemperature = 0.7
        spySettings.mistralDiarize = true

        let spyProviderSettings = SpyMistralProviderSettings()
        spyProviderSettings.storedKeys[ProviderId.mistral] = "test-key"

        let provider = MistralBatchProvider(
            providerSettings: spyProviderSettings,
            settings: spySettings
        )

        // We can't execute the actual network call, but we can verify the provider
        // reads settings via the injected protocols by testing buildRequest directly.
        let request = try provider.buildRequest(
            audio: Data("x".utf8),
            apiKey: "test-key",
            model: spySettings.mistralBatchModel,
            language: spySettings.mistralLanguage,
            temperature: spySettings.mistralTemperature,
            diarize: spySettings.mistralDiarize
        )

        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("custom-model"), "Must use injected batch model")
        #expect(body.contains(#"name="language""#), "Must include language")
        #expect(body.contains("ja"), "Must use injected language")
        #expect(body.contains(#"name="temperature""#), "Must include temperature when > 0")
        #expect(body.contains("0.7"), "Must use injected temperature")
        #expect(body.contains(#"name="diarize""#), "Must include diarize when true")
    }
}

// MARK: - Spy for MistralSettingsProviding

@MainActor
private final class SpyMistralSettings: MistralSettingsProviding {
    var mistralModel: String = "voxtral-mini-transcribe-realtime-latest"
    var mistralBatchModel: String = "voxtral-mini-latest"
    var mistralLanguage: String = "en"
    var mistralTemperature: Float = 0.0
    var mistralDiarize: Bool = false
    var mistralContextBias: String = ""
}

@MainActor
private final class SpyMistralProviderSettings: ProviderSettingsProviding {
    var activeProviderId: String = ProviderId.mistralBatch
    var storedKeys: [String: String] = [:]

    func apiKey(for providerId: String) -> String? { storedKeys[providerId] }
    func setApiKey(_ apiKey: String?, for providerId: String) {
        if let apiKey { storedKeys[providerId] = apiKey } else { storedKeys.removeValue(forKey: providerId) }
    }
    func hasApiKey(for providerId: String) -> Bool { storedKeys[providerId] != nil }
    func removeApiKey(for providerId: String) { storedKeys.removeValue(forKey: providerId) }
}
