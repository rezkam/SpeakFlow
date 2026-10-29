import ApplicationServices
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Acknowledged streaming text delivery", .serialized)
struct StreamingTextDeliveryTests {
    @MainActor
    private func fixture() -> (RecordingController, TextInserter, TextInserterCancellationTests.PostRecorder) {
        let inserter = TextInserter._testMakeIsolatedInstance()
        let posted = TextInserterCancellationTests.PostRecorder()
        inserter.captureTargetForTesting = { [weak inserter] in
            inserter?.targetElement = AXUIElementCreateApplication(42_424)
            inserter?.targetPid = 42_424
            return true
        }
        inserter._testSetTargetProcessLiveness { $0 == 42_424 }
        inserter._testSetFlagsProvider { [] }
        inserter._testSetFocusObserver { .init(focusedPid: 42_424, field: .same) }
        inserter.editorSnapshotForTesting = {
            var text = ""
            for (code, value) in zip(posted.keyCodes, posted.keyDowns) {
                if code == 51 { if !text.isEmpty { text.removeLast() } }
                else if code != 36 { text += value }
            }
            return .init(text: text, selection: NSRange(location: text.utf16.count, length: 0))
        }
        inserter._testSetEventPoster { posted.record($0) }
        let providers = SpyProviderSettings()
        providers.activeProviderId = ProviderId.deepgram
        providers.storedKeys[ProviderId.deepgram] = "synthetic-key"
        let registry = SpyProviderRegistry()
        let provider = MockStreamingProvider()
        provider.mockSession = MockStreamingSession()
        registry.register(provider)
        let settings = SpySettings()
        settings.streamingKeepAliveEnabled = false
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(), textInserter: inserter, appState: SpyBannerPresenter(),
            providerSettings: providers, providerRegistry: registry, settings: settings,
            transcription: SpyTranscription(), playSoundEffect: { _ in }
        )
        controller.testMode = .live
        return (controller, inserter, posted)
    }

    @Test @MainActor
    func terminalSnapshotAtCapacitySettlesBeforeEnter() async throws {
        let (_, inserter, posted) = fixture()
        #expect(inserter.captureTarget())
        // Fill the real queue synchronously so none of its tasks can drain yet.
        for _ in 0..<Config.maxQueuedTextInsertions { inserter.insertText("x") }
        for index in 0..<100 { inserter.updateStreamingText("draft\(index)", isFinal: false) }
        inserter.updateStreamingText("terminal", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(posted.keyDowns.dropLast().joined() == String(repeating: "x", count: Config.maxQueuedTextInsertions) + "terminal ")
        #expect(posted.keyCodes.last == 36)
        #expect(posted.keyCodes.filter { $0 == 36 }.count == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func resetRetiresCoalescedSnapshotsAndEnter(cancel: Bool) async {
        let (_, inserter, posted) = fixture()
        #expect(inserter.captureTarget())
        for _ in 0..<Config.maxQueuedTextInsertions { inserter.insertText("old") }
        inserter.updateStreamingText("retired", isFinal: true)
        inserter.pressEnterKey()
        let oldTail = inserter.pendingTask
        if cancel { inserter.cancelAndReset() } else { inserter.reset() }
        #expect(inserter.captureTarget())
        inserter.updateStreamingText("fresh", isFinal: true)
        await oldTail?.value
        await inserter.waitForPendingInsertions()
        #expect(posted.keyDowns.joined() == "fresh ")
        #expect(!posted.keyCodes.contains(36))
    }

    @Test @MainActor
    func laterSegmentReconcilesARejectedFinalBeforeAppending() async throws {
        let (controller, inserter, posted) = fixture()
        defer { controller.cancelRecording() }
        controller.startRecording()
        let stream = try #require(controller.liveStreamingController)
        try await waitUntil { stream.isActive }
        inserter._testSetQueuedInsertionCount(Config.maxQueuedTextInsertions)
        stream.handleEvent(.finalResult(TranscriptionResult(transcript: "hello", isFinal: true, speechFinal: true)))
        inserter._testSetQueuedInsertionCount(0)
        stream.handleEvent(.interim(TranscriptionResult(transcript: "world", isFinal: false)))
        await inserter.waitForPendingInsertions()
        #expect(posted.keyDowns.joined() == "hello world", "Rejected final text must remain part of the next desired snapshot")
        #expect(!posted.keyCodes.contains(51))
    }

    @Test @MainActor
    func correctionAfterPartialDeletionUsesTheRemainingPostedTail() async throws {
        let (controller, inserter, posted) = fixture()
        defer { controller.cancelRecording() }
        var focused = true
        var interrupted = false
        var field = "existing "
        inserter._testSetFocusWaitTimeout(0)
        inserter._testSetFocusObserver { .init(focusedPid: 42_424, field: focused ? .same : .different) }
        inserter._testSetEventPoster { event in
            posted.record(event)
            let deleting = event.getIntegerValueField(.keyboardEventKeycode) == 51
            if event.type == .keyDown {
                if deleting { field.removeLast() }
                else { field += posted.keyDowns.last ?? "" }
            }
            if event.type == .keyUp, deleting, !interrupted { interrupted = true; focused = false }
        }
        controller.startRecording()
        let stream = try #require(controller.liveStreamingController)
        try await waitUntil { stream.isActive }
        stream.handleEvent(.interim(TranscriptionResult(transcript: "hello", isFinal: false)))
        await inserter.waitForPendingInsertions()
        stream.handleEvent(.interim(TranscriptionResult(transcript: "hi", isFinal: false)))
        await inserter.waitForPendingInsertions()
        #expect(field == "existing hell", "Deletion must stop after its first posted key pair")
        focused = true
        stream.handleEvent(.interim(TranscriptionResult(transcript: "help", isFinal: false)))
        await inserter.waitForPendingInsertions()
        #expect(field == "existing help", "Resume from the actual remaining tail, not either proposed snapshot")
        #expect(posted.keyCodes.filter { $0 == 51 }.count == 2)
    }

    @Test @MainActor
    func correctionAfterPartialTypingUsesOnlyPostedCharacters() async throws {
        let (controller, inserter, posted) = fixture()
        defer { controller.cancelRecording() }
        var focused = true
        inserter._testSetFocusWaitTimeout(0)
        inserter._testSetFocusObserver { .init(focusedPid: 42_424, field: focused ? .same : .different) }
        inserter._testSetEventPoster { event in
            posted.record(event)
            if event.type == .keyUp, posted.keyUps == 2 { focused = false }
        }
        controller.startRecording()
        let stream = try #require(controller.liveStreamingController)
        try await waitUntil { stream.isActive }
        stream.handleEvent(.interim(TranscriptionResult(transcript: "hello", isFinal: false)))
        await inserter.waitForPendingInsertions()
        #expect(posted.keyDowns.joined() == "he", "The first snapshot must time out after partial delivery")
        focused = true
        stream.handleEvent(.interim(TranscriptionResult(transcript: "help", isFinal: false)))
        await inserter.waitForPendingInsertions()
        #expect(!posted.keyCodes.contains(51), "Only he reached the field; neither character needs deletion")
        #expect(posted.keyDowns.joined() == "help")
    }

    @Test @MainActor
    func rejectedInterimCannotAuthorizeDeletingExistingFieldText() async throws {
        let (controller, inserter, posted) = fixture()
        defer { controller.cancelRecording() }
        controller.startRecording()
        let stream = try #require(controller.liveStreamingController)
        try await waitUntil { stream.isActive }
        inserter._testSetQueuedInsertionCount(Config.maxQueuedTextInsertions)
        stream.handleEvent(.interim(TranscriptionResult(transcript: "hello", isFinal: false)))
        inserter._testSetQueuedInsertionCount(0)
        stream.handleEvent(.interim(TranscriptionResult(transcript: "help", isFinal: false)))
        await inserter.waitForPendingInsertions()

        #expect(!posted.keyCodes.contains(51), "Rejected text never authorizes a backspace into existing field content")
        #expect(posted.keyDowns.joined() == "help", "Reconciliation must type the complete undelivered snapshot")
    }
}
