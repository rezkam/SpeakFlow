import SwiftUI
import SpeakFlowCore

@main
struct SpeakFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        // Menu bar icon + dropdown menu (replaces NSStatusItem + NSMenu)
        MenuBarExtra {
            MenuView()
                .environment(appState)
        } label: {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
        }

        // Dialog windows (replaces DialogPresenter / NSPanel)
        Window("Statistics", id: "statistics") {
            StatisticsWindowView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Deepgram API Key", id: "deepgram-key") {
            DeepgramApiKeyWindowView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Login", id: "login") {
            LoginWindowView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Alert", id: "alert") {
            AlertWindowView()
                .environment(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
