import Foundation

extension LocalSpeechModel {
    /// A single persisted identifier names the exact model, export, revision and mode.
    public var providerID: String { "local:\(id.rawValue):\(manifest.revision):\(mode.rawValue)" }
}

public struct LocalBatchSpeechProvider: BatchTranscriptionProvider {
    private let lease: LocalSpeechLease
    private let requests: LocalBatchSpeechRequests
    public var id: String { lease.model.providerID }
    public var displayName: String { lease.model.name }
    public let mode = ProviderMode.batch
    public let isConfigured = true
    public var authRequirement: ProviderAuthRequirement { .none }

    public init(lease: LocalSpeechLease) {
        self.lease = lease
        requests = LocalBatchSpeechRequests(lease: lease)
    }
    public func transcribe(audio: Data) async throws -> String { try await requests.transcribe(audio) }
}

/// A batch recording has one native request in flight. Reject overlap before decoding
/// another WAV, so a slow model cannot accumulate an unbounded queue of audio arrays.
private actor LocalBatchSpeechRequests {
    let lease: LocalSpeechLease
    private var busy = false
    init(lease: LocalSpeechLease) { self.lease = lease }
    func transcribe(_ audio: Data) async throws -> String {
        try Task.checkCancellation()
        guard !busy else { throw LocalSpeechRuntimeError.audioBacklog }
        busy = true
        defer { busy = false }
        let samples = try LocalSpeechAudio.batchSamples(audio)
        do { return try await lease.transcribe(samples: samples) } catch { throw localSpeechFailure(error) }
    }
}

/// Prepared before microphone capture. Starting the session does not load or reset a model.
public struct LocalStreamingSpeechProvider: StreamingTranscriptionProvider {
    private let model: LocalSpeechModel
    private let owner: LocalSpeechSessionOwner
    public var id: String { model.providerID }
    public var displayName: String { model.name }
    public let mode = ProviderMode.streaming
    public let isConfigured = true
    public var authRequirement: ProviderAuthRequirement { .none }

    private init(lease: LocalSpeechLease) {
        model = lease.model
        owner = LocalSpeechSessionOwner(session: LocalSpeechSession(lease: lease))
    }
    public static func prepare(lease: LocalSpeechLease) async throws -> LocalStreamingSpeechProvider {
        do {
            try await lease.resetStreaming()
            return LocalStreamingSpeechProvider(lease: lease)
        } catch {
            await lease.release()
            throw localSpeechFailure(error)
        }
    }
    public func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        guard config.sampleRate == 16000, config.encoding == .linear16,
              ["en", "en-us"].contains(config.language.lowercased()), config.model == model.id.rawValue else {
            throw LocalSpeechAudioError.invalidAudio
        }
        return try await owner.start()
    }
    @MainActor public func buildSessionConfig() -> StreamingSessionConfig {
        StreamingSessionConfig(language: "en", sampleRate: 16000, encoding: .linear16,
            interimResults: true, smartFormat: false, endpointingMs: 0, model: model.id.rawValue)
    }
}

private actor LocalSpeechSessionOwner {
    private let session: LocalSpeechSession
    private var started = false
    init(session: LocalSpeechSession) { self.session = session }
    func start() throws -> StreamingSession {
        guard !started else { throw LocalModelError.busy }
        started = true
        return session
    }
}

private actor LocalSpeechSession: StreamingSession {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private let lease: LocalSpeechLease
    private enum State { case open, finalizing, finalized, closed }
    private var state = State.open
    private var previous = ""
    private var audioSamples = 0
    private var finalization: Task<Void, Error>?

    init(lease: LocalSpeechLease) {
        self.lease = lease
        // The latest cumulative partial may replace an older one. Final and close both fit.
        let stream = AsyncStream.makeStream(of: TranscriptionEvent.self, bufferingPolicy: .bufferingNewest(2))
        events = stream.stream
        continuation = stream.continuation
    }
    func sendAudio(_ data: Data) async throws {
        guard state == .open else { throw CancellationError() }
        let samples = try LocalSpeechAudio.streamingSamples(data)
        guard !samples.isEmpty else { return }
        audioSamples += samples.count
        do {
            let text = try await lease.process(samples: samples)
            guard state == .open else { return }
            if text != previous {
                previous = text
                continuation.yield(.interim(TranscriptionResult(transcript: text, duration: Double(audioSamples) / 16000)))
            }
        } catch { throw localSpeechFailure(error) }
    }
    func finalize() async throws {
        if let finalization { try await finalization.value; return }
        guard state == .open else { throw CancellationError() }
        state = .finalizing
        let task = Task { try await self.completeFinalization() }
        finalization = task
        try await task.value
    }
    private func completeFinalization() async throws {
        do {
            let text = try await lease.finishStreaming()
            try Task.checkCancellation()
            guard state == .finalizing else { throw CancellationError() }
            state = .finalized
            continuation.yield(.finalResult(TranscriptionResult(transcript: text,
                duration: Double(audioSamples) / 16000, isFinal: true, speechFinal: true)))
        } catch { throw localSpeechFailure(error) }
    }
    func close() async throws {
        guard state != .closed else { return }
        state = .closed
        finalization?.cancel()
        continuation.yield(.closed)
        continuation.finish()
        await lease.cancelOperations()
    }
    func keepAlive() async throws { }
}

private func localSpeechFailure(_ error: Error) -> Error {
    if error is CancellationError { return CancellationError() }
    if let error = error as? LocalSpeechRuntimeError { return error }
    return LocalSpeechRuntimeError.inferenceFailed
}
