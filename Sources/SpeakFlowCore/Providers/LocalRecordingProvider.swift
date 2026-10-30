import Foundation
import os

/// Verified installation status is updated by the app's explicit store audit.
/// Reading provider readiness never performs I/O, model loading or networking.
public final class LocalSpeechAvailability: Sendable {
    private let ready = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public var isReady: Bool { ready.withLock { $0 } }
    public func setReady(_ value: Bool) { ready.withLock { $0 = value } }
}

public struct PreparedLocalRecording: Sendable {
    public let provider: any TranscriptionProvider
    public let lease: LocalSpeechLease
    public init(provider: any TranscriptionProvider, lease: LocalSpeechLease) {
        self.provider = provider
        self.lease = lease
    }
}

public protocol LocalRecordingPreparing: TranscriptionProvider {
    func prepareRecording() async throws -> PreparedLocalRecording
}

/// The registry entry describes a verified installation. A recording receives its
/// own concrete provider and lease only after local preparation succeeds.
public struct LocalRecordingProvider: LocalRecordingPreparing {
    public let model: LocalSpeechModel
    private let runtime: LocalSpeechRuntime
    private let availability: LocalSpeechAvailability
    public var id: String { model.providerID }
    public var displayName: String { model.name }
    public var mode: ProviderMode { model.mode == .batch ? .batch : .streaming }
    public var isConfigured: Bool { availability.isReady }
    public var authRequirement: ProviderAuthRequirement { .none }

    public init(model: LocalSpeechModel, runtime: LocalSpeechRuntime, availability: LocalSpeechAvailability) {
        self.model = model
        self.runtime = runtime
        self.availability = availability
    }
    public func prepareRecording() async throws -> PreparedLocalRecording {
        guard availability.isReady else { throw LocalSpeechRuntimeError.missingModel }
        let lease = try await runtime.acquire(model)
        do {
            let provider: any TranscriptionProvider
            if model.mode == .batch {
                provider = LocalBatchSpeechProvider(lease: lease)
            } else {
                provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
            }
            try Task.checkCancellation()
            return PreparedLocalRecording(provider: provider, lease: lease)
        } catch {
            await lease.release()
            throw error
        }
    }
}
