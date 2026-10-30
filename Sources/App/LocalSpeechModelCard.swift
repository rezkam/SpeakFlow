import SwiftUI
import SpeakFlowCore

struct LocalSpeechModelCard: View {
    let model: LocalSpeechModel
    let controller: LocalModelsController
    @ScaledMetric private var cardHeight = 248.0
    @ScaledMetric private var statusHeight = 38.0
    @ScaledMetric private var descriptionHeight = 34.0
    @ScaledMetric private var badgeWidth = 120.0
    @ScaledMetric private var actionHeight = 30.0

    private var entry: LocalModelCardState { controller.entry(model.id) }
    private var loaded: Bool { controller.runtimeState.loadedRevisions[model.id] == model.manifest.revision }
    private var inUse: Bool { controller.runtimeState.inUse.contains(model.id) }
    private var selected: Bool { controller.selectedProviderID == model.providerID }
    private var badge: String {
        if !controller.supported { return "Unavailable" }
        if entry.isChecking { return "Checking" }
        if inUse { return "In use" }
        if controller.runtimeState.loading == model.id { return "Loading" }
        if controller.runtimeState.retiring.contains(model.id) { return "Unloading" }
        if loaded { return selected ? "Selected · Loaded" : "Loaded" }
        if entry.isInstalled { return selected ? "Selected · Cold" : "Downloaded" }
        return entry.hasFiles ? "Needs attention" : "Not downloaded"
    }
    private var message: String {
        if !controller.supported { return model.unavailabilityReason(isAppleSilicon: false) ?? "Unavailable" }
        if entry.hasError || controller.workingID == model.id { return entry.message }
        if let notice = entry.updateNotice { return notice }
        if inUse { return "In use by a recording or its finalization. Unload and Delete are unavailable." }
        if loaded && !entry.isInstalled { return "Loaded in memory, but local files need attention. Unload and review this revision before recording." }
        if entry.isInstalled && controller.needsVAD(model.id) { return "Download the required voice activity model below before loading this batch model." }
        if loaded { return "Loaded. The next dictation can start without a cold model load." }
        if entry.isInstalled && entry.message.hasPrefix("Loaded") {
            return "Downloaded. The next dictation loads this model before opening the microphone."
        }
        return entry.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.name).font(.headline).lineLimit(1).help(model.name)
                Spacer()
                Text(badge).font(.caption).foregroundStyle(Theme.text2)
                    .frame(width: badgeWidth, alignment: .trailing)
            }
            Text(model.mode == .batch ? "BATCH TRANSCRIPTION · ENGLISH · ON DEVICE" : "LIVE TRANSCRIPTION · ENGLISH · ON DEVICE")
                .font(.caption).foregroundStyle(Theme.text2)
            Text(model.mode == .batch ? "Transcribes completed recording chunks. Apple Silicon required."
                : "Streams cumulative text while you speak. 1120 ms export; this is not a latency guarantee.")
                .font(.callout).lineLimit(2).frame(height: descriptionHeight, alignment: .topLeading)
            Text("Download: \(model.manifest.transferBytes.formatted()) bytes · \(model.manifest.license)\nRuntime RAM: not yet qualified · Revision \(model.manifest.revision.prefix(8))")
                .font(.caption).foregroundStyle(Theme.text2).lineLimit(2)
            HStack(spacing: 8) {
                Button("Download") { controller.reviewDownload(model.id) }.disabled(!controller.canDownload(model.id))
                    .accessibilityIdentifier("model.\(model.id.rawValue).download").accessibilityLabel("Download \(model.name)")
                Button("Load") { controller.load(model.id) }.disabled(!controller.canLoad(model.id))
                    .accessibilityIdentifier("model.\(model.id.rawValue).load").accessibilityLabel("Load \(model.name)")
                Button("Unload") { controller.unload(model.id) }.disabled(!controller.canUnload(model.id))
                    .accessibilityIdentifier("model.\(model.id.rawValue).unload").accessibilityLabel("Unload \(model.name)")
                Button("Delete", role: .destructive) { controller.reviewDelete(model.id) }.disabled(!controller.canDelete(model.id))
                    .accessibilityIdentifier("model.\(model.id.rawValue).delete").accessibilityLabel("Delete \(model.name)")
                if controller.versions(model.id).count > 1 {
                    Menu("Versions") {
                        ForEach(controller.versions(model.id), id: \.providerID) { version in
                            Button("Revision \(version.manifest.revision.prefix(8))" +
                                (controller.selectedProviderID == version.providerID ? " · Selected" : "")) {
                                controller.chooseVersion(version.providerID)
                            }
                        }
                    }
                    .disabled(controller.isBusy || controller.recordingBusy)
                    .accessibilityLabel("Reviewed versions of \(model.name)")
                }
                Spacer(minLength: 0)
                Button("Cancel") { controller.cancelOperation() }
                    .disabled(controller.workingID != model.id || !controller.operationCancellable)
                    .opacity(controller.workingID == model.id && controller.operationCancellable ? 1 : 0)
                    .accessibilityHidden(controller.workingID != model.id || !controller.operationCancellable)
            }
            .buttonStyle(.bordered).controlSize(.small).frame(height: actionHeight)
            Text(message).font(.caption).foregroundStyle(entry.hasError ? Theme.red : Theme.text2)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: statusHeight, maxHeight: statusHeight, alignment: .topLeading)
                .help(message).accessibilityIdentifier("model.\(model.id.rawValue).status")
        }
        .padding(16).frame(height: cardHeight, alignment: .topLeading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.line))
        .accessibilityElement(children: .contain).accessibilityLabel(model.name)
    }
}
