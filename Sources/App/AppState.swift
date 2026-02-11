import AVFoundation
import OSLog
import Observation
import SpeakFlowCore

// MARK: - Provider Descriptor

/// Describes a transcription provider and its mode.
/// Add new entries here when integrating additional providers.
enum ProviderMode: String { case batch, streaming }

struct ProviderInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let mode: ProviderMode

    var displayName: String {
        let modeLabel = mode == .streaming ? "Streaming" : "Batch"
        return "\(name) — \(modeLabel)"
    }

    /// All known providers, in display order.
    static let all: [ProviderInfo] = [
        ProviderInfo(id: "gpt", name: "ChatGPT", mode: .batch),
        ProviderInfo(id: "deepgram", name: "Deepgram", mode: .streaming),
    ]
}

/// Central observable state for the app.
/// Single source of truth that SwiftUI views observe for reactive updates.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: - Permissions
    var accessibilityGranted = false
    var microphoneGranted = false

    // MARK: - Accounts
    var isLoggedIn = false
    var hasDeepgramKey = false

    // MARK: - Provider
    var activeProviderId: String = "gpt"
    var isStreamingProvider: Bool {
        ProviderInfo.all.first(where: { $0.id == activeProviderId })?.mode == .streaming
    }

    /// Providers that the user has configured (logged in / has API key).
    var configuredProviders: [ProviderInfo] {
        ProviderInfo.all.filter { isProviderConfigured($0.id) }
    }

    func isProviderConfigured(_ id: String) -> Bool {
        switch id {
        case "gpt": return isLoggedIn
        case "deepgram": return hasDeepgramKey
        default: return false
        }
    }

    // MARK: - Deepgram Settings
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

    // MARK: - Refresh

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        isLoggedIn = OpenAICodexAuth.isLoggedIn
        hasDeepgramKey = ProviderSettings.shared.hasApiKey(for: "deepgram")
        activeProviderId = ProviderSettings.shared.activeProviderId
        currentHotkey = HotkeySettings.shared.currentHotkey
        chunkDuration = Settings.shared.chunkDuration
        skipSilentChunks = Settings.shared.skipSilentChunks
        launchAtLogin = (try? SMAppService.mainApp.status == .enabled) ?? false
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
