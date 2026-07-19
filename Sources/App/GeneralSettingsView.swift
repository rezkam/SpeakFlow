import AppKit
import ServiceManagement
import SwiftUI
import SpeakFlowCore

/// General tab: active model, permissions, activation, behavior, system, and diagnostics.
struct GeneralSettingsView: View {
    @Environment(\.appState) private var state
    @Environment(\.permissionController) private var permissionController
    @Environment(\.recordingController) private var recordingController

    let switchTab: (SettingsTab) -> Void

    private var allPermissionsGranted: Bool {
        state.accessibilityGranted && state.microphoneGranted
    }

    var body: some View {
        let _ = state.refreshVersion
        VStack(alignment: .leading, spacing: 18) {
            banner
            permissionsSection
            activationSection
            behaviorSection
            systemSection
            advancedSection
        }
        .onAppear(perform: autoSelectProviderIfNeeded)
    }

    private var banner: some View {
        let configured = ProviderRegistry.shared.configuredProviders
        let activeProvider = activeConfiguredProvider(from: configured)
        return ActiveModelBanner(
            activeProvider: activeProvider,
            activeModelId: ModelCatalog.activeModelId(for: activeProvider?.id ?? state.activeProviderId, in: state),
            configuredProviders: configured,
            allModels: ModelCatalog.availableModels(for: configured),
            onActivate: { model in ModelCatalog.activate(model, in: state) },
            onManageProviders: { switchTab(.providers) }
        )
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SectionCard(
            "Permissions",
            footer: allPermissionsGranted
                ? "All permissions granted. SpeakFlow is ready to use."
                : "Both permissions are required for SpeakFlow to work."
        ) {
            PermissionRow(
                title: "Accessibility",
                granted: state.accessibilityGranted,
                description: "SpeakFlow needs accessibility permission to type transcribed text directly into any app, like your editor, browser, chat, or notes.",
                action: { permissionController.checkAccessibility() }
            )
            PermissionRow(
                title: "Microphone",
                granted: state.microphoneGranted,
                description: "SpeakFlow needs microphone access to hear your voice. Audio is processed in real time and never stored on disk.",
                action: { permissionController.checkMicrophoneAction() }
            )
        }
    }

    // MARK: - Activation

    private var activationSection: some View {
        SectionCard(
            "Activation",
            footer: "The hotkey starts listening. Hold-to-talk keys record while pressed. Double-tap and toggle keys start or stop on press."
        ) {
            SettingRow(
                "Hotkey",
                description: "Pick a key that does not conflict with anything else you press while typing."
            ) {
                Picker("", selection: hotkeyBinding) {
                    ForEach(HotkeyType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        let footer = """
        Restart on hotkey cancels an in-flight transcription if you press the hotkey again while it is still processing. \
        Hold pending text for keeps the result alive while you tab back to the app you started recording from. \
        If you do not return in time, the text is discarded so it does not surprise you later.
        """
        return SectionCard(
            "Behavior",
            footer: footer
        ) {
            SettingRow(
                "Restart on hotkey",
                description: "Pressing the hotkey while transcription is still processing cancels it and starts a new recording instead of queuing another one."
            ) {
                Toggle("", isOn: state.binding(for: \.hotkeyRestartsRecording))
                    .labelsHidden()
            }
            SettingSliderRow(
                label: "Hold pending text for",
                description: "If you switch apps after recording, wait this long for you to return before discarding the text.",
                value: state.binding(for: \.focusWaitTimeout),
                range: 10...300,
                step: 10,
                formatted: formatTimeout(state.focusWaitTimeout),
                lowLabel: "10 s, discard quickly",
                highLabel: "5 m, wait patiently"
            )
        }
    }

    // MARK: - System

    private var systemSection: some View {
        SectionCard("System") {
            SettingRow(
                "Launch at Login",
                description: "Open SpeakFlow when your Mac starts."
            ) {
                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureCard(
            "Advanced settings",
            subtitle: "Diagnostics and event logging, most people never need these"
        ) {
            SectionCard(
                "Observability",
                footer: "Diagnostics are written as JSONL events to \(ObservabilityStore.defaultPathInfo.eventsFile.path). Only enable text payload capture while debugging because transcribed text is sensitive."
            ) {
                SettingRow(
                    "Write diagnostic events",
                    description: "Record JSONL events describing pipeline state, latencies, and errors. Required for the capture options below."
                ) {
                    Toggle("", isOn: state.binding(for: \.observabilityEnabled))
                        .labelsHidden()
                }

                if state.observabilityEnabled {
                    SettingRow(
                        "Verbosity",
                        description: "How much detail to write per event."
                    ) {
                        Picker("", selection: state.binding(for: \.observabilityVerbosity)) {
                            Text("Minimal, warnings and errors only").tag(ObservabilityVerbosity.minimal)
                            Text("Standard, pipeline events").tag(ObservabilityVerbosity.standard)
                            Text("Verbose, full debug detail").tag(ObservabilityVerbosity.verbose)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingRow(
                        "Include settings snapshots",
                        description: "Attach a copy of your settings to each event. This makes bug reports reproducible."
                    ) {
                        Toggle("", isOn: state.binding(for: \.observabilityCaptureSettingsSnapshot))
                            .labelsHidden()
                    }
                    SettingRow(
                        "Include runtime context",
                        description: "Attach safe runtime details like OS version and app mode."
                    ) {
                        Toggle("", isOn: state.binding(for: \.observabilityCaptureSystemContext))
                            .labelsHidden()
                    }
                    SettingRow(
                        "Include transcript text",
                        description: "Write the actual transcribed text into the log. Only enable temporarily."
                    ) {
                        Toggle("", isOn: state.binding(for: \.observabilityCaptureTextPayloads))
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var hotkeyBinding: Binding<HotkeyType> {
        Binding(
            get: { state.currentHotkey },
            set: { newValue in
                HotkeySettings.shared.currentHotkey = newValue
                recordingController.setupHotkey()
                state.refresh()
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    AppState.shared.showBanner("Could not update login item, check System Settings", style: .error)
                }
                state.refresh()
            }
        )
    }

    // MARK: - Helpers

    private func autoSelectProviderIfNeeded() {
        let configured = ProviderRegistry.shared.configuredProviders
        guard !configured.isEmpty,
              !configured.contains(where: { $0.id == state.activeProviderId }) else { return }
        ProviderSettings.shared.activeProviderId = configured[0].id
        state.refresh()
    }

    private func activeConfiguredProvider(from configured: [any TranscriptionProvider]) -> (any TranscriptionProvider)? {
        configured.first { $0.id == state.activeProviderId } ?? configured.first
    }

    private func formatTimeout(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        if minutes > 0 && remainingSeconds > 0 { return "\(minutes)m \(remainingSeconds)s" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(remainingSeconds)s"
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let description: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? Theme.green : Theme.orange)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if !granted {
                    Button("Grant Access") { action() }
                        .controlSize(.small)
                }
            }

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .padding(.leading, 30)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(Divider().background(Theme.line), alignment: .bottom)
    }
}
