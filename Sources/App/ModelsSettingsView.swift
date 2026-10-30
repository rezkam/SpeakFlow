import SwiftUI
import SpeakFlowCore

struct ModelsSettingsView: View {
    @State var vad = VADInstallController.shared
    @State var models = LocalModelsController.shared
    @State private var resources = LocalProcessResourceUsage()
    @FocusState private var downloadFocused: Bool
    @ScaledMetric private var vadCardHeight = 248.0
    @ScaledMetric private var vadStatusHeight = 38.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Models stay on this Mac. Downloads always require confirmation.")
                .font(.callout)
                .foregroundStyle(Theme.text2)
            localPreferences
            resourceUsage
            Text(models.resourceWarning ?? "")
                .font(.caption).foregroundStyle(Theme.text2)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
                .accessibilityHidden(models.resourceWarning == nil)
            if let error = models.catalogError { Text(error).foregroundStyle(Theme.red) }
            ForEach(models.models) { model in
                LocalSpeechModelCard(model: model, controller: models)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Voice activity detection").font(.headline)
                    Spacer()
                    Text(vad.isInUse ? "In use" : vad.isLoading ? "Loading" : vad.isLoaded ? "Loaded" : vad.isInstalled ? "Downloaded" : "Not downloaded")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Text("SILERO V6.2.1 · SPEECH DETECTION · ON-DEVICE")
                    .font(.caption).foregroundStyle(Theme.text2)
                Text("Detects speech and silence for local voice activity detection. Does not transcribe words.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Download: \(ModelDisplayFormatting.size(LocalVADAssets.manifest.transferBytes)) · License: MIT")
                    .font(.caption).foregroundStyle(Theme.text2)
                HStack {
                    Button("Download") { vad.reviewDownload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vad.canDownload || models.isBusy || models.recordingBusy)
                        .focused($downloadFocused)
                        .accessibilityIdentifier("vad.download").accessibilityLabel("Download voice activity detection")
                    Button("Load") { vad.load() }
                        .disabled(!vad.canLoad || models.isBusy || models.recordingBusy)
                        .accessibilityIdentifier("vad.load").accessibilityLabel("Load voice activity detection")
                    Button("Unload") { vad.unload() }
                        .disabled(!vad.canUnload || models.isBusy || models.recordingBusy)
                        .accessibilityIdentifier("vad.unload").accessibilityLabel("Unload voice activity detection")
                    Button("Delete", role: .destructive) { vad.reviewDelete() }
                        .disabled(!vad.canDelete || models.isBusy || models.recordingBusy)
                        .accessibilityIdentifier("vad.delete").accessibilityLabel("Delete voice activity detection")
                    Button("Cancel") { models.cancelOperation() }
                        .disabled(!vad.isBusy || !vad.operationCancellable)
                        .opacity(vad.isBusy && vad.operationCancellable ? 1 : 0)
                        .accessibilityHidden(!vad.isBusy || !vad.operationCancellable)
                    Spacer()
                }
                .frame(height: 32)
                Text(vad.hasError || vad.isBusy ? vad.message : vad.isInUse
                    ? "In use by recording or finalization. Model actions are available after it finishes."
                    : vad.updateNotice ?? vad.message)
                    .font(.caption)
                    .foregroundStyle(vad.hasError ? Theme.red : Theme.text2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: vadStatusHeight, maxHeight: vadStatusHeight, alignment: .topLeading)
                    .help(vad.message)
                    .accessibilityIdentifier("vad.status")
            }
            .padding(16).frame(height: vadCardHeight, alignment: .topLeading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.line))
        }
        .task {
            if vad !== models.vad { await vad.refresh() }
            await models.refresh()
            while !Task.isCancelled {
                resources.sample()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await models.refreshRuntime()
            }
        }
        .sheet(isPresented: Binding(get: { models.confirmation != nil }, set: { if !$0 { models.confirmation = nil } }), content: {
            if let review = models.confirmation { modelConfirmation(review) }
        })
        .sheet(isPresented: Binding(get: { vad.confirmation != nil }, set: { if !$0 { vad.confirmation = nil } }),
               onDismiss: { downloadFocused = true }) {
            confirmation
        }
    }

    private var resourceUsage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live SpeakFlow resources").font(.subheadline.bold())
            HStack {
                Text("Memory: \(resources.memoryBytes.map { ModelDisplayFormatting.size(Int64($0)) } ?? "Unavailable")")
                Text("Resident: \(resources.residentBytes.map { ModelDisplayFormatting.size(Int64($0)) } ?? "Unavailable")")
                Text("CPU: \(resources.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Measuring...")")
            }
            .font(.caption).monospacedDigit()
            Text("Whole app, including loaded models. Model-only and shared accelerator memory are not isolated. CPU: 100% equals one core.")
                .font(.caption).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(vad.isDeleteReview ? "Delete this voice activity revision?" : "Download voice activity detection?").font(.headline)
            Text("Silero VAD v6.2.1 · MIT license")
            Text("5 files · \(ModelDisplayFormatting.size(LocalVADAssets.manifest.transferBytes))")
            Text("Source: FluidInference/silero-vad-coreml\nRevision: b419383c55c110e2c9271fa6ee0ea83d03c70d96")
                .font(.caption).textSelection(.enabled)
            if vad.isDeleteReview {
                Text(vad.removesInstallation
                    ? "Recordings requiring voice activity detection will be unavailable until these files are downloaded again. Other models remain installed."
                    : "Only the named incomplete transfers are removed. Installed models remain available.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(vad.measuredBytes.map { "Measured files: \(ModelDisplayFormatting.size($0))." } ?? "Installed size could not be measured.")
                    .font(.caption)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(vad.availableRemovalTargets, id: \.name) { target in
                            Toggle(isOn: Binding(get: { vad.removalTargets.contains(target) },
                                set: { vad.selectRemovalTarget(target.name, included: $0) })) {
                                Text("\(target.name)\n\(ModelDisplayFormatting.size(target.bytes))").font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }.frame(height: min(150, CGFloat(vad.availableRemovalTargets.count) * 70))
            } else {
                Text("Required for local speech detection. No audio is uploaded. Files are verified before use.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { vad.confirmation = nil }
                    .keyboardShortcut(.cancelAction)
                Button(vad.isDeleteReview ? "Delete revision" : "Confirm download") {
                    if vad.isDeleteReview { vad.confirmDelete() } else { vad.confirmDownload() }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vad.isDeleteReview && vad.removalTargets.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
        .background(Theme.surface)
    }

    private func modelConfirmation(_ review: LocalModelConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.kind == .download ? "Download local model?" : "Delete this exact revision?").font(.headline)
            ForEach(review.manifests, id: \.id) { manifest in
                VStack(alignment: .leading, spacing: 4) {
                    Text(manifest.id == LocalVADAssets.manifest.id ? "Silero VAD v6.2.1" :
                        models.models.first(where: { $0.id == review.modelID })?.name ?? manifest.id).font(.subheadline.bold())
                    Text("\(manifest.artifacts.count) files · \(ModelDisplayFormatting.size(manifest.transferBytes)) · \(manifest.license)")
                        .font(.caption)
                    Text("Source: \(manifest.repository)\nRevision: \(manifest.revision)")
                        .font(.caption2).textSelection(.enabled)
                }
            }
            if review.kind == .download {
                let total = review.manifests.reduce(0) { $0 + $1.transferBytes }
                Text("Total: \(ModelDisplayFormatting.size(total)). Files are verified before installation. No audio is uploaded.")
                    .font(.callout)
            } else {
                Text(review.installedBytes.map { "Measured files: \(ModelDisplayFormatting.size($0))." } ?? "Installed size could not be measured.")
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(review.availableRemovalTargets, id: \.name) { target in
                            Toggle(isOn: Binding(get: { models.confirmation?.removalTargets.contains(target) == true },
                                set: { models.selectRemovalTarget(target.name, included: $0) })) {
                                Text("\(target.name)\n\(ModelDisplayFormatting.size(target.bytes))").font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(height: min(150, CGFloat(review.availableRemovalTargets.count) * 70))
                Text(review.removesInstallation
                    ? "Other models and voice activity files are retained. If selected, this model stays unavailable until downloaded again or replaced."
                    : "Only the named incomplete transfers are removed. Installed models and voice activity files are retained.")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { models.confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(review.kind == .download ? "Confirm download" : "Delete revision") { models.confirmOperation() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(models.isBusy || models.recordingBusy || (review.kind == .delete && review.removalTargets.isEmpty))
            }
        }
        .padding(24).frame(width: 420).fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text).background(Theme.surface)
    }

    private var localPreferences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No cloud account is needed. Loading keeps the microphone off until the model is ready.")
                .font(.callout).foregroundStyle(Theme.text2)
            HStack {
                Text("Keep idle models warm")
                Spacer()
                Picker("Keep idle models warm", selection: Binding(
                    get: { LocalModelPreferences.shared.idleSeconds }, set: { models.setIdleSeconds($0) })) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                }
                .labelsHidden().frame(width: 180)
            }
            Toggle("Preload downloaded models for the selected mode at launch", isOn: Binding(
                get: { LocalModelPreferences.shared.preloadOnLaunch },
                set: { LocalModelPreferences.shared.preloadOnLaunch = $0 }))
            Text("Cold loading can wait up to 60 seconds. Preloading never downloads files.")
                .font(.caption).foregroundStyle(Theme.text2)
            HStack {
                Button(models.checkingUpdates ? "Cancel update check" : "Check for model updates") {
                    if models.checkingUpdates { models.cancelOperation() } else { models.checkForUpdates() }
                }
                .disabled(models.recordingBusy || (models.isBusy && !models.checkingUpdates))
                .accessibilityIdentifier("models.check-updates")
                Text(models.updateMessage).font(.caption).foregroundStyle(Theme.text2)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            }
        }
        .disabled(models.recordingBusy)
    }

}
