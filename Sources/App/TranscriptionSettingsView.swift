import AppKit
import AVFoundation
import SwiftUI
import SpeakFlowCore

/// Unified transcription settings: provider selection on top, provider-specific
/// audio/API settings below. Streaming and batch modes show different sections.
struct TranscriptionSettingsView: View {
    private let state = AppState.shared

    var body: some View {
        Form {
            // MARK: - Provider Selection

            Section {
                Picker("Transcription Provider", selection: providerBinding) {
                    ForEach(ProviderInfo.all) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                .pickerStyle(.radioGroup)

                if !state.isProviderConfigured(state.activeProviderId) {
                    providerWarning
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("Batch providers record audio and transcribe after each chunk. Streaming providers transcribe in real-time as you speak.")
            }

            // MARK: - Provider-Specific Settings

            if state.isStreamingProvider {
                streamingSettings
            } else {
                batchSettings
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
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

    @ViewBuilder
    private var providerWarning: some View {
        let message = state.activeProviderId == "gpt"
            ? "Log in to ChatGPT in the Accounts tab to use this provider."
            : "Set a Deepgram API key in the Accounts tab to use this provider."

        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
    }

    // MARK: - Streaming Settings (Deepgram)

    @ViewBuilder
    private var streamingSettings: some View {
        Section {
            Toggle("Show Interim Results", isOn: deepgramInterimBinding)
            Toggle("Smart Formatting", isOn: deepgramSmartFormatBinding)
        } header: {
            Text("Real-Time Options")
        } footer: {
            Text("Interim results show partial text as you speak, refining in real-time. Smart formatting adds punctuation and capitalization automatically.")
        }

        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Endpointing")
                    Spacer()
                    Text("\(state.deepgramEndpointingMs) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: deepgramEndpointingBinding,
                    in: 100...3000,
                    step: 100
                )
                HStack {
                    Text("100 ms — fast response")
                    Spacer()
                    Text("3000 ms — waits for pauses")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Utterance Detection")
        } footer: {
            Text("Controls how quickly Deepgram detects the end of an utterance. Lower values give faster responses but may split mid-sentence. Higher values wait longer for natural pauses. Default: 300 ms.")
        }

        Section {
            Picker("Model", selection: deepgramModelBinding) {
                Text("Nova 3").tag("nova-3")
                Text("Nova 2").tag("nova-2")
            }
            .pickerStyle(.menu)

            Picker("Language", selection: deepgramLanguageBinding) {
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
            Toggle("Auto-End on Silence", isOn: streamingAutoEndBinding)

            if state.streamingAutoEndEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Silence Duration")
                        Spacer()
                        Text(String(format: "%.0fs", state.autoEndSilenceDuration))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: autoEndDurationBinding, in: 3...30, step: 1)
                    HStack {
                        Text("3s — quick stop")
                        Spacer()
                        Text("30s — tolerates long pauses")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Auto-End")
        } footer: {
            Text("Disabled by default for streaming. When enabled, recording stops after the specified silence period. In streaming mode, text is already inserted in real-time, so you can simply press the hotkey to stop when finished.")
        }
    }

    // MARK: - Batch Settings (ChatGPT)

    @ViewBuilder
    private var batchSettings: some View {
        Section {
            Picker("Chunk Duration", selection: chunkDurationBinding) {
                ForEach(ChunkDuration.allCases, id: \.self) { duration in
                    Text(duration.displayName).tag(duration)
                }
            }
            .pickerStyle(.menu)

            Toggle("Skip Silent Chunks", isOn: skipSilentBinding)
        } header: {
            Text("Recording")
        } footer: {
            Text("Chunk duration controls how often audio is sent for transcription. Skip silent chunks saves API costs by not sending audio with no speech detected.")
        }

        Section {
            Toggle("Enable Voice Activity Detection", isOn: vadEnabledBinding)

            if state.vadEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("VAD Sensitivity")
                        Spacer()
                        Text(String(format: "%.0f%%", state.vadThreshold * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: vadThresholdBinding, in: 0.05...0.50, step: 0.05)
                    HStack {
                        Text("More sensitive")
                        Spacer()
                        Text("Stricter filtering")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Voice Activity Detection")
        } footer: {
            Text("VAD analyzes audio in real time to detect when you are speaking. Only segments containing speech are sent to the transcription service. Default: 15%.")
        }

        Section {
            Toggle("Auto-End Recording on Silence", isOn: autoEndEnabledBinding)

            if state.autoEndEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Silence Duration")
                        Spacer()
                        Text(String(format: "%.0fs", state.autoEndSilenceDuration))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: autoEndDurationBinding, in: 3...30, step: 1)
                    HStack {
                        Text("3s — quick stop")
                        Spacer()
                        Text("30s — tolerates long pauses")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Auto-End")
        } footer: {
            Text("When enabled, recording automatically stops after the specified silence period. Default: 5s.")
        }

        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum Speech Ratio")
                    Spacer()
                    Text(String(format: "%.0f%%", state.minSpeechRatio * 100))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: minSpeechRatioBinding, in: 0.01...0.10, step: 0.01)
                HStack {
                    Text("1% — very sensitive")
                    Spacer()
                    Text("10% — requires more speech")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Speech Detection")
        } footer: {
            Text("Minimum percentage of a chunk that must contain speech before it is sent for transcription. Default: 1%.")
        }
    }

    // MARK: - Batch Bindings

    private var chunkDurationBinding: Binding<ChunkDuration> {
        Binding(
            get: { state.chunkDuration },
            set: { newValue in
                Settings.shared.chunkDuration = newValue
                state.refresh()
            }
        )
    }

    private var skipSilentBinding: Binding<Bool> {
        Binding(
            get: { state.skipSilentChunks },
            set: { newValue in
                Settings.shared.skipSilentChunks = newValue
                state.refresh()
            }
        )
    }

    private var vadEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.vadEnabled },
            set: { newValue in
                Settings.shared.vadEnabled = newValue
                state.refresh()
            }
        )
    }

    private var vadThresholdBinding: Binding<Float> {
        Binding(
            get: { state.vadThreshold },
            set: { newValue in
                Settings.shared.vadThreshold = newValue
                state.refresh()
            }
        )
    }

    private var autoEndEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.autoEndEnabled },
            set: { newValue in
                Settings.shared.autoEndEnabled = newValue
                state.refresh()
            }
        )
    }

    private var autoEndDurationBinding: Binding<Double> {
        Binding(
            get: { state.autoEndSilenceDuration },
            set: { newValue in
                Settings.shared.autoEndSilenceDuration = newValue
                state.refresh()
            }
        )
    }

    private var minSpeechRatioBinding: Binding<Float> {
        Binding(
            get: { state.minSpeechRatio },
            set: { newValue in
                Settings.shared.minSpeechRatio = newValue
                state.refresh()
            }
        )
    }

    // MARK: - Streaming Bindings

    private var deepgramInterimBinding: Binding<Bool> {
        Binding(
            get: { state.deepgramInterimResults },
            set: { newValue in
                Settings.shared.deepgramInterimResults = newValue
                state.refresh()
            }
        )
    }

    private var deepgramSmartFormatBinding: Binding<Bool> {
        Binding(
            get: { state.deepgramSmartFormat },
            set: { newValue in
                Settings.shared.deepgramSmartFormat = newValue
                state.refresh()
            }
        )
    }

    private var deepgramEndpointingBinding: Binding<Double> {
        Binding(
            get: { Double(state.deepgramEndpointingMs) },
            set: { newValue in
                Settings.shared.deepgramEndpointingMs = Int(newValue)
                state.refresh()
            }
        )
    }

    private var deepgramModelBinding: Binding<String> {
        Binding(
            get: { state.deepgramModel },
            set: { newValue in
                Settings.shared.deepgramModel = newValue
                state.refresh()
            }
        )
    }

    private var deepgramLanguageBinding: Binding<String> {
        Binding(
            get: { state.deepgramLanguage },
            set: { newValue in
                Settings.shared.deepgramLanguage = newValue
                state.refresh()
            }
        )
    }

    private var streamingAutoEndBinding: Binding<Bool> {
        Binding(
            get: { state.streamingAutoEndEnabled },
            set: { newValue in
                Settings.shared.streamingAutoEndEnabled = newValue
                state.refresh()
            }
        )
    }
}
