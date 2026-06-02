import SwiftUI

/// Sidebar navigation tabs for the main settings window.
///
/// The raw value for Providers remains "accounts" so any saved selection from
/// the older Accounts tab continues to resolve.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case providers = "accounts"
    case statistics
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .transcription: "Transcription"
        case .providers: "Providers"
        case .statistics: "Statistics"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .transcription: "waveform"
        case .providers: "cloud"
        case .statistics: "chart.bar"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Permissions, hotkey, and system behavior"
        case .transcription: "Choose a model and tune how it transcribes"
        case .providers: "Connect accounts and pick the active model"
        case .statistics: "Your dictation usage at a glance"
        case .about: "SpeakFlow version and credits"
        }
    }
}
