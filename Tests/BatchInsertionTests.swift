import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Batch insertion settings")
struct BatchInsertionSettingsTests {
    @Test @MainActor
    func directInsertionIsDefaultAndTypingChoicePersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "synthetic.batch-insertion.\(UUID().uuidString)"))
        let settings = Settings(defaults: defaults)
        #expect(!settings.batchTypeText)
        settings.batchTypeText = true
        #expect(Settings(defaults: defaults).batchTypeText)
        settings.batchTypeText = false
        #expect(!Settings(defaults: defaults).batchTypeText)
    }
}

@Suite("Batch insertion routing")
struct BatchInsertionRoutingTests {
    @Test(arguments: [false, true]) @MainActor
    func streamingKeepsTypingAndCorrections(typeBatchText: Bool) throws {
        let settings = SpySettings()
        settings.batchTypeText = typeBatchText
        let providers = SpyProviderSettings()
        providers.activeProviderId = ProviderId.deepgram
        let registry = SpyProviderRegistry()
        let provider = MockStreamingProvider()
        provider.isConfigured = true
        provider.mockSession = MockStreamingSession()
        registry.register(provider)
        let (controller, _, inserter, _) = makeTestRecordingController(
            providerSettings: providers, providerRegistry: registry, settings: settings
        )
        defer { controller.cancelRecording() }
        controller.startRecording()
        let streaming = try #require(controller.liveStreamingController)
        streaming.handleEvent(.interim(TranscriptionResult(transcript: "hello", isFinal: false)))
        streaming.handleEvent(.finalResult(TranscriptionResult(transcript: "help", isFinal: true, speechFinal: true)))
        #expect(inserter.replaceTailCallCount == 2)
        #expect(!inserter.insertedTexts.isEmpty)
        #expect(inserter.directlyInsertedTexts.isEmpty)
    }

    @Test @MainActor
    func directInsertionFailureBannerSurvivesLaterBatchResults() throws {
        let (controller, _, inserter, banner) = makeTestRecordingController()
        controller.isRecording = true
        let reportFailure = try #require(inserter.onDirectInsertionFailure)
        reportFailure()
        let dismissals = banner.dismissCount
        controller.transcription.queueBridge.onTextReady?("next")
        #expect(banner.dismissCount == dismissals)
        #expect(banner.bannerMessages.last?.0.contains("Type batch results") == true)
    }

    @Test @MainActor
    func batchDefaultsToDirectInsertion() {
        let (controller, _, inserter, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.transcription.queueBridge.onTextReady?("hello")
        #expect(inserter.directlyInsertedTexts == ["hello "])
        #expect(inserter.insertedTexts.isEmpty)
    }

    @Test @MainActor
    func batchCanUseExistingTyping() {
        let settings = SpySettings()
        settings.batchTypeText = true
        let (controller, _, inserter, _) = makeTestRecordingController(settings: settings)
        controller.isRecording = true
        controller.transcription.queueBridge.onTextReady?("hello")
        #expect(inserter.insertedTexts == ["hello "])
        #expect(inserter.directlyInsertedTexts.isEmpty)
    }
}

@Suite("Direct text insertion", .serialized)
struct TextInserterDirectTests {
    @MainActor
    private func makeInserter() -> TextInserter {
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter.testIsTargetFrontmost = true
        inserter._testSetTargetProcessLiveness { _ in true }
        inserter._testSetFlagsProvider { [] }
        return inserter
    }

    @Test @MainActor
    func replacesOnlySelectionInOneWriteWithoutKeyEvents() async {
        let inserter = makeInserter()
        var field = TextInserter.EditorSnapshot(text: "prefix old suffix", selection: NSRange(location: 7, length: 3))
        inserter.editorSnapshotForTesting = { field }
        var writes: [String] = []
        var events = 0
        inserter._testSetEventPoster { _ in events += 1 }
        inserter.replaceSelectedTextForTesting = { element, text in
            #expect(CFEqual(element, inserter.targetElement))
            writes.append(text)
            field.text = (field.text as NSString).replacingCharacters(in: field.selection, with: text)
            field.selection = NSRange(location: field.selection.location + text.utf16.count, length: 0)
            return .success
        }
        inserter.insertTextDirectly("hello 🌍\nnext")
        await inserter.waitForPendingInsertions()
        #expect(writes == ["hello 🌍\nnext"])
        #expect(field.text == "prefix hello 🌍\nnext suffix")
        #expect(events == 0)
    }

    @Test @MainActor
    func unsupportedEditorDoesNotTypeOrSubmitAndReportsFailureOnce() async {
        let inserter = makeInserter()
        inserter.editorSnapshotForTesting = { .init(text: "prefix ", selection: NSRange(location: 7, length: 0)) }
        var writes = 0
        var events = 0
        var failures = 0
        inserter.replaceSelectedTextForTesting = { _, _ in writes += 1; return .attributeUnsupported }
        inserter._testSetEventPoster { _ in events += 1 }
        inserter.onDirectInsertionFailure = { failures += 1 }
        inserter.insertTextDirectly("hello")
        inserter.insertTextDirectly("next")
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(writes == 1)
        #expect(events == 0)
        #expect(failures == 1)
    }
    @Test @MainActor
    func ignoredWriteBlocksSubmitWithoutRetryingOrTyping() async {
        let inserter = makeInserter()
        inserter.editorSnapshotForTesting = { .init(text: "", selection: NSRange(location: 0, length: 0)) }
        var writes = 0
        var events = 0
        var failures = 0
        inserter.replaceSelectedTextForTesting = { _, _ in writes += 1; return .success }
        inserter._testSetEventPoster { _ in events += 1 }
        inserter.onDirectInsertionFailure = { failures += 1 }
        inserter.insertTextDirectly("hello")
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(writes == 1)
        #expect(events == 0)
        #expect(failures == 1)
    }

    @Test @MainActor
    func focusAndModifiersGateDirectWriteAndEnterFollowsAllChunks() async throws {
        let inserter = makeInserter()
        var field = TextInserter.EditorSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        var fieldMatches = false
        var focusChecked = false
        var held = true
        var heldChecked = false
        var trace: [String] = []
        inserter.testIsTargetFrontmost = nil
        inserter._testSetFocusObserver {
            focusChecked = true
            return .init(focusedPid: 42_424, field: fieldMatches ? .same : .different)
        }
        inserter._testSetFlagsProvider { heldChecked = true; return held ? .maskShift : [] }
        inserter.editorSnapshotForTesting = { field }
        inserter.replaceSelectedTextForTesting = { _, text in
            #expect(!held && fieldMatches)
            trace.append(text)
            field.text += text
            field.selection.location = field.text.utf16.count
            return .success
        }
        inserter._testSetEventPoster { if $0.type == .keyDown { trace.append("Enter") } }
        inserter.insertTextDirectly("first ")
        inserter.insertTextDirectly("second ")
        inserter.pressEnterKey()
        try await waitUntil { focusChecked }
        #expect(trace.isEmpty)
        fieldMatches = true
        try await waitUntil { heldChecked }
        #expect(trace.isEmpty)
        held = false
        await inserter.waitForPendingInsertions()
        #expect(trace == ["first ", "second ", "Enter"])
        #expect(field.text == "first second ")
    }

    @Test(arguments: [false, true]) @MainActor
    func retiringSessionStopsEveryQueuedDirectWrite(reset: Bool) async throws {
        let inserter = makeInserter()
        var heldChecked = false
        inserter._testSetFlagsProvider { heldChecked = true; return .maskCommand }
        var writes = 0
        var events = 0
        inserter.replaceSelectedTextForTesting = { _, _ in writes += 1; return .success }
        inserter._testSetEventPoster { _ in events += 1 }
        inserter.insertTextDirectly("old one")
        let firstTask = inserter.pendingTask
        inserter.insertTextDirectly("old two")
        inserter.pressEnterKey()
        let tailTask = inserter.pendingTask
        try await waitUntil { heldChecked }
        if reset { inserter.reset() } else { inserter.cancelAndReset() }
        inserter._testSetFlagsProvider { [] }
        await firstTask?.value
        await tailTask?.value
        #expect(writes == 0)
        #expect(events == 0)
    }

    @Test @MainActor
    func missingTargetOrUnreadableEditorNeverWritesOrSubmits() async {
        for hasTarget in [false, true] {
            let inserter = makeInserter()
            if !hasTarget { inserter.targetElement = nil; inserter.targetPid = 0 }
            inserter.editorSnapshotForTesting = { nil }
            var writes = 0
            var events = 0
            var failures = 0
            inserter.replaceSelectedTextForTesting = { _, _ in writes += 1; return .success }
            inserter._testSetEventPoster { _ in events += 1 }
            inserter.onDirectInsertionFailure = { failures += 1 }
            inserter.insertTextDirectly("hello")
            inserter.pressEnterKey()
            await inserter.waitForPendingInsertions()
            #expect(writes == 0)
            #expect(events == 0)
            #expect(failures == 1)
        }
    }

    @Test @MainActor
    func retiredAcknowledgementCannotFailTheNextRecording() async throws {
        let inserter = makeInserter()
        var snapshots = 0
        var failures = 0
        inserter.editorSnapshotForTesting = {
            snapshots += 1
            return .init(text: "", selection: NSRange(location: 0, length: 0))
        }
        inserter.replaceSelectedTextForTesting = { _, _ in .success }
        inserter.onDirectInsertionFailure = { failures += 1 }
        inserter.insertTextDirectly("old")
        let pending = inserter.pendingTask
        // One initial snapshot plus twenty readbacks. Retire during the final wait.
        try await waitUntil(interval: .milliseconds(1)) { snapshots == 21 }
        inserter.cancelAndReset()
        await pending?.value
        #expect(failures == 0)
    }

}
