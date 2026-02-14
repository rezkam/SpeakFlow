import SwiftUI
import SpeakFlowCore

/// Unified transcription settings: provider selection on top, provider-specific
/// audio/API settings below. Streaming and batch modes show different sections.
struct TranscriptionSettingsView: View {
    @Environment(\.appState) private var state

    var body: some View {
        // Read refreshVersion so the view re-evaluates when provider configuration changes
        let _ = state.refreshVersion
        let configured = ProviderRegistry.shared.configuredProviders

        Form {
            // MARK: - Provider Selection (only shown when multiple providers are configured)

            if configured.count > 1 {
                Section {
                    Picker("Transcription Provider", selection: providerBinding) {
                        ForEach(configured, id: \.id) { provider in
                            Text(provider.providerDisplayName).tag(provider.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Provider")
                } footer: {
                    Text("Batch providers record audio and transcribe after each chunk. Streaming providers transcribe in real-time as you speak.")
                }
            } else if configured.isEmpty {
                Section {
                    Label(
                        "Set up a provider in the Accounts tab to configure transcription settings.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                } header: {
                    Text("Provider")
                }
            }

            // MARK: - Provider-Specific Settings (only when active provider is configured)

            if !configured.isEmpty {
                if state.isStreamingProvider {
                    streamingSettings
                } else {
                    batchSettings
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
        .onAppear {
            // Auto-select the only configured provider when current selection is unconfigured
            let configured = ProviderRegistry.shared.configuredProviders
            if !configured.isEmpty, !configured.contains(where: { $0.id == state.activeProviderId }) {
                ProviderSettings.shared.activeProviderId = configured[0].id
                state.refresh()
            }
        }
    }

    // MARK: - Provider

    private var providerBinding: Binding<String> {
        Binding(
            get: { state.activeProviderId },
            set: { newValue in
                ProviderSettings.shared.activeProviderId = newValue
                state.refresh()
            }
        )
    }

    // MARK: - Streaming Settings (Deepgram)

    @ViewBuilder
    private var streamingSettings: some View {
        Section {
            Toggle("Show Interim Results", isOn: state.binding(for: \.deepgramInterimResults))
            Toggle("Smart Formatting", isOn: state.binding(for: \.deepgramSmartFormat))
        } header: {
            Text("Real-Time Options")
        } footer: {
            Text("Interim results show partial text as you speak, refining in real-time. Smart formatting adds punctuation and capitalization automatically.")
        }

        Section {
            SettingSlider(
                title: "Endpointing",
                displayValue: "\(state.deepgramEndpointingMs) ms",
                value: deepgramEndpointingBinding,
                range: 100...3000, step: 100,
                lowLabel: "100 ms — fast response",
                highLabel: "3000 ms — waits for pauses"
            )
        } header: {
            Text("Utterance Detection")
        } footer: {
            Text("""
            Controls how quickly Deepgram detects the end of an utterance. \
            Lower values give faster responses but may split mid-sentence. \
            Higher values wait longer for natural pauses. Default: 300 ms.
            """)
        }

        Section {
            Picker("Model", selection: state.binding(for: \.deepgramModel)) {
                Text("Nova 3").tag("nova-3")
                Text("Nova 2").tag("nova-2")
            }
            .pickerStyle(.menu)

            Picker("Language", selection: state.binding(for: \.deepgramLanguage)) {
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Portuguese").tag("pt")
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("Chinese").tag("zh")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Deepgram API")
        } footer: {
            Text("Nova 3 is the latest model with the best accuracy. Language selection determines the transcription language sent to the Deepgram API.")
        }

        Section {
            Toggle("Auto-End on Silence", isOn: state.binding(for: \.streamingAutoEndEnabled))

            if state.streamingAutoEndEnabled {
                SettingSlider(
                    title: "Silence Duration",
                    displayValue: String(format: "%.0fs", state.autoEndSilenceDuration),
                    value: state.binding(for: \.autoEndSilenceDuration),
                    range: 3...30, step: 1,
                    lowLabel: "3s — quick stop",
                    highLabel: "30s — tolerates long pauses"
                )
            }
        } header: {
            Text("Auto-End")
        } footer: {
            Text("""
            Disabled by default for streaming. When enabled, recording stops \
            after the specified silence period. In streaming mode, text is already \
            inserted in real-time, so you can simply press the hotkey to stop when finished.
            """)
        }
    }

    // MARK: - Batch Settings (ChatGPT)

    @ViewBuilder
    private var batchSettings: some View {
        Section {
            Picker("Chunk Duration", selection: state.binding(for: \.chunkDuration)) {
                ForEach(ChunkDuration.allCases, id: \.self) { duration in
                    Text(duration.displayName).tag(duration)
                }
            }
            .pickerStyle(.menu)

            Toggle("Skip Silent Chunks", isOn: state.binding(for: \.skipSilentChunks))
        } header: {
            Text("Recording")
        } footer: {
            Text("Chunk duration controls how often audio is sent for transcription. Skip silent chunks saves API costs by not sending audio with no speech detected.")
        }

        Section {
            Toggle("Enable Voice Activity Detection", isOn: state.binding(for: \.vadEnabled))

            if state.vadEnabled {
                SettingSlider(
                    title: "VAD Sensitivity",
                    displayValue: String(format: "%.0f%%", state.vadThreshold * 100),
                    value: floatBinding(for: \.vadThreshold),
                    range: 0.05...0.50, step: 0.05,
                    lowLabel: "More sensitive",
                    highLabel: "Stricter filtering"
                )
            }
        } header: {
            Text("Voice Activity Detection")
        } footer: {
            Text("VAD analyzes audio in real time to detect when you are speaking. Only segments containing speech are sent to the transcription service. Default: 15%.")
        }

        Section {
            Toggle("Auto-End Recording on Silence", isOn: state.binding(for: \.autoEndEnabled))

            if state.autoEndEnabled {
                SettingSlider(
                    title: "Silence Duration",
                    displayValue: String(format: "%.0fs", state.autoEndSilenceDuration),
                    value: state.binding(for: \.autoEndSilenceDuration),
                    range: 3...30, step: 1,
                    lowLabel: "3s — quick stop",
                    highLabel: "30s — tolerates long pauses"
                )
            }
        } header: {
            Text("Auto-End")
        } footer: {
            Text("When enabled, recording automatically stops after the specified silence period. Default: 5s.")
        }

        Section {
            SettingSlider(
                title: "Minimum Speech Ratio",
                displayValue: String(format: "%.0f%%", state.minSpeechRatio * 100),
                value: floatBinding(for: \.minSpeechRatio),
                range: 0.01...0.10, step: 0.01,
                lowLabel: "1% — very sensitive",
                highLabel: "10% — requires more speech"
            )
        } header: {
            Text("Speech Detection")
        } footer: {
            Text("Minimum percentage of a chunk that must contain speech before it is sent for transcription. Default: 1%.")
        }
    }

    // MARK: - Special-Case Bindings

    /// Endpointing requires Double↔Int conversion for the Slider.
    private var deepgramEndpointingBinding: Binding<Double> {
        Binding(
            get: { Double(state.deepgramEndpointingMs) },
            set: { newValue in
                Settings.shared.deepgramEndpointingMs = Int(newValue)
                state.refresh()
            }
        )
    }

    /// Bridges a `Float` setting to the `Double` binding that `SettingSlider` expects.
    private func floatBinding(
        for keyPath: ReferenceWritableKeyPath<SpeakFlowCore.Settings, Float>
    ) -> Binding<Double> {
        Binding(
            get: { Double(SpeakFlowCore.Settings.shared[keyPath: keyPath]) },
            set: { SpeakFlowCore.Settings.shared[keyPath: keyPath] = Float($0); state.refresh() }
        )
    }
}

// MARK: - Reusable Slider Component

/// A labeled slider with title, formatted value display, and range hint labels.
private struct SettingSlider: View {
    let title: String
    let displayValue: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let lowLabel: String
    let highLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(displayValue)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
