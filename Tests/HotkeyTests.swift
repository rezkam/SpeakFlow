import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Hotkey Listener Cleanup Tests

struct HotkeyListenerCleanupTests {
    @Test func testStopIsIdempotent() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            let listener = HotkeyListener()
            listener.stop()
            listener.stop()
            #expect(stopCalls == 2)
        }
    }
}

struct HotkeyListenerCleanupRegressionTests {
    @Test func testDeinitInvokesStopCleanup() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            var listener: HotkeyListener? = HotkeyListener()
            #expect(stopCalls == 0)
            _ = listener // Silence "never read" warning
            listener = nil

            #if compiler(>=6.2)
            // Isolated deinit calls stop() on deallocation
            #expect(stopCalls == 1)
            #else
            // Swift 6.1 has no isolated deinit — cleanup via explicit stop() only
            #expect(stopCalls == 0)
            #endif
        }
    }

    @Test func testDeinitAfterManualStopRemainsSafe() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            var listener: HotkeyListener? = HotkeyListener()
            listener?.stop()
            listener = nil

            #if compiler(>=6.2)
            // Manual stop() + isolated deinit stop()
            #expect(stopCalls == 2)
            #else
            // Swift 6.1: only the explicit stop() call
            #expect(stopCalls == 1)
            #endif
        }
    }

    @Test func testSourceRetainsDeinitStopCleanupHook() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift")

        #expect(source.contains("@MainActor deinit"))
        #expect(source.contains("#if compiler(>=6.2)"))
        #expect(source.contains("stop()"))
    }
}

// MARK: - Enter Key During Processing-Final Phase Tests

@Suite("Enter key handling during processing-final — source regression")
struct EnterKeyProcessingFinalSourceTests {

    @Test func testStopRecordingDoesNotStopKeyListener() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let body = extractFunctionBody(named: "stopRecording", from: source)
        #expect(body != nil, "stopRecording function must exist")
        if let body = body {
            // The key listener must stay active during processing-final so Escape/Enter work.
            // stopKeyListener() may appear inside Task blocks (deferred cleanup after processing),
            // but must NOT be called synchronously before the first Task block.
            let lines = body.components(separatedBy: "\n")
            var reachedTask = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
                if trimmed.contains("Task {") || trimmed.contains("Task(") { reachedTask = true }
                if !reachedTask && trimmed.contains("stopKeyListener()") {
                    Issue.record("stopRecording calls stopKeyListener() synchronously before Task — key listener must stay active during processing-final")
                }
            }
        }
    }

    @Test func testKeyHandlerHandlesBothPhases() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // The key event handler must check both isRecording and isProcessingFinal
        let handler = extractFunctionBody(named: "handleRecordingKeyEvent", from: source)
        #expect(handler != nil, "handleRecordingKeyEvent must exist")
        if let handler = handler {
            #expect(handler.contains("self.isRecording"), "Handler must check isRecording")
            #expect(handler.contains("self.isProcessingFinal"), "Handler must check isProcessingFinal")
            #expect(handler.contains("shouldPressEnterOnComplete = true"),
                    "Handler must flag Enter for post-completion during processing-final")
        }
    }

    @Test func testFinishIfDoneStopsKeyListener() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let body = extractFunctionBody(named: "finishIfDone", from: source)
        #expect(body != nil, "finishIfDone must exist")
        if let body = body {
            // stopKeyListener must be called in finishIfDone (at least once for normal path)
            let count = countOccurrences(of: "stopKeyListener()", in: body)
            #expect(count >= 2,
                    "finishIfDone must call stopKeyListener in both timeout and success paths (found \(count))")
        }
    }

    @Test func testCancelRecordingStopsKeyListener() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let body = extractFunctionBody(named: "cancelRecording", from: source)
        #expect(body != nil, "cancelRecording must exist")
        if let body = body {
            #expect(body.contains("stopKeyListener()"),
                    "cancelRecording must stop key listener")
        }
    }

    @Test func testEnterKeyConsumedDuringProcessingFinal() throws {
        // The CGEvent tap handler returns nil for Enter (keyCode 36) = consumed
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let handler = extractFunctionBody(named: "handleRecordingKeyEvent", from: source)
        #expect(handler != nil)
        if let handler = handler {
            // Enter case must return nil to consume the event
            #expect(handler.contains("case 36:"))
            #expect(handler.contains("return nil"))
        }
    }

    @Test func testFallbackMonitorAlsoHandlesProcessingFinal() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // The NSEvent fallback monitor must also handle isProcessingFinal
        #expect(source.contains("self.isProcessingFinal"),
                "Fallback NSEvent monitor must handle isProcessingFinal phase")
    }
}

// MARK: - Key Listener Safety Tests

@Suite("P1 — Enter/Escape not consumed when recording inactive")
struct KeyListenerSafetyTests {

    @Test func testKeyListenerActiveAtomicFlagExists() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        #expect(source.contains("keyListenerActive"),
                "RecordingController must have a thread-safe keyListenerActive flag")
        #expect(source.contains("OSAllocatedUnfairLock"),
                "keyListenerActive must use OSAllocatedUnfairLock for thread safety")
    }

    @Test func testHandleRecordingKeyEventChecksFlag() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        let body = extractFunctionBody(named: "handleRecordingKeyEvent", from: source)
        #expect(body != nil, "handleRecordingKeyEvent must exist")
        guard let body else { return }

        // Must check keyListenerActive BEFORE examining keyCode
        #expect(body.contains("keyListenerActive"),
                "handleRecordingKeyEvent must check keyListenerActive flag")

        // The guard must return the event (pass-through), not nil (consume)
        #expect(body.contains("Unmanaged.passRetained(event)"),
                "When flag is false, event must pass through (not consumed)")
    }

    @Test func testStartKeyListenerSetsFlag() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        let body = extractFunctionBody(named: "startKeyListener", from: source)
        #expect(body != nil, "startKeyListener must exist")
        guard let body else { return }

        #expect(body.contains("keyListenerActive"),
                "startKeyListener must set keyListenerActive to true")
    }

    @Test func testStopKeyListenerClearsFlag() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        let body = extractFunctionBody(named: "stopKeyListener", from: source)
        #expect(body != nil, "stopKeyListener must exist")
        guard let body else { return }

        #expect(body.contains("keyListenerActive"),
                "stopKeyListener must set keyListenerActive to false")
    }

    @Test func testRecorderStartFailureCleansUpKeyListener() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        let body = extractFunctionBody(named: "startGPTRecording", from: source)
        #expect(body != nil, "startGPTRecording must exist")
        guard let body else { return }

        // Key listener must start eagerly so Escape works immediately
        #expect(body.contains("startKeyListener()"),
                "startGPTRecording must call startKeyListener()")

        // The failure branch must call stopKeyListener
        #expect(body.contains("stopKeyListener()"),
                "Recorder start failure must call stopKeyListener() to clean up")

        // startKeyListener must appear before "recorder?.start()" (the async start)
        if let keyListenerIdx = body.range(of: "startKeyListener()")?.lowerBound,
           let recorderStartIdx = body.range(of: "recorder?.start()")?.lowerBound {
            #expect(keyListenerIdx < recorderStartIdx,
                    "startKeyListener() must be called before recorder?.start()")
        }
    }

    @Test func testFlagClearedBeforeTapDisabled() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        let body = extractFunctionBody(named: "stopKeyListener", from: source)
        guard let body else {
            Issue.record("stopKeyListener not found")
            return
        }

        // keyListenerActive must be cleared BEFORE disabling the tap,
        // so any in-flight callback sees the flag as false immediately.
        guard let flagPos = body.range(of: "keyListenerActive")?.lowerBound,
              let tapPos = body.range(of: "CGEvent.tapEnable")?.lowerBound else {
            Issue.record("Required code not found in stopKeyListener")
            return
        }
        #expect(flagPos < tapPos,
                "keyListenerActive must be cleared BEFORE disabling CGEvent tap")
    }
}

// MARK: - Key Listener Start Order Tests

@Suite("Issue #7 Regression — Key Listener Immediate Start for Escape")
struct KeyListenerStartOrderTests {

    /// Key listener must start BEFORE the async Task so Escape works immediately.
    /// Previously it was inside the success branch, meaning Escape was dead
    /// during the 1-2s audio engine / WebSocket startup.
    @Test func testKeyListenerStartsBeforeAsyncWork() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        // Check GPT mode: startKeyListener before recorder?.start()
        let gptBody = extractFunctionBody(named: "startGPTRecording", from: source)
        #expect(gptBody != nil, "startGPTRecording must exist")
        guard let gptBody else { return }

        #expect(gptBody.contains("startKeyListener()"),
                "startGPTRecording must call startKeyListener()")

        if let klIdx = gptBody.range(of: "startKeyListener()")?.lowerBound,
           let startIdx = gptBody.range(of: "recorder?.start()")?.lowerBound {
            #expect(klIdx < startIdx,
                    "startKeyListener() must be called BEFORE recorder?.start() for immediate Escape")
        }

        // Check Deepgram mode: startKeyListener before controller.start()
        let dgBody = extractFunctionBody(named: "startDeepgramRecording", from: source)
        #expect(dgBody != nil, "startDeepgramRecording must exist")
        guard let dgBody else { return }

        #expect(dgBody.contains("startKeyListener()"),
                "startDeepgramRecording must call startKeyListener()")

        if let klIdx = dgBody.range(of: "startKeyListener()")?.lowerBound,
           let startIdx = dgBody.range(of: "controller.start(")?.lowerBound {
            #expect(klIdx < startIdx,
                    "startKeyListener() must be called BEFORE controller.start() for immediate Escape")
        }
    }

    /// Exactly one call to startKeyListener per recording function.
    @Test func testExactlyOneStartKeyListenerCall() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        for funcName in ["startGPTRecording", "startDeepgramRecording"] {
            let body = extractFunctionBody(named: funcName, from: source)
            guard let body else {
                Issue.record("\(funcName) not found")
                continue
            }
            let count = body.components(separatedBy: "startKeyListener()").count - 1
            #expect(count == 1,
                    "Must call startKeyListener() exactly once in \(funcName), found \(count)")
        }
    }

    /// The failure branch must call stopKeyListener to clean up the eagerly-started listener.
    @Test func testFailureBranchCallsStopKeyListener() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        for funcName in ["startGPTRecording", "startDeepgramRecording"] {
            let body = extractFunctionBody(named: funcName, from: source)
            guard let body else {
                Issue.record("\(funcName) not found")
                continue
            }
            #expect(body.contains("stopKeyListener()"),
                    "\(funcName) failure branch must call stopKeyListener() to clean up")
        }
    }
}
