import AVFoundation
import OSLog
import Observation
import SpeakFlowCore

/// Central observable state for the SwiftUI menu bar app.
/// Replaces scattered AppDelegate properties with a single source of truth.
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

    // MARK: - Recording
    var isRecording = false
    var isProcessingFinal = false

    // MARK: - Settings
    var currentHotkey: HotkeyType = .controlOptionD
    var chunkDuration: ChunkDuration = .seconds30
    var skipSilentChunks = true
    var launchAtLogin = false

    // MARK: - Dialogs
    var alertTitle = ""
    var alertMessage = ""
    var alertStyle: AlertStyle = .info

    enum AlertStyle { case info, success, error }

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
    }

    init() { refresh() }
}

import ServiceManagement
