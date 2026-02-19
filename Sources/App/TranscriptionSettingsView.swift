import SwiftUI
import SpeakFlowCore

/// Unified transcription settings: provider selection on top, provider-specific
/// audio/API settings below. Streaming and batch modes share reusable sections;
/// each provider only adds its own model/language picker.
struct TranscriptionSettingsView: View {
    @Environment(\.appState) private var state

    var body: some View {
        // Read refreshVersion so the view re-evaluates when provider configuration changes
        let _ = state.refreshVersion
        let configured = ProviderRegistry.shared.configuredProviders

        Form {
            // MARK: - Provider Selection

            providerSelectionSection(configured: configured)

            // MARK: - Provider-Specific + Shared Settings

            if !configured.isEmpty {
                let activeMode = ProviderRegistry.shared.provider(for: state.activeProviderId)?.mode

                if activeMode == .streaming {
                    streamingProviderSettings
                } else {
                    batchProviderSettings
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
        .onAppear {
            autoSelectProvider()
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Provider Selection
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private func providerSelectionSection(configured: [any TranscriptionProvider]) -> some View {
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
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { state.activeProviderId },
            set: { newValue in
                ProviderSettings.shared.activeProviderId = newValue
                state.refresh()
            }
        )
    }

    private func autoSelectProvider() {
        let configured = ProviderRegistry.shared.configuredProviders
        if !configured.isEmpty, !configured.contains(where: { $0.id == state.activeProviderId }) {
            ProviderSettings.shared.activeProviderId = configured[0].id
            state.refresh()
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Streaming Provider Settings
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Settings for streaming providers (Deepgram, Mistral Realtime).
    /// Layout: Provider-specific API section → Shared auto-end section.
    @ViewBuilder
    private var streamingProviderSettings: some View {
        // Provider-specific API settings
        switch state.activeProviderId {
        case ProviderId.deepgram:   deepgramAPISection
        case ProviderId.mistral:    mistralRealtimeAPISection
        default:                    EmptyView()
        }

        // Deepgram has its own streaming-specific options
        if state.activeProviderId == ProviderId.deepgram {
            deepgramStreamingOptionsSection
        }

        // Shared: streaming auto-end
        streamingAutoEndSection
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Batch Provider Settings
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Settings for batch providers (ChatGPT, Mistral Batch).
    /// Layout: Shared recording → Provider-specific API → Shared VAD → Shared auto-end → Speech detection.
    @ViewBuilder
    private var batchProviderSettings: some View {
        // Shared: recording chunk settings (all batch providers)
        batchRecordingSection

        // Provider-specific API settings
        switch state.activeProviderId {
        case ProviderId.mistralBatch:   mistralBatchAPISection
        default:                        EmptyView()  // ChatGPT has no extra API settings
        }

        // Shared: VAD (all batch providers)
        vadSection

        // Shared: auto-end (all batch providers)
        batchAutoEndSection

        // Shared: speech detection threshold (all batch providers)
        speechDetectionSection
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Shared Sections (Batch)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Chunk duration + silent chunk skipping. Used by all batch providers.
    private var batchRecordingSection: some View {
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
    }

    /// VAD toggle + sensitivity. Used by all batch providers.
    private var vadSection: some View {
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
    }

    /// Auto-end for batch mode (enabled by default). Used by all batch providers.
    private var batchAutoEndSection: some View {
        Section {
            Toggle("Auto-End Recording on Silence", isOn: state.binding(for: \.autoEndEnabled))

            if state.autoEndEnabled {
                silenceDurationSlider
            }
        } header: {
            Text("Auto-End")
        } footer: {
            Text("When enabled, recording automatically stops after the specified silence period. Default: 5s.")
        }
    }

    /// Speech detection ratio. Used by all batch providers.
    private var speechDetectionSection: some View {
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Shared Sections (Streaming)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Auto-end for streaming mode (disabled by default). Used by all streaming providers.
    private var streamingAutoEndSection: some View {
        Section {
            Toggle("Auto-End on Silence", isOn: state.binding(for: \.streamingAutoEndEnabled))

            if state.streamingAutoEndEnabled {
                silenceDurationSlider
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

    /// Reusable silence duration slider (used by both batch and streaming auto-end).
    private var silenceDurationSlider: some View {
        SettingSlider(
            title: "Silence Duration",
            displayValue: String(format: "%.0fs", state.autoEndSilenceDuration),
            value: state.binding(for: \.autoEndSilenceDuration),
            range: 3...30, step: 1,
            lowLabel: "3s — quick stop",
            highLabel: "30s — tolerates long pauses"
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Provider-Specific API Sections
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Deepgram-specific: model + language picker.
    private var deepgramAPISection: some View {
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
    }

    /// Deepgram-specific: interim results, smart formatting, endpointing.
    private var deepgramStreamingOptionsSection: some View {
        Group {
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
        }
    }

    /// Mistral Realtime: model + language.
    private var mistralRealtimeAPISection: some View {
        Section {
            Picker("Model", selection: state.binding(for: \.mistralModel)) {
                Text("Voxtral Mini Transcribe (2602)").tag("voxtral-mini-transcribe-realtime-2602")
            }
            .pickerStyle(.menu)

            mistralLanguagePicker(includeAutoDetect: true)
        } header: {
            Text("Mistral API")
        } footer: {
            Text("Voxtral Mini Transcribe delivers low-latency live transcription. Setting a language boosts accuracy; leave on Auto-Detect to let the model identify the language. $0.006/min.")
        }
    }

    /// Mistral Batch: model + language + temperature + diarization + context bias.
    @ViewBuilder
    private var mistralBatchAPISection: some View {
        // Core API settings
        Section {
            Picker("Model", selection: state.binding(for: \.mistralBatchModel)) {
                Text("Voxtral Mini (voxtral-mini-latest)").tag("voxtral-mini-latest")
            }
            .pickerStyle(.menu)

            mistralLanguagePicker(includeAutoDetect: true)

            SettingSlider(
                title: "Temperature",
                displayValue: String(format: "%.1f", state.mistralTemperature),
                value: mistralTemperatureBinding,
                range: 0...1, step: 0.1,
                lowLabel: "0 — deterministic",
                highLabel: "1.0 — more varied"
            )
        } header: {
            Text("Mistral API")
        } footer: {
            Text("Voxtral Mini Transcribe processes each audio chunk after recording. Temperature 0 gives deterministic, consistent results. $0.003/min.")
        }

        // Speaker diarization (incompatible with language auto-detect warning)
        Section {
            Toggle("Speaker Diarization", isOn: state.binding(for: \.mistralDiarize))
        } header: {
            Text("Speaker Identification")
        } footer: {
            Text("Identifies who is speaking in each segment. Requires language to be set — diarization does not work with Auto-Detect. Best with voxtral-mini-latest (voxtral-mini-2602 model).")
        }

        // Context bias (vocabulary hints)
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context Bias")
                    .font(.body)
                TextEditor(text: state.binding(for: \.mistralContextBias))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if state.mistralContextBias.isEmpty {
                            Text("e.g. Kubernetes,gRPC,SwiftUI,Barack Obama")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }
        } header: {
            Text("Vocabulary Hints")
        } footer: {
            Text("Comma-separated words or phrases (up to 100) that guide the model toward correct spellings of names, technical terms, or domain vocabulary. Optimised for English; experimental in other languages.")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Shared Pickers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Mistral language picker (shared by realtime and batch).
    ///
    /// Languages listed are those explicitly benchmarked by Mistral (FLEURS + Mozilla CV).
    /// Additional languages (ja, ko, zh, ru) have weaker support via the model backbone
    /// but are offered as they commonly appear in production use.
    ///
    /// `includeAutoDetect`: when true, adds an "Auto-Detect" option (empty string tag)
    /// that omits the language parameter entirely, letting the API identify the language.
    private func mistralLanguagePicker(includeAutoDetect: Bool) -> some View {
        Picker("Language", selection: state.binding(for: \.mistralLanguage)) {
            if includeAutoDetect {
                Text("Auto-Detect").tag("")
                    .help("The model detects the language automatically. Setting a language explicitly gives better accuracy.")
                Divider()
            }
            // — Fully benchmarked languages (Mistral FLEURS + Mozilla Common Voice) —
            Group {
                Text("English").tag("en")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Spanish").tag("es")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Dutch").tag("nl")
                Text("Hindi").tag("hi")
                Text("Arabic").tag("ar")
            }
            Divider()
            // — Additional languages (backbone support; not in official benchmarks) —
            Group {
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("Chinese (Mandarin)").tag("zh")
                Text("Russian").tag("ru")
            }
        }
        .pickerStyle(.menu)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Binding Helpers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

    /// Mistral temperature requires Float↔Double conversion for the Slider.
    private var mistralTemperatureBinding: Binding<Double> {
        floatBinding(for: \.mistralTemperature)
    }
}
