import Foundation

/// Applies observability settings to an `ObservabilityStore`, in the order
/// they were requested.
///
/// The store caches its configuration and every component writes through it
/// (hotkey diagnostics included), so a settings change must reach the store
/// as soon as it is made: turning diagnostics off has to stop writes then,
/// not at the next recording or launch.
@MainActor
public final class ObservabilityConfigurator {
    public static let shared = ObservabilityConfigurator(store: .shared)

    private let store: ObservabilityStore
    /// Serial chain: each application waits for the previous one, so rapid
    /// changes cannot land out of order.
    private var tail: Task<Void, Never>?

    init(store: ObservabilityStore) {
        self.store = store
    }

    /// Captures the current settings now and applies them after any
    /// previously requested configuration.
    public func apply(from settings: any SettingsProviding) {
        let enabled = settings.observabilityEnabled
        let verbosity = settings.observabilityVerbosity
        let captureSettingsSnapshot = settings.observabilityCaptureSettingsSnapshot
        let captureSystemContext = settings.observabilityCaptureSystemContext
        let captureTextPayloads = settings.observabilityCaptureTextPayloads
        let previous = tail
        let store = self.store
        tail = Task {
            await previous?.value
            await store.applyConfiguration(
                enabled: enabled,
                verbosity: verbosity,
                captureSettingsSnapshot: captureSettingsSnapshot,
                captureSystemContext: captureSystemContext,
                captureTextPayloads: captureTextPayloads
            )
        }
    }

    /// Waits until every configuration requested so far has been applied.
    public func waitUntilApplied() async {
        await tail?.value
    }
}
