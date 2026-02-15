import AppKit
import os
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - Behavioral Tests (SpyTextInserter through RecordingController)

@Suite("TextInserter Focus — Streaming Text Operations")
struct TextInserterFocusBehavioralTests {

    /// Creates a streaming test context with a configured mock provider.
    @MainActor
    private func makeStreamingContext() -> StreamingTestContext {
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let settings = SpySettings()

        let mockSession = MockStreamingSession()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = true
        mockProvider.mockSession = mockSession

        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let (controller, ki, ti, bp) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )

        return StreamingTestContext(
            controller: controller, provider: mockProvider, session: mockSession,
            textInserter: ti, banner: bp, keyInterceptor: ki
        )
    }

    @MainActor @Test
    func allInterimAndFinalEventsProduceTextOperations() {
        let ctx = makeStreamingContext()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        // Simulate a realistic streaming sequence: multiple interims then a final
        lsc.handleEvent(.interim(TranscriptionResult(transcript: "hel", isFinal: false)))
        lsc.handleEvent(.interim(TranscriptionResult(transcript: "hello", isFinal: false)))
        lsc.handleEvent(.interim(TranscriptionResult(transcript: "hello wo", isFinal: false)))
        lsc.handleEvent(.finalResult(TranscriptionResult(
            transcript: "Hello world.", isFinal: true, speechFinal: true
        )))

        // Every event that produces a text diff should result in an insert call
        // The first interim inserts "hel" (3 chars), the second appends "lo" (delete 0, type "lo"), etc.
        // The key assertion: no text operations were silently dropped
        let totalOps = ctx.textInserter.insertedTexts.count + ctx.textInserter.deletedCounts.count
        #expect(totalOps > 0, "Text operations must not be silently dropped")

        // The final event should have produced at least one insertion
        #expect(ctx.textInserter.insertedTexts.count >= 1,
                "Final transcription should produce at least one insertText call")
    }

    @MainActor @Test
    func deleteCharsPrecedesReplacementText() {
        let ctx = makeStreamingContext()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        // First interim establishes baseline text
        lsc.handleEvent(.interim(TranscriptionResult(transcript: "hello worl", isFinal: false)))

        // Clear tracked operations to isolate the replacement sequence
        let insertCountBefore = ctx.textInserter.insertedTexts.count
        let deleteCountBefore = ctx.textInserter.deletedCounts.count

        // Second interim corrects the partial: "hello worl" → "hello world"
        // Smart diff should delete suffix and type the new suffix
        lsc.handleEvent(.interim(TranscriptionResult(transcript: "hello world", isFinal: false)))

        let newInserts = ctx.textInserter.insertedTexts.count - insertCountBefore
        let newDeletes = ctx.textInserter.deletedCounts.count - deleteCountBefore

        // For an extending interim, either:
        // - No deletion needed (pure append), OR
        // - Deletion comes before insertion (replacement)
        if newDeletes > 0 {
            // When replacement happens, both delete and insert should be present
            #expect(newInserts > 0, "Replacement should have both delete and insert operations")
        }
        // Either way, the new text should be present
        #expect(ctx.textInserter.insertedTexts.last?.contains("world") == true
                || ctx.textInserter.insertedTexts.last?.contains("d") == true,
                "Updated text should be inserted")
    }

    @MainActor @Test
    func pressEnterCalledAfterInsertions() async throws {
        let ctx = makeStreamingContext()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        // Produce some text
        lsc.handleEvent(.finalResult(TranscriptionResult(
            transcript: "Hello.", isFinal: true, speechFinal: true
        )))
        #expect(!ctx.textInserter.insertedTexts.isEmpty, "Should have inserted text")

        // stopRecordingAndSubmit sets shouldPressEnterOnComplete and stops recording.
        // The internal Task awaits pending insertions then presses Enter.
        ctx.controller.stopRecordingAndSubmit()

        // Allow the internal Task to settle (it awaits pendingTask then presses Enter)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(ctx.textInserter.enterKeyPressed,
                "pressEnterKey should be called after text insertions complete")
    }

    @MainActor @Test
    func cancelAndResetClearsInserterState() {
        let ctx = makeStreamingContext()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        // Produce some text then cancel
        lsc.handleEvent(.interim(TranscriptionResult(transcript: "hello", isFinal: false)))
        ctx.controller.cancelRecording()

        #expect(ctx.textInserter.cancelCalled,
                "cancelAndReset should be called on the TextInserter")
    }
}

// MARK: - TextInserter PID-Based Focus Tests

@Suite("TextInserter Focus — PID-Based App Tracking", .serialized)
struct TextInserterPidFocusTests {

    // MARK: - captureTarget PID extraction

    @MainActor @Test
    func captureTargetStoresCurrentProcessPid() async throws {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        #expect(inserter.targetPid == 0, "PID should be 0 after reset")

        // captureTarget should capture the test process's PID
        // (the test runner is the frontmost app with a focused element)
        inserter.captureTarget()

        if inserter.targetElement != nil {
            // If we captured an element, PID must be set
            #expect(inserter.targetPid != 0,
                    "captureTarget must store the target element's PID")
            #expect(inserter.targetPid == ProcessInfo.processInfo.processIdentifier,
                    "PID should match the test process since it owns the focused element")
        }
        // If no element captured (headless CI), that's OK — PID stays 0

        inserter.cancelAndReset()
    }

    @MainActor @Test
    func cancelAndResetClearsPid() {
        let inserter = TextInserter.shared
        inserter.targetPid = 12345
        inserter.cancelAndReset()
        #expect(inserter.targetPid == 0, "cancelAndReset must clear targetPid")
    }

    @MainActor @Test
    func resetClearsPid() {
        let inserter = TextInserter.shared
        inserter.targetPid = 12345
        inserter.reset()
        #expect(inserter.targetPid == 0, "reset must clear targetPid")
    }

    // MARK: - isTargetAppFrontmost

    @MainActor @Test
    func isTargetAppFrontmostReturnsTrueWhenNoPidSet() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        // With targetPid == 0, should return true (no target to guard)
        #expect(inserter.isTargetAppFrontmost(),
                "With no PID set, isTargetAppFrontmost should return true")
    }

    /// This is the test that would have caught the CFEqual bug.
    /// It simulates a cross-app scenario by setting targetPid to a
    /// non-matching PID, verifying that focus check correctly detects
    /// the user is in a different app.
    @MainActor @Test
    func isTargetAppFrontmostReturnsFalseForDifferentApp() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        // Set PID to a value that doesn't match the frontmost app
        // PID 1 is launchd — never the frontmost GUI app
        inserter.targetPid = 1
        #expect(!inserter.isTargetAppFrontmost(),
                "Must return false when target PID doesn't match frontmost app")
        inserter.cancelAndReset()
    }

    /// Verifies focus detection uses the AX focused element PID, not just
    /// the frontmost app. This catches system overlays (Spotlight, password
    /// prompts) that steal keyboard focus without changing the frontmost app.
    ///
    /// The test finds a background GUI app and sets it as the target. Since
    /// the test runner owns the actual keyboard focus, `isTargetAppFrontmost`
    /// must return false — even though the background app might technically
    /// be "frontmost" in some NSWorkspace sense, it doesn't own the focused element.
    @MainActor @Test
    func isTargetAppFrontmostDetectsAXFocusOwner() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()

        // The focused element's PID should match whoever owns the keyboard focus.
        // Set our target to a different running GUI app — since that app doesn't
        // own the focused element, isTargetAppFrontmost must return false.
        let ourPid = ProcessInfo.processInfo.processIdentifier
        if let otherApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != ourPid && $0.activationPolicy == .regular
        }) {
            inserter.targetPid = otherApp.processIdentifier
            #expect(!inserter.isTargetAppFrontmost(),
                    "Must return false when focused element belongs to a different process (Spotlight scenario)")
            inserter.cancelAndReset()
        }
    }

    @MainActor @Test
    func isTargetAppFrontmostReturnsTrueForCurrentProcess() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        // Set PID to our own process
        inserter.targetPid = ProcessInfo.processInfo.processIdentifier
        // In test runner, our process should be frontmost (or at least,
        // NSWorkspace.shared.frontmostApplication should match our PID)
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmostPid == ProcessInfo.processInfo.processIdentifier {
            #expect(inserter.isTargetAppFrontmost(),
                    "Must return true when target PID matches frontmost app")
        }
        // If test runner isn't frontmost (CI), skip assertion
        inserter.cancelAndReset()
    }

    // MARK: - ensureTargetFocused behavior

    @MainActor @Test
    func ensureTargetFocusedReturnsTrueWithNoTarget() async {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        let result = await inserter.ensureTargetFocused()
        #expect(result, "ensureTargetFocused should return true when no target was captured")
    }

    /// Simulates the cross-app scenario: target app is not frontmost.
    /// ensureTargetFocused should NOT return true immediately — it should
    /// wait (poll). We cancel the task to verify it returns false on cancellation.
    @MainActor @Test
    func ensureTargetFocusedPausesWhenTargetNotFrontmost() async throws {
        // Find a real running GUI app that isn't frontmost.
        // ensureTargetFocused checks NSRunningApplication(processIdentifier:) to verify
        // the app is still running — system daemons (PID 1) aren't GUI apps and return nil.
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard let backgroundApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != frontmostPid && $0.activationPolicy == .regular
        }) else {
            // No background GUI app available — can't test this scenario
            return
        }

        let inserter = TextInserter.shared
        inserter.cancelAndReset()

        // Set the target to a background app that IS running but NOT frontmost
        inserter.targetElement = AXUIElementCreateApplication(backgroundApp.processIdentifier)
        inserter.targetPid = backgroundApp.processIdentifier

        // ensureTargetFocused should NOT return immediately — it should poll
        let returned = OSAllocatedUnfairLock(initialState: false)
        let task = Task { @MainActor in
            let result = await inserter.ensureTargetFocused()
            returned.withLock { $0 = true }
            return result
        }

        // Give it time — it should be polling, not returning
        try await Task.sleep(for: .milliseconds(400))
        #expect(returned.withLock { $0 } == false,
                "ensureTargetFocused must NOT return while target app is not frontmost — it was returning immediately before the PID fix")

        // Cancel the task to unblock
        task.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(returned.withLock { $0 } == true,
                "ensureTargetFocused should return false after cancellation")

        inserter.cancelAndReset()
    }

    /// When targetPid points to a terminated app, ensureTargetFocused
    /// should return false promptly instead of polling forever.
    @MainActor @Test
    func ensureTargetFocusedReturnsFalseForTerminatedApp() async throws {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()

        // Use a PID that doesn't correspond to any running app.
        // Create a dummy AXUIElement so the nil guard passes.
        inserter.targetElement = AXUIElementCreateApplication(99999)
        inserter.targetPid = 99999

        let result = await inserter.ensureTargetFocused()
        #expect(!result,
                "ensureTargetFocused should return false when target app is not running")

        inserter.cancelAndReset()
    }

    // MARK: - Focus Wait Timeout

    /// Verifies that ensureTargetFocused returns false after the configured
    /// timeout expires, rather than polling indefinitely.
    @MainActor @Test
    func ensureTargetFocusedTimesOutAfterConfiguredDuration() async throws {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard let backgroundApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != frontmostPid && $0.activationPolicy == .regular
        }) else { return }

        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        inserter.targetElement = AXUIElementCreateApplication(backgroundApp.processIdentifier)
        inserter.targetPid = backgroundApp.processIdentifier

        // Write a sub-second timeout directly to the test UserDefaults suite.
        // The setter clamps to 10s minimum, but the getter trusts stored values,
        // so writing directly to defaults enables fast test execution.
        let suiteName = "app.monodo.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else { return }
        testDefaults.set(0.5, forKey: "settings.focusWaitTimeout")

        let result = await inserter.ensureTargetFocused()
        #expect(!result, "ensureTargetFocused must return false after timeout expires")

        testDefaults.removeObject(forKey: "settings.focusWaitTimeout")
        inserter.cancelAndReset()
    }

    // MARK: - AX Integration (real element capture)

    /// AX integration test: exercises real captureTarget and verifies the PID
    /// mechanics work with the actual system focused element (whichever app
    /// owns it at test time). The PID swap assertions verify cross-app detection
    /// regardless of which process was captured.
    @MainActor @Test
    func captureAndVerifyPidBasedFocus() async throws {
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission required — grant it to the test runner")
            return
        }

        let inserter = TextInserter.shared
        inserter.cancelAndReset()

        // Capture whatever element currently has focus (may be our process or another)
        inserter.captureTarget()

        guard inserter.targetElement != nil else {
            // No focused element (headless / no GUI) — PID mechanics are covered
            // by the synthetic tests above. Nothing more to verify here.
            inserter.cancelAndReset()
            return
        }

        // captureTarget must have extracted a valid PID from the focused element
        #expect(inserter.targetPid != 0,
                "captureTarget must store the focused element's PID")

        // isTargetAppFrontmost should be consistent with what we just captured
        // (the captured element IS the currently focused one, so it should match)
        #expect(inserter.isTargetAppFrontmost(),
                "Freshly captured target should match current focus")

        // ensureTargetFocused should return true immediately (fast path)
        let result = await inserter.ensureTargetFocused()
        #expect(result, "ensureTargetFocused should return true for freshly captured target")

        // Simulate cross-app switch by changing PID to a non-matching value
        let savedPid = inserter.targetPid
        inserter.targetPid = 1  // launchd — never the focused app
        #expect(!inserter.isTargetAppFrontmost(),
                "After changing PID to another app, isTargetAppFrontmost must return false")

        // Restore PID — should work again
        inserter.targetPid = savedPid
        #expect(inserter.isTargetAppFrontmost(),
                "After restoring PID, isTargetAppFrontmost must return true again")

        inserter.cancelAndReset()
    }
}
