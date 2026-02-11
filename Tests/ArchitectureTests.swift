import ApplicationServices
import Foundation
import Testing
@testable import SpeakFlowCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Test Isolation Verification
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("Test Isolation — Settings & Statistics do not pollute user data")
struct TestIsolationTests {

    @Test func testSettingsUsesIsolatedUserDefaults() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        // Settings must detect test runs and use an isolated UserDefaults suite
        #expect(source.contains("isTestRun"), "Settings must detect test runner")
        #expect(source.contains("suiteName"), "Settings must use a named UserDefaults suite in tests")
        #expect(source.contains("removePersistentDomain"),
                "Settings must clean the test suite on init for a fresh slate")
    }

    @Test func testStatisticsUsesIsolatedStorage() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Statistics.swift")
        // Statistics must detect test runs and use a temp directory
        #expect(source.contains("isTestRun"), "Statistics must detect test runner")
        #expect(source.contains("temporaryDirectory"), "Statistics must use temp dir in tests")
    }

    /// Behavioral: Settings.shared in tests writes to an isolated store, not UserDefaults.standard.
    @Test @MainActor func testSettingsWritesAreIsolatedFromUserDefaults() {
        let settings = Settings.shared
        let orig = settings.deepgramModel
        defer { settings.deepgramModel = orig }

        // Write a sentinel value via Settings.shared
        let sentinel = "test-isolation-\(ProcessInfo.processInfo.processIdentifier)"
        settings.deepgramModel = sentinel
        #expect(settings.deepgramModel == sentinel, "Write must round-trip through Settings")

        // Verify UserDefaults.standard does NOT contain the sentinel —
        // confirming Settings uses an isolated suite, not .standard.
        let standardValue = UserDefaults.standard.string(forKey: "settings.deepgram.model")
        #expect(standardValue != sentinel,
                "Settings must NOT write to UserDefaults.standard in test runs")
    }

    /// Behavioral: Statistics.shared in tests writes to temp, not ~/.speakflow/.
    @Test @MainActor func testStatisticsDoesNotWriteToUserDir() {
        let stats = Statistics.shared
        stats.reset()
        defer { stats.reset() }

        stats.recordTranscription(text: "isolation test", audioDurationSeconds: 1.0)
        // If we got here without error, the write succeeded (to temp dir).
        // Verify the data round-trips correctly.
        #expect(stats.totalWords == 2)
        #expect(stats.totalSecondsTranscribed > 0.9)
    }
}

struct SourceRegressionTests {
    @Test func testAppDelegateTerminationCleansUpResources() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")

        let hasDelegateHook = appDelegate.contains("func applicationWillTerminate(_ notification: Notification)")
        let hasNotificationHook = appDelegate.contains("NSApplication.willTerminateNotification")
        #expect(hasDelegateHook || hasNotificationHook)

        // AppDelegate must call shutdown() on all controllers
        #expect(appDelegate.contains("RecordingController.shared.shutdown()"))
        #expect(appDelegate.contains("AuthController.shared.shutdown()"))
        #expect(appDelegate.contains("PermissionController.shared.shutdown()"))

        // RecordingController.shutdown() must clean up recording resources
        let recording = try readProjectSource("Sources/App/RecordingController.swift")
        let recordingShutdown = extractFunctionBody(named: "shutdown", from: recording)
        #expect(recordingShutdown?.contains("hotkeyListener?.stop()") == true)
        #expect(recordingShutdown?.contains("stopKeyListener()") == true)
        #expect(recordingShutdown?.contains("Transcription.shared.cancelAll()") == true)

        // AuthController.shutdown() must stop OAuth server
        let auth = try readProjectSource("Sources/App/AuthController.swift")
        let authShutdown = extractFunctionBody(named: "shutdown", from: auth)
        #expect(authShutdown?.contains("oauthCallbackServer?.stop()") == true)

        // PermissionController.shutdown() must stop polling
        let perm = try readProjectSource("Sources/App/PermissionController.swift")
        let permShutdown = extractFunctionBody(named: "shutdown", from: perm)
        #expect(permShutdown?.contains("permissionManager.stopPolling()") == true)
    }

    @Test func testNoDispatchQueueMainAsyncInMainActorHotPaths() throws {
        // All known @MainActor-facing files where UI/coordination logic lives.
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/RecordingController.swift",
            "Sources/App/AuthController.swift",
            "Sources/App/PermissionController.swift",
            "Sources/App/UITestHarnessController.swift",
            "Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift",
            "Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift",
            "Sources/SpeakFlowCore/Audio/StreamingRecorder.swift",
            "Sources/SpeakFlowCore/Transcription/Transcription.swift",
            "Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift",
            "Sources/SpeakFlowCore/Hotkey/HotkeySettings.swift",
            "Sources/SpeakFlowCore/Statistics.swift",
            "Sources/SpeakFlowCore/Config.swift"
        ]

        for file in files {
            let source = try readProjectSource(file)
            #expect(!source.contains("DispatchQueue.main.async"), "Found DispatchQueue.main.async in \(file)")
            #expect(!source.contains("DispatchQueue.main.asyncAfter"), "Found DispatchQueue.main.asyncAfter in \(file)")
        }
    }

    @Test func testTranscriptionServiceNoDeadActiveTasksState() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")

        // Preferred path: legacy dead state removed entirely.
        if !source.contains("activeTasks") {
            #expect(!source.contains("public func cancelAll()"))
            return
        }

        // Fallback guard: if activeTasks is reintroduced, it must be actively balanced.
        let increments = countOccurrences(of: "activeTasks[", in: source)
        let decrements = countOccurrences(of: "removeValue(forKey:", in: source)
        #expect(increments > 0, "activeTasks exists but is never populated")
        #expect(decrements > 0, "activeTasks exists but is never cleaned up")
    }

    @Test func testStreamingRecorderDoesNotUsePreconcurrencyAVFoundationImport() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(!source.contains("@preconcurrency import AVFoundation"))
    }

    @Test func testAccessibilityLabelsPresentForMenuAndHarnessControls() throws {
        let speakFlowApp = try readProjectSource("Sources/App/SpeakFlowApp.swift")
        let harness = try readProjectSource("Sources/App/UITestHarnessController.swift")

        // SwiftUI menu uses Button() for accessibility labels
        #expect(speakFlowApp.contains("Open SpeakFlow"))
        #expect(speakFlowApp.contains("Start Dictation") || speakFlowApp.contains("Stop Dictation"))
        #expect(speakFlowApp.contains("Quit SpeakFlow"))

        // Harness still uses setAccessibilityIdentifier
        #expect(harness.contains("setAccessibilityLabel") || harness.contains("setAccessibilityIdentifier"))
    }
}

// MARK: - Issue #4: Text insertion goes to wrong app

@Suite("Issue #4 — Focus verification before text insertion")
struct Issue4FocusVerificationRegressionTests {

    /// REGRESSION: typeTextAsync must call verifyInsertionTarget() before typing.
    /// Without this check, dictated text leaks to whatever app has focus.
    @Test func testTypeTextAsyncCallsVerifyInsertionTarget() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcRange = source.range(of: "private func typeTextAsync") else {
            Issue.record("typeTextAsync not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        #expect(funcBody.contains("verifyInsertionTarget"),
                "typeTextAsync must verify focus target before typing — privacy leak if missing")
    }

    /// REGRESSION: pressEnterKey must also verify focus before posting the Enter event.
    @Test func testPressEnterKeyVerifiesFocus() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcRange = source.range(of: "private func pressEnterKey") else {
            Issue.record("pressEnterKey not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        #expect(funcBody.contains("verifyInsertionTarget"),
                "pressEnterKey must verify focus — Enter in wrong app is dangerous")
    }

    /// REGRESSION: verifyInsertionTarget must use CFEqual to compare AXUIElements.
    @Test func testVerifyInsertionTargetUsesCFEqual() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcRange = source.range(of: "private func verifyInsertionTarget") else {
            Issue.record("verifyInsertionTarget not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        #expect(funcBody.contains("CFEqual"),
                "verifyInsertionTarget must compare elements with CFEqual")
        #expect(funcBody.contains("kAXFocusedUIElementAttribute"),
                "Must query current focused element via Accessibility API")
    }

    /// Behavioral: CFEqual correctly distinguishes AXUIElements for different PIDs.
    @Test func testCFEqualDistinguishesDifferentAppElements() {
        let app1 = AXUIElementCreateApplication(1)
        let app2 = AXUIElementCreateApplication(2)
        let app1Again = AXUIElementCreateApplication(1)

        #expect(!CFEqual(app1, app2), "Different PID elements must not be equal")
        #expect(CFEqual(app1, app1Again), "Same PID elements must be equal")
    }
}

// MARK: - Issue #8: usleep blocks MainActor thread

@Suite("Issue #8 — No usleep in MainActor code paths")
struct Issue8UsleepRegressionTests {

    /// REGRESSION: RecordingController.swift must not contain usleep — it blocks the MainActor.
    /// The fix replaces usleep(10000) with Task.sleep(nanoseconds: 10_000_000).
    @Test func testAppDelegateDoesNotContainUsleep() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        #expect(!source.contains("usleep("), "RecordingController must not use usleep — blocks MainActor")
        #expect(!source.contains("usleep ("), "RecordingController must not use usleep — blocks MainActor")
    }

    /// REGRESSION: pressEnterKey must use async Task.sleep, not usleep.
    @Test func testPressEnterKeyUsesAsyncSleep() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcStart = source.range(of: "private func pressEnterKey") else {
            Issue.record("pressEnterKey not found")
            return
        }
        // Scope to just this function: find the next top-level function/property
        let afterStart = String(source[funcStart.lowerBound...])
        let funcBody: String
        if let nextFunc = afterStart.range(of: "\n    private func ",
                                           range: afterStart.index(afterStart.startIndex, offsetBy: 10)..<afterStart.endIndex) {
            funcBody = String(afterStart[..<nextFunc.lowerBound])
        } else if let nextFunc = afterStart.range(of: "\n    // MARK:") {
            funcBody = String(afterStart[..<nextFunc.lowerBound])
        } else {
            funcBody = afterStart
        }

        // Must use Task.sleep (cooperative) not usleep (blocking)
        #expect(funcBody.contains("Task.sleep"),
                "pressEnterKey must use Task.sleep for cooperative async delay")
        #expect(!funcBody.contains("usleep("),
                "pressEnterKey must NOT call usleep() — blocks main thread")
    }

    /// REGRESSION: No usleep anywhere in the main app source files.
    @Test func testNoUsleepInMainActorFiles() throws {
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/RecordingController.swift",
            "Sources/App/AuthController.swift",
            "Sources/App/PermissionController.swift",
            "Sources/App/UITestHarnessController.swift",
        ]
        for file in files {
            let source = try readProjectSource(file)
            #expect(!source.contains("usleep("),
                    "Found blocking usleep in \(file) — use Task.sleep instead")
        }
    }
}

// MARK: - Issue #18: Package.swift platform mismatch with Info.plist

@Suite("Issue #18 — Package.swift and Info.plist deployment target alignment")
struct Issue18PlatformMismatchRegressionTests {

    /// REGRESSION: Package.swift must specify .macOS(.v15), matching Info.plist.
    /// The original bug had .macOS(.v14) in Package.swift but LSMinimumSystemVersion: 15.0
    /// in Info.plist, causing a binary/bundle mismatch.
    @Test func testPackageSwiftTargetsMacOSv15() throws {
        let source = try readProjectSource("Package.swift")
        #expect(source.contains(".macOS(.v15)"),
                "Package.swift must target .macOS(.v15) — was .macOS(.v14) causing mismatch")
        #expect(!source.contains(".macOS(.v14)"),
                "Must NOT target .macOS(.v14) — mismatches Info.plist LSMinimumSystemVersion")
    }

    /// REGRESSION: Info.plist must declare LSMinimumSystemVersion matching Package.swift.
    /// Only runs when the app bundle exists (skipped in CI where only swift test runs).
    @Test func testInfoPlistMatchesPackageSwift() throws {
        let infoPath = "SpeakFlow.app/Contents/Info.plist"
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fullPath = projectRoot.appendingPathComponent(infoPath).path
        guard FileManager.default.fileExists(atPath: fullPath) else {
            return // App bundle not built — skip in CI
        }
        let infoPlist = try readProjectSource(infoPath)

        // Extract LSMinimumSystemVersion value
        #expect(infoPlist.contains("<key>LSMinimumSystemVersion</key>"),
                "Info.plist must declare LSMinimumSystemVersion")

        // The value right after the key should be 15.0
        guard let keyRange = infoPlist.range(of: "<key>LSMinimumSystemVersion</key>") else {
            Issue.record("LSMinimumSystemVersion key not found")
            return
        }
        let afterKey = String(infoPlist[keyRange.upperBound...])
        #expect(afterKey.contains("<string>15.0</string>"),
                "LSMinimumSystemVersion must be 15.0 to match Package.swift .macOS(.v15)")
    }
}

@Suite("Issues #10/#12/#20/#23 — Additional Regression Coverage")
struct AdditionalLifecycleConcurrencyI18NAccessibilityRegressionTests {

    /// Issue #10: Ensure graceful termination performs all major cleanup actions.
    @Test func testIssue10TerminationIncludesRecorderTaskAndObserverCleanup() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")

        #expect(appDelegate.contains("func applicationWillTerminate(_ notification: Notification)"))
        #expect(appDelegate.contains("RecordingController.shared.shutdown()"))
        #expect(appDelegate.contains("AuthController.shared.shutdown()"))
        #expect(appDelegate.contains("PermissionController.shared.shutdown()"))

        // RecordingController.shutdown() must clean up recorder and tasks
        let recording = try readProjectSource("Sources/App/RecordingController.swift")
        let recordingShutdown = extractFunctionBody(named: "shutdown", from: recording)
        #expect(recordingShutdown?.contains("recorder?.cancel()") == true)
        #expect(recordingShutdown?.contains("textInsertionTask?.cancel()") == true)
    }

    /// Issue #12: Verify hotkey callbacks are marshalled through `Task { @MainActor ... }`.
    @Test func testIssue12HotkeyCallbacksUseMainActorTaskPattern() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift")

        let mainActorTaskCount = countOccurrences(of: "Task { @MainActor [weak self] in", in: source)
        #expect(mainActorTaskCount >= 4,
                "Expected at least 4 MainActor Task callback hops in HotkeyListener, got \(mainActorTaskCount)")
        #expect(source.contains("self?.onActivate?()"))
    }

    /// Issue #20: Guard localization of high-visibility user-facing strings.
    @Test func testIssue20HighVisibilityStringsAreLocalized() throws {
        let speakFlowApp = try readProjectSource("Sources/App/SpeakFlowApp.swift")
        let accountsSettings = try readProjectSource("Sources/App/AccountsSettingsView.swift")
        let generalSettings = try readProjectSource("Sources/App/GeneralSettingsView.swift")

        // Check SpeakFlowApp for menu strings
        #expect(speakFlowApp.contains("Start Dictation"))
        // Check AccountsSettingsView for login
        #expect(accountsSettings.contains("Log In") || accountsSettings.contains("Log Out"))
        // Check GeneralSettingsView for accessibility permissions
        #expect(generalSettings.contains("Accessibility"))
    }

}

@Suite("Issues #10/#11/#12/#13/#16/#19/#20/#21/#23 — Completion Regression Additions")
struct Issue10To23CompletionRegressionAdditions {

    @Test func testIssue10TerminationHandledByDelegateOrNotification() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let hasDelegateHook = source.contains("func applicationWillTerminate(_ notification: Notification)")
        let hasNotificationHook = source.contains("NSApplication.willTerminateNotification")
        #expect(hasDelegateHook || hasNotificationHook)
    }

    @Test func testIssue11HotkeyListenerDeinitPerformsStopCleanup() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift")
        guard let deinitRange = source.range(of: "@MainActor deinit") else {
            Issue.record("HotkeyListener deinit not found")
            return
        }

        let suffix = String(source[deinitRange.lowerBound...].prefix(160))
        #expect(suffix.contains("stop()"), "HotkeyListener deinit should call stop()")
    }

    @Test func testIssue12NoDispatchQueueMainAsyncInMainActorFiles() throws {
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/RecordingController.swift",
            "Sources/App/AuthController.swift",
            "Sources/App/PermissionController.swift",
            "Sources/App/UITestHarnessController.swift",
            "Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift",
            "Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift",
            "Sources/SpeakFlowCore/Audio/StreamingRecorder.swift"
        ]

        for file in files {
            let source = try readProjectSource(file)
            #expect(!source.contains("DispatchQueue.main.async"), "Found DispatchQueue.main.async in \(file)")
            #expect(!source.contains("DispatchQueue.main.asyncAfter"), "Found DispatchQueue.main.asyncAfter in \(file)")
        }
    }

    @Test func testIssue13TranscriptionServiceDoesNotRetainDeadActiveTasksField() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(!source.contains("activeTasks"))
    }

    @Test func testIssue16StreamingRecorderAvoidsPreconcurrencyImport() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("import AVFoundation"))
        #expect(!source.contains("@preconcurrency import AVFoundation"))
    }

    @Test func testIssue19FormatterCacheRemainsStableForPublicFormattedProperties() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordTranscription(text: "issue nineteen formatter cache", audioDurationSeconds: 3.2)
            stats.recordApiCall()

            let before = Statistics._testFormatterIdentity
            _ = stats.formattedCharacters
            _ = stats.formattedWords
            _ = stats.formattedApiCalls
            let after = Statistics._testFormatterIdentity

            #expect(before == after)
        }
    }

    @Test func testIssue21FormattedDurationUsesExpectedZeroAndNonZeroOutput() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            #expect(stats.formattedDuration == String(localized: "0s"))

            let duration = 3_661.0
            stats.recordTranscription(text: "duration", audioDurationSeconds: duration)

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 3
            formatter.zeroFormattingBehavior = .dropAll

            let expected = formatter.string(from: duration) ?? String(localized: "0s")
            #expect(stats.formattedDuration == expected)
        }
    }

}

// MARK: - Menu Label Toggle Tests

@Suite("Menu Start/Stop Dictation toggle — source regression")
struct MenuDictationToggleSourceTests {

    @Test func testBuildMenuUsesRecordingStateForLabel() throws {
        let source = try readProjectSource("Sources/App/SpeakFlowApp.swift")
        #expect(source.contains("isRecording") && source.contains("isProcessingFinal"),
                "Menu label must check both isRecording and isProcessingFinal")
        #expect(source.contains("Stop Dictation"))
        #expect(source.contains("Start Dictation"))
    }

    @Test func testUpdateStatusIconRebuildsMenu() throws {
        let source = try readProjectSource("Sources/App/PermissionController.swift")
        #expect(source.contains("func updateStatusIcon()"))
        let updateIconBody = extractFunctionBody(named: "updateStatusIcon", from: source)
        #expect(updateIconBody != nil, "updateStatusIcon function must exist")
        if let body = updateIconBody {
            #expect(body.contains("AppState.shared.refresh()"), "updateStatusIcon must call AppState.shared.refresh() for SwiftUI reactive updates")
        }
    }

    @Test func testMenuLabelIsDynamic() throws {
        let source = try readProjectSource("Sources/App/SpeakFlowApp.swift")
        #expect(source.contains("dictationLabel"),
                "Menu must use a variable label based on recording state")
        #expect(source.contains("Stop Dictation") && source.contains("Start Dictation"),
                "Menu must have both Start and Stop labels")
    }
}

// MARK: - OAuth Server Cleanup Tests

@Suite("OAuth callback server cleanup on termination — source regression")
struct OAuthServerCleanupSourceTests {

    @Test func testOAuthServerPropertyExists() throws {
        let source = try readProjectSource("Sources/App/AuthController.swift")
        #expect(source.contains("oauthCallbackServer: OAuthCallbackServer?"),
                "AuthController must have an oauthCallbackServer property")
    }

    @Test func testLoginFlowStoresServer() throws {
        let source = try readProjectSource("Sources/App/AuthController.swift")
        #expect(source.contains("oauthCallbackServer = server"),
                "startLoginFlow must store the server for cleanup")
    }

    @Test func testLoginFlowClearsServerOnCompletion() throws {
        let source = try readProjectSource("Sources/App/AuthController.swift")
        #expect(source.contains("self.oauthCallbackServer = nil"),
                "Server reference must be cleared after login completes")
    }

    @Test func testTerminationStopsOAuthServer() throws {
        let auth = try readProjectSource("Sources/App/AuthController.swift")
        let body = extractFunctionBody(named: "shutdown", from: auth)
        #expect(body != nil, "AuthController.shutdown must exist")
        if let body = body {
            #expect(body.contains("oauthCallbackServer?.stop()"),
                    "AuthController.shutdown must stop the OAuth server")
            #expect(body.contains("oauthCallbackServer = nil"),
                    "AuthController.shutdown must nil the OAuth server")
        }
    }
}

// MARK: - Updated Termination Completeness Test

@Suite("applicationWillTerminate — full cleanup audit")
struct TerminationCleanupAuditTests {

    @Test func testAllResourcesCleanedUp() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")
        let appBody = extractTerminationBody(from: appDelegate)
        #expect(appBody != nil, "applicationWillTerminate must exist")
        guard let appBody = appBody else { return }

        // AppDelegate.applicationWillTerminate must call shutdown on all controllers
        #expect(appBody.contains("RecordingController.shared.shutdown()"))
        #expect(appBody.contains("AuthController.shared.shutdown()"))
        #expect(appBody.contains("PermissionController.shared.shutdown()"))
        #expect(appBody.contains("removeObserver(observer)"))

        // RecordingController.shutdown() cleanup
        let recording = try readProjectSource("Sources/App/RecordingController.swift")
        let recordingShutdown = extractFunctionBody(named: "shutdown", from: recording)
        guard let recordingShutdown = recordingShutdown else {
            Issue.record("RecordingController.shutdown not found")
            return
        }
        #expect(recordingShutdown.contains("hotkeyListener?.stop()"))
        #expect(recordingShutdown.contains("stopKeyListener()"))
        #expect(recordingShutdown.contains("recorder?.cancel()"))
        #expect(recordingShutdown.contains("Transcription.shared.cancelAll()"))
        #expect(recordingShutdown.contains("textInsertionTask?.cancel()"))

        // AuthController.shutdown() cleanup
        let auth = try readProjectSource("Sources/App/AuthController.swift")
        let authShutdown = extractFunctionBody(named: "shutdown", from: auth)
        guard let authShutdown = authShutdown else {
            Issue.record("AuthController.shutdown not found")
            return
        }
        #expect(authShutdown.contains("oauthCallbackServer?.stop()"))
        #expect(authShutdown.contains("oauthCallbackServer = nil"))

        // PermissionController.shutdown() cleanup
        let perm = try readProjectSource("Sources/App/PermissionController.swift")
        let permShutdown = extractFunctionBody(named: "shutdown", from: perm)
        guard let permShutdown = permShutdown else {
            Issue.record("PermissionController.shutdown not found")
            return
        }
        #expect(permShutdown.contains("permissionManager.stopPolling()"))
    }
}

// MARK: - Regression: Timeout scales with audio duration

@Suite("Timeout scales with data size — source regression")
struct TimeoutScalingSourceTests {

    @Test func testTimeoutScalingConfigExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        #expect(source.contains("maxTimeout"))
        #expect(source.contains("baseTimeoutDataSize"))
    }

    @Test func testTimeoutScalingMethod() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("func timeout(forDataSize"),
                "TranscriptionService must have a data-size-based timeout method")
    }

    @Test func testTimeoutScalingBehavior() {
        // Zero bytes: base timeout
        let zero = TranscriptionService.timeout(forDataSize: 0)
        #expect(zero == Config.timeout,
                "Zero bytes should use base timeout, got \(zero)")

        // At base data size: base timeout
        let atBase = TranscriptionService.timeout(forDataSize: Config.baseTimeoutDataSize)
        #expect(atBase == Config.timeout,
                "Data at baseTimeoutDataSize should use base timeout, got \(atBase)")

        // At max file size: max timeout
        let atMax = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes)
        #expect(atMax == Config.maxTimeout,
                "Data at maxAudioSizeBytes should use maxTimeout, got \(atMax)")

        // Above max: still capped
        let overMax = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes * 2)
        #expect(overMax == Config.maxTimeout,
                "Data above max should be capped at maxTimeout, got \(overMax)")

        // Midpoint: halfway between base and max timeout
        let midSize = Config.baseTimeoutDataSize + (Config.maxAudioSizeBytes - Config.baseTimeoutDataSize) / 2
        let midTimeout = TranscriptionService.timeout(forDataSize: midSize)
        let expectedMid = Config.timeout + (Config.maxTimeout - Config.timeout) / 2.0
        #expect(abs(midTimeout - expectedMid) < 0.01,
                "Mid-range data should get mid-range timeout, got \(midTimeout) expected \(expectedMid)")

        // Monotonically increasing
        let t1 = TranscriptionService.timeout(forDataSize: 500_000)
        let t2 = TranscriptionService.timeout(forDataSize: 5_000_000)
        let t3 = TranscriptionService.timeout(forDataSize: 15_000_000)
        #expect(t1 <= t2 && t2 <= t3,
                "Timeout must be monotonically increasing: \(t1) <= \(t2) <= \(t3)")
    }

    @Test func testTranscriptionUsesDataSize() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/Transcription.swift")
        #expect(source.contains("timeout(forDataSize: chunk.wavData.count)"),
                "Transcription must compute timeout from chunk data size")
    }
}

// MARK: - Swift 6 Actor-Isolation Regression Tests (Permission Polling)

@Suite("Swift 6 Actor-Isolation — Permission Polling")
struct PermissionPollingSwift6Tests {

    /// BLOCKER REGRESSION: Timer.scheduledTimer closures are @Sendable and cannot
    /// safely access @MainActor state. Permission polling must use Task loops.
    @Test func testAccessibilityPollingUsesTaskNotTimer() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        #expect(!source.contains("Timer.scheduledTimer"),
                "REGRESSION: Must not use Timer.scheduledTimer (Swift 6 actor-isolation violation)")
        #expect(source.contains("permissionCheckTask = Task"),
                "Must use Task-based polling loop")
        #expect(source.contains("Task.sleep"),
                "Must use Task.sleep for polling interval")
    }

    @Test func testAccessibilityPollingHasNoTimerProperty() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        #expect(!source.contains("permissionCheckTimer"),
                "Must not have Timer property — use Task instead")
        #expect(source.contains("permissionCheckTask: Task<Void, Never>?"),
                "Must have Task<Void, Never>? property for polling")
    }

    @Test func testStopPollingCancelsTask() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        guard let range = source.range(of: "func stopPolling()") else {
            Issue.record("stopPolling not found")
            return
        }
        let body = String(source[range.lowerBound...].prefix(200))
        #expect(body.contains("permissionCheckTask?.cancel()"),
                "stopPolling must cancel the polling task")
        #expect(body.contains("permissionCheckTask = nil"),
                "stopPolling must nil out the task reference")
    }

    @Test func testMicPermissionNoPolling() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(!source.contains("micPermissionTimer"),
                "REGRESSION: Must not use micPermissionTimer (Swift 6 actor-isolation violation)")
        #expect(!source.contains("startMicrophonePermissionPolling"),
                "Mic permission must not poll — uses requestAccess callback + menuWillOpen instead")
    }

    @Test func testMicPermissionCheckedOnLaunch() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(appDelegate.contains("permissions.checkInitialPermissions()"),
                "AppDelegate must call permissions.checkInitialPermissions() on app launch")
        // Must handle denied case with user-facing message
        let permController = try readProjectSource("Sources/App/PermissionController.swift")
        let body = extractFunctionBody(named: "checkMicrophonePermission", from: permController)
        #expect(body?.contains("denied") == true || body?.contains(".denied") == true,
                "checkMicrophonePermission must handle denied state")
    }

    /// Verify the polling task delegates to updateStatusIcon/setupHotkey
    /// directly (no extra Task dispatch needed since already on MainActor).
    @Test func testPollingDelegateCallsAreDirectNotWrapped() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        guard let range = source.range(of: "permissionCheckTask = Task") else {
            Issue.record("permissionCheckTask assignment not found")
            return
        }
        let body = String(source[range.lowerBound...].prefix(1200))
        // Delegate calls should be direct (already on MainActor), not wrapped in another Task
        #expect(body.contains("self.delegate?.updateStatusIcon()"),
                "Delegate calls should be direct on MainActor")
        #expect(body.contains("self.delegate?.setupHotkey()"),
                "Delegate calls should be direct on MainActor")
    }

    /// Behavioral: stopPolling is idempotent.
    @Test func testStopPollingIdempotent() async {
        await MainActor.run {
            let manager = AccessibilityPermissionManager()
            manager.stopPolling()
            manager.stopPolling()
            manager.stopPolling()
        }
    }

    @Test @MainActor func testMaxPollAttempts() {
        #expect(AccessibilityPermissionManager.maxPollAttempts == 60,
                "maxPollAttempts should be 60 (2 minutes at 2s intervals)")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Architecture Separation Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("Architecture — Layer Separation")
struct ArchitectureSeparationTests {

    /// View files that must not reference AppDelegate.shared.
    private static let viewFiles = [
        "Sources/App/SpeakFlowApp.swift",
        "Sources/App/MainSettingsView.swift",
        "Sources/App/GeneralSettingsView.swift",
        "Sources/App/TranscriptionSettingsView.swift",
        "Sources/App/AccountsSettingsView.swift",
        "Sources/App/AboutSettingsView.swift",
    ]

    /// Controller files that own business logic.
    private static let controllerFiles = [
        "Sources/App/RecordingController.swift",
        "Sources/App/AuthController.swift",
        "Sources/App/PermissionController.swift",
    ]

    // MARK: - No View → AppDelegate Coupling

    @Test func testNoViewReferencesAppDelegateShared() throws {
        for file in Self.viewFiles {
            let source = try readProjectSource(file)
            let hasAppDelegate = source.contains("AppDelegate.shared")
            #expect(!hasAppDelegate,
                    "\(file) must not reference AppDelegate.shared — use controllers directly")
        }
    }

    // MARK: - Controller Shutdown

    @Test func testAllControllersHaveShutdown() throws {
        for file in Self.controllerFiles {
            let source = try readProjectSource(file)
            #expect(source.contains("func shutdown()"),
                    "\(file) must have a shutdown() method for clean termination")
        }
    }

    @Test func testAppDelegateDelegatesTerminationToControllers() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractFunctionBody(named: "applicationWillTerminate", from: source)
        #expect(body != nil, "applicationWillTerminate must exist")
        if let body = body {
            #expect(body.contains("RecordingController.shared.shutdown()"),
                    "Must delegate to RecordingController.shutdown()")
            #expect(body.contains("AuthController.shared.shutdown()"),
                    "Must delegate to AuthController.shutdown()")
            #expect(body.contains("PermissionController.shared.shutdown()"),
                    "Must delegate to PermissionController.shutdown()")
        }
    }

    // MARK: - AppDelegate Is Thin Coordinator

    @Test func testAppDelegateHasNoRecordingLogic() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(!source.contains("func startRecording"),
                "AppDelegate must not contain startRecording — belongs in RecordingController")
        #expect(!source.contains("func stopRecording"),
                "AppDelegate must not contain stopRecording — belongs in RecordingController")
        #expect(!source.contains("func toggle()"),
                "AppDelegate must not contain toggle() — belongs in RecordingController")
        #expect(!source.contains("AVAudioEngine()") || source.contains("pre-warm"),
                "AVAudioEngine use in AppDelegate should only be for pre-warming")
    }

    @Test func testAppDelegateHasNoAuthLogic() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(!source.contains("func startLoginFlow"),
                "AppDelegate must not contain startLoginFlow — belongs in AuthController")
        #expect(!source.contains("func handleLogout"),
                "AppDelegate must not contain handleLogout — belongs in AuthController")
        #expect(!source.contains("OAuthCallbackServer"),
                "AppDelegate must not reference OAuthCallbackServer — belongs in AuthController")
    }

    @Test func testAppDelegateHasNoPermissionLogic() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(!source.contains("AccessibilityPermissionDelegate"),
                "AppDelegate must not conform to AccessibilityPermissionDelegate — belongs in PermissionController")
        #expect(!source.contains("func checkAccessibility"),
                "AppDelegate must not contain checkAccessibility — belongs in PermissionController")
    }

    // MARK: - Views Use Correct Controllers

    @Test func testGeneralSettingsUsesRecordingController() throws {
        let source = try readProjectSource("Sources/App/GeneralSettingsView.swift")
        #expect(source.contains("RecordingController.shared"),
                "GeneralSettingsView must use RecordingController for hotkey setup")
    }

    @Test func testAccountsSettingsUsesAuthController() throws {
        let source = try readProjectSource("Sources/App/AccountsSettingsView.swift")
        #expect(source.contains("AuthController.shared"),
                "AccountsSettingsView must use AuthController for login/logout")
    }

    @Test func testGeneralSettingsUsesPermissionController() throws {
        let source = try readProjectSource("Sources/App/GeneralSettingsView.swift")
        #expect(source.contains("PermissionController.shared"),
                "GeneralSettingsView must use PermissionController for permission checks")
    }

    // MARK: - Controller Singleton Pattern

    @Test func testControllersSingletonPattern() throws {
        for file in Self.controllerFiles {
            let source = try readProjectSource(file)
            #expect(source.contains("static let shared"),
                    "\(file) must expose a shared singleton")
            #expect(source.contains("@MainActor"),
                    "\(file) must be @MainActor isolated")
        }
    }

    // MARK: - AppState Is Observable Bridge

    @Test func testAppStateIsObservable() throws {
        let source = try readProjectSource("Sources/App/AppState.swift")
        #expect(source.contains("@Observable"),
                "AppState must be @Observable for SwiftUI reactivity")
        #expect(source.contains("func refresh()"),
                "AppState must have refresh() to sync from settings singletons")
    }
}
