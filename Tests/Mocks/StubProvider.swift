import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

/// A minimal provider stub with controllable `isConfigured` for testing
/// logic that depends on provider availability (e.g. `canStartDictation`).
final class StubProvider: TranscriptionProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let mode: ProviderMode
    var authRequirement: ProviderAuthRequirement { .none }
    var stubbedIsConfigured: Bool

    var isConfigured: Bool { stubbedIsConfigured }

    init(id: String = "stub", displayName: String = "Stub", mode: ProviderMode = .batch, isConfigured: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.stubbedIsConfigured = isConfigured
    }
}
