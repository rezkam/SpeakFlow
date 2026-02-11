import SwiftUI

/// Sidebar navigation tabs for the main settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case accounts
    case statistics
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .transcription: "Transcription"
        case .accounts: "Providers"
        case .statistics: "Statistics"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .transcription: "waveform"
        case .accounts: "person.crop.circle"
        case .statistics: "chart.bar"
        case .about: "info.circle"
        }
    }
}
