import SwiftUI
import SpeakFlowCore

/// Transcription settings split into Universal, model-specific options, and Advanced.
struct TranscriptionSettingsView: View {
    @Environment(\.appState) private var state

    let switchTab: (SettingsTab) -> Void

    var body: some View {
        let _ = state.refreshVersion
        let configured = ProviderRegistry.shared.configuredProviders
        let activeProvider = activeConfiguredProvider(from: configured)
        let activeModelId = ModelCatalog.activeModelId(for: activeProvider?.id ?? state.activeProviderId, in: state)

        VStack(alignment: .leading, spacing: 18) {
            ActiveModelBanner(
                activeProvider: activeProvider,
                activeModelId: activeModelId,
                configuredProviders: configured,
                allModels: ModelCatalog.availableModels(for: configured),
                onActivate: { model in ModelCatalog.activate(model, in: state) },
                onManageProviders: { switchTab(.providers) }
            )

            universalSection(activeProvider: activeProvider)

            if let activeProvider {
                modelSection(provider: activeProvider, modelId: activeModelId)
            }

            advancedSection(activeProvider: activeProvider, activeModelId: activeModelId)
        }
        .onAppear(perform: autoSelectProviderIfNeeded)
    }

    // MARK: - Universal

    private func universalSection(activeProvider: (any TranscriptionProvider)?) -> some View {
        SectionCard(
            "Universal",
            footer: "These settings apply to the active model. Language is sent to the provider as a hint when the provider supports it. Auto-detect lets the model decide."
        ) {
            SettingRow(
                "Language",
                description: "A BCP-47 hint sent to the provider. Auto-detect works in most cases. Setting a language can improve accuracy and first-token latency."
            ) {
                languagePicker
            }
            SettingRow(
                "Auto-end on silence",
                description: "Stop the recording automatically after a sustained pause, so you do not have to press the hotkey again."
            ) {
                Toggle("", isOn: autoEndBinding(for: activeProvider))
                    .labelsHidden()
            }
            if isAutoEndEnabled(for: activeProvider) {
                SettingSliderRow(
                    label: "Silence duration",
                    description: "How long to wait in silence before auto-ending.",
                    value: state.binding(for: \.autoEndSilenceDuration),
                    range: 1...30,
                    step: 1,
                    formatted: "\(Int(state.autoEndSilenceDuration)) s",
                    lowLabel: "1 s, snappy",
                    highLabel: "30 s, patient"
                )
            }
        }
    }

    @ViewBuilder
    private var languagePicker: some View {
        switch state.activeProviderId {
        case ProviderId.deepgram:
            Picker("", selection: state.binding(for: \.deepgramLanguage)) {
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
            .labelsHidden()
            .fixedSize()
        case ProviderId.mistral, ProviderId.mistralBatch:
            Picker("", selection: state.binding(for: \.mistralLanguage)) {
                Text("Auto-detect").tag("")
                Divider()
                Text("English").tag("en")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Spanish").tag("es")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Dutch").tag("nl")
                Text("Hindi").tag("hi")
                Text("Arabic").tag("ar")
                Divider()
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("Chinese").tag("zh")
                Text("Russian").tag("ru")
            }
            .labelsHidden()
            .fixedSize()
        default:
            Text("Auto-detect")
                .foregroundStyle(Theme.text3)
                .font(.system(size: 12.5))
        }
    }

    // MARK: - Model options

    @ViewBuilder
    private func modelSection(provider: any TranscriptionProvider, modelId: String) -> some View {
        let mode: ModePill.Mode = provider.mode == .streaming ? .streaming : .batch
        SectionCard(
            "\(modelLabel(modelId)) options",
            trailingPill: AnyView(ModePill(mode: mode)),
            footer: provider.mode == .streaming
                ? "Streaming options for \(provider.displayName) \(modelLabel(modelId)). Switch models to see different options."
                : "Batch options for \(provider.displayName) \(modelLabel(modelId)). Switch models to see different options."
        ) {
            switch modelId {
            case "nova-3":
                deepgramBasic
            case "voxtral-mini-transcribe-realtime-2602":
                mistralRealtimeBasic
            case "voxtral-mini-latest":
                mistralBatchBasic
            case "gpt-4o-transcribe":
                openAIBasic
            default:
                Text("No model-specific options for \(modelId).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var deepgramBasic: some View {
        Group {
            SettingRow(
                "Show interim results",
                description: "Stream partial text as you speak. Disable for final-only output, which is cleaner but feels slower."
            ) {
                Toggle("", isOn: state.binding(for: \.deepgramInterimResults))
                    .labelsHidden()
            }
            SettingRow(
                "Smart formatting",
                description: "Format numbers, dates, currencies, phone numbers, emails, and URLs the way you would type them."
            ) {
                Toggle("", isOn: state.binding(for: \.deepgramSmartFormat))
                    .labelsHidden()
            }
            SettingSliderRow(
                label: "Endpoint silence",
                description: "How long Deepgram must hear silence after a word before deciding the utterance is over. Shorter is snappier. Longer waits through natural pauses.",
                value: Binding(
                    get: { Double(state.deepgramEndpointingMs) },
                    set: { Settings.shared.deepgramEndpointingMs = Int($0); state.refresh() }
                ),
                range: 100...3000,
                step: 50,
                formatted: "\(state.deepgramEndpointingMs) ms",
                lowLabel: "100 ms, snappy",
                highLabel: "3000 ms, patient"
            )
        }
    }

    private var mistralRealtimeBasic: some View {
        Group {
            SettingRow(
                "Show interim results",
                description: "Voxtral Realtime currently streams partial tokens by default. This control will become editable when the provider exposes a setting."
            ) {
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .disabled(true)
            }
            SettingRow(
                "Auto-end on speech pause",
                description: "Let the live session close the turn when you stop speaking."
            ) {
                Toggle("", isOn: state.binding(for: \.streamingAutoEndEnabled))
                    .labelsHidden()
            }
        }
    }

    private var mistralBatchBasic: some View {
        Group {
            SettingRow(
                "Speaker diarization",
                description: "Tag each segment with a speaker label. Useful for meetings and interviews. Requires a non-Auto-detect language."
            ) {
                Toggle("", isOn: state.binding(for: \.mistralDiarize))
                    .labelsHidden()
            }
        }
    }

    private var openAIBasic: some View {
        Group {
            SettingRow(
                "Vocabulary prompt",
                description: "Short paragraph hinting proper nouns, jargon, or style. This UI is disabled until the ChatGPT provider exposes a stored prompt setting."
            ) {
                TextField("", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .disabled(true)
            }
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private func advancedSection(activeProvider: (any TranscriptionProvider)?, activeModelId: String) -> some View {
        DisclosureCard(
            "Advanced settings",
            subtitle: "Power-user tuning, most people never need these"
        ) {
            switch activeModelId {
            case "nova-3":
                deepgramAdvanced
            case "voxtral-mini-transcribe-realtime-2602":
                mistralRealtimeAdvanced
            case "voxtral-mini-latest":
                mistralBatchAdvanced
            default:
                EmptyView()
            }

            if activeProvider?.mode == .batch {
                recordingAdvanced
                vadAdvanced
                audioFilteringAdvanced
                autoEndAdvanced
                speechDetectionAdvanced
            }
        }
    }

    private var deepgramAdvanced: some View {
        SectionCard(
            "Nova-3 advanced",
            trailingPill: AnyView(ModePill(mode: .streaming)),
            footer: "Wire-level reliability and decoder tuning. Defaults are safe for most users."
        ) {
            streamingReliabilityRows
        }
    }

    private var mistralRealtimeAdvanced: some View {
        SectionCard(
            "Voxtral Realtime advanced",
            trailingPill: AnyView(ModePill(mode: .streaming)),
            footer: "Connection reliability and final-commit tuning. Defaults are safe for most users."
        ) {
            streamingReliabilityRows
        }
    }

    private var mistralBatchAdvanced: some View {
        SectionCard(
            "Voxtral Mini advanced",
            trailingPill: AnyView(ModePill(mode: .batch)),
            footer: "Context biasing and decoder tuning. Defaults are safe for most users."
        ) {
            SettingRow(
                "Context bias terms",
                description: "Up to 100 comma-separated words or phrases that guide Voxtral toward correct spellings of names, technical terms, or domain vocabulary."
            ) {
                TextField("Telavox, Voxtral, kubectl", text: state.binding(for: \.mistralContextBias))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            SettingSliderRow(
                label: "Temperature",
                description: "Sampling randomness. 0 is deterministic and literal. Higher values let the model vary more.",
                value: floatBinding(for: \.mistralTemperature),
                range: 0...1,
                step: 0.05,
                formatted: String(format: "%.2f", state.mistralTemperature),
                lowLabel: "0, literal",
                highLabel: "1, varied"
            )
        }
    }

    private var streamingReliabilityRows: some View {
        Group {
            SettingRow(
                "Send keep-alive pings",
                description: "Send periodic frames so the WebSocket does not idle-drop during long pauses."
            ) {
                Toggle("", isOn: state.binding(for: \.streamingKeepAliveEnabled))
                    .labelsHidden()
            }
            if state.streamingKeepAliveEnabled {
                SettingSliderRow(
                    label: "Ping interval",
                    description: "How often to send a keep-alive while you are silent.",
                    value: state.binding(for: \.streamingKeepAliveInterval),
                    range: 2...20,
                    step: 1,
                    formatted: "\(Int(state.streamingKeepAliveInterval)) s",
                    lowLabel: "2 s",
                    highLabel: "20 s"
                )
            }
            SettingRow(
                "Auto-reconnect on drop",
                description: "Try to reopen the WebSocket once if it closes unexpectedly mid-utterance."
            ) {
                Toggle("", isOn: state.binding(for: \.streamingReconnectEnabled))
                    .labelsHidden()
            }
            SettingRow(
                "Drop short stutters",
                description: "Discard non-terminal final results shorter than this many words. This suppresses single-word false starts."
            ) {
                Stepper(
                    "\(state.streamingMinimumFinalWordCount)",
                    value: state.binding(for: \.streamingMinimumFinalWordCount),
                    in: 1...5
                )
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var recordingAdvanced: some View {
        SectionCard(
            "Recording",
            footer: "Chunk duration controls how often audio is sent. Streaming providers use chunks for local gating while audio still streams continuously."
        ) {
            SettingRow(
                "Chunk duration",
                description: "How often recorded audio is grouped for transcription and local checks."
            ) {
                Picker("", selection: state.binding(for: \.chunkDuration)) {
                    ForEach(ChunkDuration.allCases, id: \.self) { duration in
                        Text(duration.displayName).tag(duration)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(
                "Skip silent chunks",
                description: "Do not send chunks containing only silence. This saves API calls."
            ) {
                Toggle("", isOn: state.binding(for: \.skipSilentChunks))
                    .labelsHidden()
            }
        }
    }

    private var vadAdvanced: some View {
        SectionCard(
            "Voice Activity Detection",
            footer: "Lower threshold catches quieter speech but may pick up noise. Higher threshold is stricter."
        ) {
            SettingRow(
                "Enable VAD",
                description: "Locally detect speech versus silence before sending audio to the model."
            ) {
                Toggle("", isOn: state.binding(for: \.vadEnabled))
                    .labelsHidden()
            }
            if state.vadEnabled {
                SettingSliderRow(
                    label: "Speech threshold",
                    description: "Probability above which a frame counts as speech. Lower is permissive, higher is stricter.",
                    value: floatBinding(for: \.vadThreshold),
                    range: 0.05...0.50,
                    step: 0.05,
                    formatted: String(format: "%.2f", state.vadThreshold),
                    lowLabel: "0.05, permissive",
                    highLabel: "0.50, strict"
                )
                SettingRow(
                    "Volume gate",
                    description: "Require speech to be loud enough before VAD accepts it. Helps reject keyboard and fan noise."
                ) {
                    Toggle("", isOn: state.binding(for: \.vadVolumeGateEnabled))
                        .labelsHidden()
                }
                if state.vadVolumeGateEnabled {
                    SettingSliderRow(
                        label: "Minimum speech volume",
                        description: "Quieter audio below this RMS level is treated as noise.",
                        value: floatBinding(for: \.vadMinVolumeForSpeech),
                        range: 0.001...0.050,
                        step: 0.001,
                        formatted: String(format: "%.4f", state.vadMinVolumeForSpeech),
                        lowLabel: "Allow quieter speech",
                        highLabel: "Reject more noise"
                    )
                }
                SettingSliderRow(
                    label: "Volume smoothing",
                    description: "Smooth volume changes before VAD uses them. More smoothing is calmer, less smoothing reacts faster.",
                    value: floatBinding(for: \.vadVolumeSmoothingFactor),
                    range: 0.05...1.0,
                    step: 0.05,
                    formatted: String(format: "%.2f", state.vadVolumeSmoothingFactor),
                    lowLabel: "More smoothing",
                    highLabel: "More reactive"
                )
                SettingSliderRow(
                    label: "State reset interval",
                    description: "How often to reset accumulated VAD state during long sessions to prevent drift.",
                    value: state.binding(for: \.vadStateResetInterval),
                    range: 0.5...30.0,
                    step: 0.5,
                    formatted: String(format: "%.1f s", state.vadStateResetInterval),
                    lowLabel: "0.5 s",
                    highLabel: "30 s"
                )
            }
        }
    }

    private var audioFilteringAdvanced: some View {
        SectionCard(
            "Audio filtering",
            footer: "The pre-VAD gate removes low-level room noise before VAD and buffering."
        ) {
            SettingRow(
                "Pre-VAD noise gate",
                description: "Apply a lightweight gate before VAD. Useful in noisy rooms."
            ) {
                Toggle("", isOn: state.binding(for: \.audioNoiseGateEnabled))
                    .labelsHidden()
            }
            if state.audioNoiseGateEnabled {
                SettingSliderRow(
                    label: "Noise gate RMS threshold",
                    description: "Audio below this RMS level is reduced before VAD sees it.",
                    value: floatBinding(for: \.audioNoiseGateRmsThreshold),
                    range: 0.000...0.010,
                    step: 0.0005,
                    formatted: String(format: "%.4f", state.audioNoiseGateRmsThreshold),
                    lowLabel: "Less filtering",
                    highLabel: "More filtering"
                )
            }
        }
    }

    private var autoEndAdvanced: some View {
        SectionCard(
            "Auto-end details",
            footer: "These controls tune batch-mode auto-end timing, thinking-pause behavior, classifier gating, and idle nudges."
        ) {
            SettingSliderRow(
                label: "Minimum session duration",
                description: "Do not auto-end before the recording is at least this old.",
                value: state.binding(for: \.autoEndMinSessionDuration),
                range: 0...10,
                step: 0.5,
                formatted: String(format: "%.1f s", state.autoEndMinSessionDuration),
                lowLabel: "0 s",
                highLabel: "10 s"
            )
            SettingRow(
                "Require speech first",
                description: "Wait until speech is detected before silence can end the recording."
            ) {
                Toggle("", isOn: state.binding(for: \.autoEndRequireSpeechFirst))
                    .labelsHidden()
            }
            SettingSliderRow(
                label: "No-speech timeout",
                description: "Stop if no speech is heard for this long. Set to 0 to disable.",
                value: state.binding(for: \.autoEndNoSpeechTimeout),
                range: 0...60,
                step: 1,
                formatted: state.autoEndNoSpeechTimeout == 0 ? "Disabled" : String(format: "%.0f s", state.autoEndNoSpeechTimeout),
                lowLabel: "0 s, off",
                highLabel: "60 s"
            )
            SettingSliderRow(
                label: "Max continuous speech safety",
                description: "Stop after very long uninterrupted speech. Set to 0 to disable.",
                value: state.binding(for: \.autoEndMaxContinuousSpeechDuration),
                range: 0...600,
                step: 5,
                formatted: state.autoEndMaxContinuousSpeechDuration == 0 ? "Disabled" : String(format: "%.0f s", state.autoEndMaxContinuousSpeechDuration),
                lowLabel: "0 s, off",
                highLabel: "600 s"
            )
            SettingRow(
                "Thinking pause extension",
                description: "Extend silence tolerance when the recent transcript looks unfinished."
            ) {
                Toggle("", isOn: state.binding(for: \.thinkingPauseEnabled))
                    .labelsHidden()
            }
            if state.thinkingPauseEnabled {
                SettingSliderRow(
                    label: "Extra thinking time",
                    description: nil,
                    value: state.binding(for: \.thinkingPauseExtensionSeconds),
                    range: 1...15,
                    step: 1,
                    formatted: String(format: "+%.0f s", state.thinkingPauseExtensionSeconds),
                    lowLabel: "+1 s",
                    highLabel: "+15 s"
                )
            }
            SettingRow(
                "Turn classifier",
                description: "Use a classifier signal to wait longer when a turn appears incomplete."
            ) {
                Toggle("", isOn: state.binding(for: \.turnClassifierEnabled))
                    .labelsHidden()
            }
            if state.turnClassifierEnabled {
                SettingSliderRow(
                    label: "Classifier minimum silence",
                    description: nil,
                    value: state.binding(for: \.turnClassifierMinimumSilence),
                    range: 0.5...10,
                    step: 0.5,
                    formatted: String(format: "%.1f s", state.turnClassifierMinimumSilence),
                    lowLabel: "0.5 s",
                    highLabel: "10 s"
                )
                SettingSliderRow(
                    label: "Incomplete-turn extension",
                    description: nil,
                    value: state.binding(for: \.turnClassifierIncompleteExtensionSeconds),
                    range: 1...20,
                    step: 1,
                    formatted: String(format: "+%.0f s", state.turnClassifierIncompleteExtensionSeconds),
                    lowLabel: "+1 s",
                    highLabel: "+20 s"
                )
                SettingSliderRow(
                    label: "Classifier threshold",
                    description: nil,
                    value: floatBinding(for: \.turnClassifierThreshold),
                    range: 0.1...0.9,
                    step: 0.05,
                    formatted: String(format: "%.2f", state.turnClassifierThreshold),
                    lowLabel: "More complete",
                    highLabel: "More incomplete"
                )
            }
            SettingRow(
                "Idle nudge before auto-end",
                description: "Play nudges before auto-end when the session appears idle."
            ) {
                Toggle("", isOn: state.binding(for: \.idleNudgeEnabled))
                    .labelsHidden()
            }
            if state.idleNudgeEnabled {
                SettingSliderRow(
                    label: "Nudge initial delay",
                    description: nil,
                    value: state.binding(for: \.idleNudgeInitialDelay),
                    range: 0...10,
                    step: 0.5,
                    formatted: String(format: "%.1f s", state.idleNudgeInitialDelay),
                    lowLabel: "0 s",
                    highLabel: "10 s"
                )
                SettingSliderRow(
                    label: "Nudge interval",
                    description: nil,
                    value: state.binding(for: \.idleNudgeInterval),
                    range: 1...10,
                    step: 0.5,
                    formatted: String(format: "%.1f s", state.idleNudgeInterval),
                    lowLabel: "1 s",
                    highLabel: "10 s"
                )
                SettingRow(
                    "Maximum nudges",
                    description: "How many nudges can play before SpeakFlow gives up."
                ) {
                    Stepper(
                        "\(state.idleNudgeMaxCount)",
                        value: state.binding(for: \.idleNudgeMaxCount),
                        in: 1...10
                    )
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var speechDetectionAdvanced: some View {
        SectionCard(
            "Speech detection",
            footer: "Recordings below this ratio of speech-to-silence are discarded as accidental triggers."
        ) {
            SettingSliderRow(
                label: "Minimum speech ratio",
                description: nil,
                value: floatBinding(for: \.minSpeechRatio),
                range: 0...0.5,
                step: 0.01,
                formatted: "\(Int(state.minSpeechRatio * 100))%",
                lowLabel: "0%, accept any audio",
                highLabel: "50%, require half speech"
            )
        }
    }

    // MARK: - Helpers

    private func autoEndBinding(for provider: (any TranscriptionProvider)?) -> Binding<Bool> {
        if provider?.mode == .streaming {
            state.binding(for: \.streamingAutoEndEnabled)
        } else {
            state.binding(for: \.autoEndEnabled)
        }
    }

    private func isAutoEndEnabled(for provider: (any TranscriptionProvider)?) -> Bool {
        if provider?.mode == .streaming { return state.streamingAutoEndEnabled }
        return state.autoEndEnabled
    }

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

    private func modelLabel(_ id: String) -> String {
        ModelCatalog.all.first { $0.id == id }?.name ?? id
    }

    private func floatBinding(
        for keyPath: ReferenceWritableKeyPath<SpeakFlowCore.Settings, Float>
    ) -> Binding<Double> {
        Binding(
            get: { Double(SpeakFlowCore.Settings.shared[keyPath: keyPath]) },
            set: { newValue in
                SpeakFlowCore.Settings.shared[keyPath: keyPath] = Float(newValue)
                state.refresh()
            }
        )
    }
}
