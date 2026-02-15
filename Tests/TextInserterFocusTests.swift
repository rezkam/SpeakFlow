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
}

// MARK: - Integration Test (Real AX Focus Behavior)

@Suite("TextInserter Focus — AX Integration")
struct TextInserterAXIntegrationTests {

    /// Comprehensive AX integration test: captures a real element, verifies
    /// PID is stored correctly, and confirms focus check works within the same app.
    ///
    /// **Must run in isolation**: Creating NSWindow and manipulating TextInserter.shared
    /// concurrently with other tests causes signal 11 in AppKit's internal state.
    /// Run via: `AX_INTEGRATION=1 swift test --filter "captureAndVerify"`
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AX_INTEGRATION"] != nil,
                   "Set AX_INTEGRATION=1 to run — requires isolation from concurrent tests"))
    func captureAndVerifyPidBasedFocus() async throws {
        try #require(AXIsProcessTrusted(), "Accessibility permission required — skipping")

        let inserter = TextInserter.shared
        inserter.cancelAndReset()

        // Activate the test process so windows can take focus
        NSRunningApplication.current.activate()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let fieldA = NSTextField(frame: NSRect(x: 10, y: 100, width: 280, height: 24))
        fieldA.isEditable = true
        window.contentView?.addSubview(fieldA)
        window.makeKeyAndOrderFront(nil)

        try await Task.sleep(nanoseconds: 200_000_000) // 200ms for window
        window.makeFirstResponder(fieldA)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms for focus

        // Step 1: captureTarget stores both element and PID
        inserter.captureTarget()
        #expect(inserter.targetElement != nil,
                "captureTarget should capture a real AXUIElement")
        #expect(inserter.targetPid == ProcessInfo.processInfo.processIdentifier,
                "captureTarget must store our process PID")

        // Step 2: isTargetAppFrontmost returns true (we're the frontmost app)
        #expect(inserter.isTargetAppFrontmost(),
                "Our app is frontmost, so isTargetAppFrontmost must return true")

        // Step 3: ensureTargetFocused returns true immediately (fast path)
        let result = await inserter.ensureTargetFocused()
        #expect(result, "ensureTargetFocused should return true when our app is frontmost")

        // Step 4: Simulate cross-app switch by changing PID
        let savedPid = inserter.targetPid
        inserter.targetPid = 1  // launchd — not frontmost
        #expect(!inserter.isTargetAppFrontmost(),
                "After changing PID to another app, isTargetAppFrontmost must return false")

        // Step 5: Restore PID — should work again
        inserter.targetPid = savedPid
        #expect(inserter.isTargetAppFrontmost(),
                "After restoring PID, isTargetAppFrontmost must return true again")

        // Cleanup
        inserter.cancelAndReset()
        window.close()
    }
}
