import AppKit
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - Behavioral Tests (SpyTextInserter through RecordingController)

@Suite("TextInserter Focus — Streaming Text Operations", .serialized)
struct TextInserterFocusBehavioralTests {

    /// Creates a streaming test context with a configured mock provider.
    @MainActor
    private func makeStreamingContext() -> StreamingTestContext {
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let settings = SpySettings()
        // Zero trailing-final timeout so tests complete without a real network wait.
        settings.streamingTrailingFinalTimeout = 0.0

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
        #expect(ctx.textInserter.replaceTailCallCount >= 1,
                "Streaming updates must use atomic replaceTail path")
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

        // Allow the internal Task to settle (awaits controller.stop() then presses Enter).
        // Uses waitUntil so the test is not coupled to any hardcoded sleep duration.
        try await waitUntil(timeout: .seconds(3)) { ctx.textInserter.enterKeyPressed }

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

@Suite("TextInserter Focus — Bundle Matching", .serialized)
struct TextInserterBundleMatchingTests {
    @Test
    func exactBundleMatchIsTrue() {
        #expect(
            TextInserter.bundleIdentifiersLikelySameApp(
                target: "com.google.Chrome",
                candidate: "com.google.Chrome"
            )
        )
    }

    @Test
    func helperBundleSuffixMatchesParentApp() {
        #expect(
            TextInserter.bundleIdentifiersLikelySameApp(
                target: "com.google.Chrome",
                candidate: "com.google.Chrome.helper"
            )
        )
        #expect(
            TextInserter.bundleIdentifiersLikelySameApp(
                target: "com.google.Chrome.helper",
                candidate: "com.google.Chrome"
            )
        )
    }

    @Test
    func unrelatedBundlesDoNotMatch() {
        #expect(
            !TextInserter.bundleIdentifiersLikelySameApp(
                target: "com.apple.TextEdit",
                candidate: "com.apple.Safari"
            )
        )
    }

    @Test
    func nilBundleDoesNotMatch() {
        #expect(
            !TextInserter.bundleIdentifiersLikelySameApp(
                target: "com.apple.TextEdit",
                candidate: nil
            )
        )
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

        // Determine the focused element PID first. In GUI test runs this may be
        // the test process or another currently focused app.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        var expectedPid: pid_t = 0
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
           let element = focusedElement,
           CFGetTypeID(element) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            let axElement = element as! AXUIElement
            _ = AXUIElementGetPid(axElement, &expectedPid)
        }

        inserter.captureTarget()

        if inserter.targetElement != nil {
            // If we captured an element, PID must be set
            #expect(inserter.targetPid != 0,
                    "captureTarget must store the target element's PID")
            if expectedPid != 0 {
                #expect(inserter.targetPid == expectedPid,
                        "PID should match the focused element owner at capture time")
            }
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

    /// This test protects the CFEqual-based focus comparison path.
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
    /// The test finds a background GUI app that does NOT own the focused element
    /// and sets it as the target. `isTargetAppFrontmost` must return false
    /// because the focused element belongs to a different process.
    @MainActor @Test
    func isTargetAppFrontmostDetectsAXFocusOwner() {
        guard AXIsProcessTrusted() else { return }

        // Resolve the PID of the process that currently owns keyboard focus.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedElement = focusedRef,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            // No focused element — skip in headless CI.
            return
        }

        // swiftlint:disable:next force_cast
        let focusedAX = focusedElement as! AXUIElement
        var focusedPid: pid_t = 0
        guard AXUIElementGetPid(focusedAX, &focusedPid) == .success, focusedPid != 0 else {
            return
        }
        let focusedBundle = NSRunningApplication(processIdentifier: focusedPid)?.bundleIdentifier

        let inserter = TextInserter.shared
        inserter.cancelAndReset()

        // Pick a background GUI app that does NOT own the focused element.
        // In CI, Finder is frontmost and owns the focused element, so we must
        // explicitly exclude it (and any app in the same bundle family).
        let ourPid = ProcessInfo.processInfo.processIdentifier
        if let otherApp = NSWorkspace.shared.runningApplications.first(where: {
            guard $0.processIdentifier != ourPid,
                  $0.processIdentifier != focusedPid,
                  $0.activationPolicy == .regular
            else { return false }
            // Also exclude apps in the same bundle family as the focused app.
            let otherBundle = $0.bundleIdentifier
            return !TextInserter.bundleIdentifiersLikelySameApp(
                target: focusedBundle,
                candidate: otherBundle
            )
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
        // Find a real running GUI app to use as the target.
        // ensureTargetFocused checks NSRunningApplication(processIdentifier:) to verify
        // the app is still running — system daemons (PID 1) aren't GUI apps and return nil.
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard let backgroundApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != frontmostPid && $0.activationPolicy == .regular
        }) else {
            // No background GUI app available — can't test this scenario
            return
        }

        let inserter = TextInserter._testMakeIsolatedInstance()

        // Force isTargetAppFrontmost() to return false deterministically.
        // Without this override, CI runners can flakily promote the target app
        // (e.g. Finder) to frontmost when the test process yields the main actor,
        // causing ensureTargetFocused to return immediately with true.
        inserter._testIsTargetFrontmost = false
        defer { inserter._testIsTargetFrontmost = nil }

        // Set the target to a running app so the "is still alive" guard passes.
        inserter.targetElement = AXUIElementCreateApplication(backgroundApp.processIdentifier)
        inserter.targetPid = backgroundApp.processIdentifier

        // ensureTargetFocused should NOT return immediately — it should poll and
        // then fail once the focus wait timeout expires.
        let originalTimeout = Settings.shared.focusWaitTimeout
        Settings.shared.focusWaitTimeout = 0.3
        defer { Settings.shared.focusWaitTimeout = originalTimeout }

        let result = await inserter.ensureTargetFocused()

        // The result must be false: true would mean the function incorrectly
        // treated the target as frontmost (regression: was returning immediately
        // with true before the PID fix was applied).
        #expect(!result,
                "ensureTargetFocused must return false — returning true means it incorrectly treated the target app as frontmost (pre-PID-fix regression)")
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

        // Force isTargetAppFrontmost() to return false deterministically so the
        // timeout logic is exercised regardless of live system frontmost state.
        inserter._testIsTargetFrontmost = false
        defer { inserter._testIsTargetFrontmost = nil; inserter.cancelAndReset() }

        inserter.targetElement = AXUIElementCreateApplication(backgroundApp.processIdentifier)
        inserter.targetPid = backgroundApp.processIdentifier

        // Write a sub-second timeout directly to the test UserDefaults suite.
        // The setter clamps to 10s minimum, but the getter trusts stored values,
        // so writing directly to defaults enables fast test execution.
        let suiteName = "nu.rez.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else { return }
        testDefaults.set(0.5, forKey: "settings.focusWaitTimeout")

        let result = await inserter.ensureTargetFocused()
        #expect(!result, "ensureTargetFocused must return false after timeout expires")

        testDefaults.removeObject(forKey: "settings.focusWaitTimeout")
    }

    // MARK: - AX Integration (real element capture)

    /// AX integration test: exercises real captureTarget and verifies the PID
    /// mechanics work with the actual system focused element (whichever app
    /// owns it at test time). The PID swap assertions verify cross-app detection
    /// regardless of which process was captured.
    @MainActor @Test
    func captureAndVerifyPidBasedFocus() async throws {
        guard AXIsProcessTrusted() else { return }

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

        // Note: the "different PID → false" case is covered by the dedicated unit test
        // isTargetAppFrontmostReturnsFalseForDifferentApp(), which starts from a clean
        // state (no targetBundleIdentifier) so the bundle-ID fallback cannot interfere.

        inserter.cancelAndReset()
    }
}

@Suite("TextInserter Queue Guard", .serialized)
struct TextInserterQueueGuardTests {
    @MainActor @Test
    func queuedOperationsRemainSerializedWhenSecondChunkArrivesMidTyping() async {
        let inserter = TextInserter._testMakeIsolatedInstance()

        var trace: [String] = []

        inserter._testEnqueueSimulatedOperation(
            label: "chunk1",
            delayNanoseconds: 50_000_000
        ) { trace.append($0) }

        inserter._testEnqueueSimulatedOperation(label: "chunk2") { trace.append($0) }

        await inserter.waitForPendingInsertions()

        #expect(
            trace == ["start:chunk1", "end:chunk1", "start:chunk2", "end:chunk2"],
            "A second queued chunk must not start typing until the first queued chunk fully completes"
        )
        #expect(inserter._testQueuedInsertionCount == 0,
                "Queue depth should return to zero after all serialized work completes")
    }

    @MainActor @Test
    func replaceTailQueuesDeleteAndInsertAtomically() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        defer {
            inserter._testIsTargetFrontmost = nil
            inserter.cancelAndReset()
        }

        // Keep the first queued task blocked so queue depth is stable for assertion.
        inserter.targetElement = AXUIElementCreateSystemWide()
        inserter.targetPid = NSRunningApplication.current.processIdentifier
        inserter._testIsTargetFrontmost = false

        inserter.replaceTail(replacingChars: 2, with: "abc")

        #expect(
            inserter._testQueuedInsertionCount == 1,
            "replaceTail should enqueue delete+insert as one atomic queue operation"
        )
    }

    @MainActor @Test
    func deleteCharsRespectsQueueCap() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        defer { inserter.cancelAndReset() }

        let attempts = Config.maxQueuedTextInsertions + 25
        for _ in 0..<attempts {
            inserter.deleteChars(1)
        }

        #expect(
            inserter._testQueuedInsertionCount == Config.maxQueuedTextInsertions,
            "deleteChars must honor maxQueuedTextInsertions just like insertText"
        )
    }

    @MainActor @Test
    func replaceTailRespectsQueueCap() {
        let inserter = TextInserter.shared
        inserter.cancelAndReset()
        defer {
            inserter._testIsTargetFrontmost = nil
            inserter.cancelAndReset()
        }

        // Keep queued work pending so cap checks are observable.
        inserter.targetElement = AXUIElementCreateSystemWide()
        inserter.targetPid = NSRunningApplication.current.processIdentifier
        inserter._testIsTargetFrontmost = false

        let attempts = Config.maxQueuedTextInsertions + 25
        for _ in 0..<attempts {
            inserter.replaceTail(replacingChars: 1, with: "x")
        }

        #expect(
            inserter._testQueuedInsertionCount == Config.maxQueuedTextInsertions,
            "replaceTail must honor maxQueuedTextInsertions"
        )
    }
}
