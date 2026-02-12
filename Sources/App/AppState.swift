import AVFoundation
import OSLog
import Observation
import SwiftUI
import SpeakFlowCore

/// Central observable state for the app.
/// Single source of truth that SwiftUI views observe for reactive updates.
///
/// Provider information is delegated to `ProviderRegistry` — no hardcoded
/// provider lists or per-provider booleans. Adding a new provider requires
/// only registering it in the registry; AppState adapts automatically.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: - Permissions
    var accessibilityGranted = false
    var microphoneGranted = false

    // MARK: - Provider
    var activeProviderId: String = ProviderId.chatGPT

    var isStreamingProvider: Bool {
        ProviderRegistry.shared.provider(for: activeProviderId)?.mode == .streaming
    }

    /// Whether a specific provider is configured and ready to use.
    func isProviderConfigured(_ id: String) -> Bool {
        ProviderRegistry.shared.isProviderConfigured(id)
    }

    // MARK: - Streaming Settings
    var deepgramInterimResults = true
    var deepgramSmartFormat = true
    var deepgramEndpointingMs = 300
    var deepgramModel = "nova-3"
    var deepgramLanguage = "en-US"
    var streamingAutoEndEnabled = false

    // MARK: - Recording
    var isRecording = false
    var isProcessingFinal = false

    // MARK: - Settings
    var currentHotkey: HotkeyType = .controlOptionD
    var chunkDuration: ChunkDuration = .seconds30
    var skipSilentChunks = true
    var launchAtLogin = false

    // MARK: - Audio / VAD Settings
    var vadEnabled = true
    var vadThreshold: Float = Config.vadThreshold
    var autoEndEnabled = true
    var autoEndSilenceDuration: Double = Config.autoEndSilenceDuration
    var minSpeechRatio: Float = Config.minSpeechRatio

    // MARK: - Inline Banner (replaces popup alerts)
    var bannerMessage = ""
    var bannerStyle: BannerStyle = .info
    var bannerVisible = false

    enum BannerStyle { case info, success, error }

    private var bannerDismissTask: Task<Void, Never>?

    /// Show a temporary inline banner in the settings window.
    func showBanner(_ message: String, style: BannerStyle = .info, duration: Double = 4) {
        bannerDismissTask?.cancel()
        bannerMessage = message
        bannerStyle = style
        bannerVisible = true
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.bannerVisible = false
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerVisible = false
    }

    // MARK: - Settings Binding

    /// Creates a two-way Binding that reads from `Settings.shared` and writes back + refreshes.
    /// Eliminates boilerplate binding properties in settings views.
    func binding<T>(for keyPath: ReferenceWritableKeyPath<SpeakFlowCore.Settings, T>) -> Binding<T> {
        Binding(
            get: { SpeakFlowCore.Settings.shared[keyPath: keyPath] },
            set: { newValue in
                SpeakFlowCore.Settings.shared[keyPath: keyPath] = newValue
                self.refresh()
            }
        )
    }

    // MARK: - Refresh

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        activeProviderId = ProviderSettings.shared.activeProviderId
        currentHotkey = HotkeySettings.shared.currentHotkey
        chunkDuration = Settings.shared.chunkDuration
        skipSilentChunks = Settings.shared.skipSilentChunks
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        vadEnabled = Settings.shared.vadEnabled
        vadThreshold = Settings.shared.vadThreshold
        autoEndEnabled = Settings.shared.autoEndEnabled
        autoEndSilenceDuration = Settings.shared.autoEndSilenceDuration
        minSpeechRatio = Settings.shared.minSpeechRatio
        deepgramInterimResults = Settings.shared.deepgramInterimResults
        deepgramSmartFormat = Settings.shared.deepgramSmartFormat
        deepgramEndpointingMs = Settings.shared.deepgramEndpointingMs
        deepgramModel = Settings.shared.deepgramModel
        deepgramLanguage = Settings.shared.deepgramLanguage
        streamingAutoEndEnabled = Settings.shared.streamingAutoEndEnabled
    }

    init() { refresh() }
}

import ServiceManagement
