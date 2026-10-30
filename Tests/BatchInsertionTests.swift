import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Batch insertion settings")
struct BatchInsertionSettingsTests {
    @Test @MainActor
    func bulkInsertionIsDefaultAndTypingChoicePersists() throws {
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
        #expect(inserter.bulkInsertedTexts.isEmpty)
    }

    @Test @MainActor
    func bulkInsertionFailureBannerSurvivesLaterBatchResults() throws {
        let (controller, _, inserter, banner) = makeTestRecordingController()
        controller.isRecording = true
        let reportFailure = try #require(inserter.onBulkInsertionFailure)
        reportFailure()
        let dismissals = banner.dismissCount
        controller.transcription.queueBridge.onTextReady?("next")
        #expect(banner.dismissCount == dismissals)
        #expect(banner.bannerMessages.last?.0.contains("Automatic submit is disabled") == true)
    }

    @Test @MainActor
    func batchDefaultsToBulkInsertion() {
        let (controller, _, inserter, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.transcription.queueBridge.onTextReady?("hello")
        #expect(inserter.bulkInsertedTexts == ["hello "])
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
        #expect(inserter.bulkInsertedTexts.isEmpty)
    }
}

@Suite("Bulk text insertion", .serialized)
struct TextInserterBulkTests {
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

    private func payload(_ event: CGEvent) -> String {
        var length = 0
        var units = [UniChar](repeating: 0, count: BatchTextPayload.maxUTF16Length)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(utf16CodeUnits: units, count: length)
    }

    @Test(arguments: ["", "hello 🌍\nnext", String(repeating: "👩🏽‍💻e\u{301} ", count: 12), "e" + String(repeating: "\u{301}", count: 40)])
    func payloadBoundsPreserveUnicode(text: String) {
        let chunks = BatchTextPayload.chunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 })
    }

    @Test @MainActor
    func unreadableEditorReceivesWholePayloadsWithoutAccessibilityTextWrites() async {
        let inserter = makeInserter()
        var snapshots = 0
        inserter.editorSnapshotForTesting = { snapshots += 1; return nil }
        var downs: [String] = []
        var ups: [String] = []
        var failures = 0
        inserter.onBulkInsertionFailure = { failures += 1 }
        inserter._testSetEventPoster { event in
            #expect(event.flags.isEmpty)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == 49)
            if event.type == .keyDown { downs.append(payload(event)) }
            if event.type == .keyUp { ups.append(payload(event)) }
        }
        let text = "hello 🌍\nnext " + String(repeating: "sample ", count: 12)
        inserter.insertTextInBulk(text)
        await inserter.waitForPendingInsertions()
        #expect(downs == BatchTextPayload.chunks(text))
        #expect(ups == downs)
        #expect(downs.joined() == text)
        #expect(downs.count < text.count)
        #expect(snapshots == 0)
        #expect(failures == 0)
    }

    @Test @MainActor
    func focusAndModifiersGateBulkWriteAndEnterFollowsAllChunks() async throws {
        let inserter = makeInserter()
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
        inserter._testSetEventPoster { event in
            guard event.type == .keyDown else { return }
            #expect(!held && fieldMatches)
            trace.append(event.getIntegerValueField(.keyboardEventKeycode) == 36 ? "Enter" : payload(event))
        }
        inserter.insertTextInBulk("first ")
        inserter.insertTextInBulk("second ")
        inserter.pressEnterKey()
        try await waitUntil { focusChecked }
        #expect(trace.isEmpty)
        fieldMatches = true
        try await waitUntil { heldChecked }
        #expect(trace.isEmpty)
        held = false
        await inserter.waitForPendingInsertions()
        #expect(trace == ["first ", "second ", "Enter"])
    }

    @Test(arguments: [false, true]) @MainActor
    func retiringSessionStopsEveryQueuedBulkWrite(reset: Bool) async throws {
        let inserter = makeInserter()
        var heldChecked = false
        inserter._testSetFlagsProvider { heldChecked = true; return .maskCommand }
        var events = 0
        var failures = 0
        inserter._testSetEventPoster { _ in events += 1 }
        inserter.onBulkInsertionFailure = { failures += 1 }
        inserter.insertTextInBulk("old one")
        let firstTask = inserter.pendingTask
        inserter.insertTextInBulk("old two")
        inserter.pressEnterKey()
        let tailTask = inserter.pendingTask
        try await waitUntil { heldChecked }
        if reset { inserter.reset() } else { inserter.cancelAndReset() }
        inserter._testSetFlagsProvider { [] }
        await firstTask?.value
        await tailTask?.value
        #expect(events == 0)
        #expect(failures == 0)
    }

    @Test @MainActor
    func missingTargetNeverWritesOrSubmits() async {
        let inserter = makeInserter()
        inserter.targetElement = nil
        inserter.targetPid = 0
        var events = 0
        var failures = 0
        inserter._testSetEventPoster { _ in events += 1 }
        inserter.onBulkInsertionFailure = { failures += 1 }
        inserter.insertTextInBulk("hello")
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(events == 0)
        #expect(failures == 1)
    }

    @Test @MainActor
    func focusLossBetweenBurstsStopsTextAndWithholdsSubmit() async {
        let inserter = makeInserter()
        inserter._testSetFocusWaitTimeout(0.01)
        var downs: [String] = []
        var keyUps = 0
        var failures = 0
        inserter.onBulkInsertionFailure = { failures += 1 }
        inserter._testSetEventPoster { event in
            if event.type == .keyDown {
                downs.append(payload(event))
                inserter.testIsTargetFrontmost = false
            } else if event.type == .keyUp { keyUps += 1 }
        }
        let text = String(repeating: "sample ", count: 20)
        inserter.insertTextInBulk(text)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(downs == [BatchTextPayload.chunks(text)[0]])
        #expect(keyUps == 1)
        #expect(failures == 1)
    }

    @Test @MainActor
    func cancellingAfterKeyDownStillReleasesItAndRetiresRemainingBursts() async {
        let inserter = makeInserter()
        var downs = 0
        var ups = 0
        inserter._testSetEventPoster { event in
            if event.type == .keyDown { downs += 1; inserter.cancelAndReset() }
            if event.type == .keyUp { ups += 1 }
        }
        inserter.insertTextInBulk(String(repeating: "sample ", count: 20))
        let pending = inserter.pendingTask
        await pending?.value
        #expect(downs == 1)
        #expect(ups == 1)
    }
}
