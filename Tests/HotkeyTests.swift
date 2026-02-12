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

    @Test func testStopRecordingDoesNotStopKeyInterceptorSynchronously() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let body = extractFunctionBody(named: "stopRecording", from: source)
        #expect(body != nil, "stopRecording function must exist")
        if let body = body {
            // The key interceptor must stay active during processing-final so Escape/Enter work.
            // keyInterceptor.stop() may appear inside Task blocks (deferred cleanup after processing),
            // but must NOT be called synchronously before the first Task block.
            let lines = body.components(separatedBy: "\n")
            var reachedTask = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
                if trimmed.contains("Task {") || trimmed.contains("Task(") { reachedTask = true }
                if !reachedTask && trimmed.contains("keyInterceptor.stop()") {
                    Issue.record("stopRecording calls keyInterceptor.stop() synchronously before Task — key interceptor must stay active during processing-final")
                }
            }
        }
    }

    @Test func testEnterCallbackHandlesBothPhases() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // The onEnterPressed callback must check both isRecording and isProcessingFinal
        #expect(source.contains("onEnterPressed"),
                "RecordingController must set up onEnterPressed callback on KeyInterceptor")
        #expect(source.contains("self.isRecording") && source.contains("self.stopRecordingAndSubmit()"),
                "Enter callback must call stopRecordingAndSubmit when recording")
        #expect(source.contains("self.isProcessingFinal") && source.contains("self.shouldPressEnterOnComplete = true"),
                "Enter callback must flag Enter for post-completion during processing-final")
    }

    @Test func testFinishIfDoneStopsKeyInterceptor() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let body = extractFunctionBody(named: "finishIfDone", from: source)
        #expect(body != nil, "finishIfDone must exist")
        if let body = body {
            let count = countOccurrences(of: "keyInterceptor.stop()", in: body)
            #expect(count >= 2,
                    "finishIfDone must call keyInterceptor.stop() in both timeout and success paths (found \(count))")
        }
    }

    @Test func testCancelRecordingStopsKeyInterceptor() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        let body = extractFunctionBody(named: "cancelRecording", from: source)
        #expect(body != nil, "cancelRecording must exist")
        if let body = body {
            #expect(body.contains("keyInterceptor.stop()"),
                    "cancelRecording must stop key interceptor")
        }
    }

    @Test func testEnterKeyConsumedByInterceptor() throws {
        // The CGEvent tap handler returns nil for Enter (keyCode 36) = consumed
        let source = try readProjectSource("Sources/App/KeyInterceptor.swift")
        let handler = extractFunctionBody(named: "handleKeyEvent", from: source)
        #expect(handler != nil, "handleKeyEvent must exist in KeyInterceptor")
        if let handler = handler {
            #expect(handler.contains("case 36:"))
            #expect(handler.contains("return nil"))
        }
    }

    @Test func testBothEscapeAndEnterCallbacksConfigured() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        #expect(source.contains("onEscapePressed"),
                "RecordingController must configure onEscapePressed on KeyInterceptor")
        #expect(source.contains("onEnterPressed"),
                "RecordingController must configure onEnterPressed on KeyInterceptor")
    }
}

// MARK: - Key Interceptor Safety Tests

@Suite("P1 — Enter/Escape not consumed when recording inactive")
struct KeyInterceptorSafetyTests {

    @Test func testKeyListenerActiveAtomicFlagExists() throws {
        let source = try readProjectSource("Sources/App/KeyInterceptor.swift")
        #expect(source.contains("keyListenerActive"),
                "KeyInterceptor must have a thread-safe keyListenerActive flag")
        #expect(source.contains("OSAllocatedUnfairLock"),
                "keyListenerActive must use OSAllocatedUnfairLock for thread safety")
    }

    @Test func testHandleKeyEventChecksFlag() throws {
        let source = try readProjectSource("Sources/App/KeyInterceptor.swift")

        let body = extractFunctionBody(named: "handleKeyEvent", from: source)
        #expect(body != nil, "handleKeyEvent must exist in KeyInterceptor")
        guard let body else { return }

        // Must check keyListenerActive BEFORE examining keyCode
        #expect(body.contains("keyListenerActive"),
                "handleKeyEvent must check keyListenerActive flag")

        // The guard must return the event (pass-through), not nil (consume)
        #expect(body.contains("Unmanaged.passRetained(event)"),
                "When flag is false, event must pass through (not consumed)")
    }

    @Test func testStartSetsFlag() throws {
        let source = try readProjectSource("Sources/App/KeyInterceptor.swift")

        let body = extractFunctionBody(named: "start", from: source)
        #expect(body != nil, "start must exist in KeyInterceptor")
        guard let body else { return }

        #expect(body.contains("keyListenerActive"),
                "start must set keyListenerActive to true")
    }

    @Test func testStopClearsFlag() throws {
        let source = try readProjectSource("Sources/App/KeyInterceptor.swift")

        let body = extractFunctionBody(named: "stop", from: source)
        #expect(body != nil, "stop must exist in KeyInterceptor")
        guard let body else { return }

        #expect(body.contains("keyListenerActive"),
                "stop must set keyListenerActive to false")
    }

    @Test func testRecorderStartFailureCleansUpKeyInterceptor() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        let body = extractFunctionBody(named: "startBatchRecording", from: source)
        #expect(body != nil, "startBatchRecording must exist")
        guard let body else { return }

        // Key interceptor must start eagerly so Escape works immediately
        #expect(body.contains("keyInterceptor.start()"),
                "startBatchRecording must call keyInterceptor.start()")

        // The failure branch must stop the interceptor
        #expect(body.contains("keyInterceptor.stop()"),
                "Recorder start failure must call keyInterceptor.stop() to clean up")

        // keyInterceptor.start() must appear before "recorder?.start()" (the async start)
        if let keyIdx = body.range(of: "keyInterceptor.start()")?.lowerBound,
           let recorderStartIdx = body.range(of: "recorder?.start()")?.lowerBound {
            #expect(keyIdx < recorderStartIdx,
                    "keyInterceptor.start() must be called before recorder?.start()")
        }
    }

    @Test func testFlagClearedBeforeTapDisabled() throws {
        let source = try readProjectSource("Sources/App/KeyInterceptor.swift")

        let body = extractFunctionBody(named: "stop", from: source)
        guard let body else {
            Issue.record("stop not found in KeyInterceptor")
            return
        }

        // keyListenerActive must be cleared BEFORE disabling the tap,
        // so any in-flight callback sees the flag as false immediately.
        guard let flagPos = body.range(of: "keyListenerActive")?.lowerBound,
              let tapPos = body.range(of: "CGEvent.tapEnable")?.lowerBound else {
            Issue.record("Required code not found in KeyInterceptor.stop")
            return
        }
        #expect(flagPos < tapPos,
                "keyListenerActive must be cleared BEFORE disabling CGEvent tap")
    }
}

// MARK: - Key Interceptor Start Order Tests

@Suite("Issue #7 Regression — Key Interceptor Immediate Start for Escape")
struct KeyInterceptorStartOrderTests {

    /// Key interceptor must start BEFORE the async Task so Escape works immediately.
    @Test func testKeyInterceptorStartsBeforeAsyncWork() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        // Check batch mode: keyInterceptor.start() before recorder?.start()
        let batchBody = extractFunctionBody(named: "startBatchRecording", from: source)
        #expect(batchBody != nil, "startBatchRecording must exist")
        guard let batchBody else { return }

        #expect(batchBody.contains("keyInterceptor.start()"),
                "startBatchRecording must call keyInterceptor.start()")

        if let klIdx = batchBody.range(of: "keyInterceptor.start()")?.lowerBound,
           let startIdx = batchBody.range(of: "recorder?.start()")?.lowerBound {
            #expect(klIdx < startIdx,
                    "keyInterceptor.start() must be called BEFORE recorder?.start() for immediate Escape")
        }

        // Check streaming mode: keyInterceptor.start() before controller.start()
        let streamBody = extractFunctionBody(named: "startStreamingRecording", from: source)
        #expect(streamBody != nil, "startStreamingRecording must exist")
        guard let streamBody else { return }

        #expect(streamBody.contains("keyInterceptor.start()"),
                "startStreamingRecording must call keyInterceptor.start()")

        if let klIdx = streamBody.range(of: "keyInterceptor.start()")?.lowerBound,
           let startIdx = streamBody.range(of: "controller.start(")?.lowerBound {
            #expect(klIdx < startIdx,
                    "keyInterceptor.start() must be called BEFORE controller.start() for immediate Escape")
        }
    }

    /// Exactly one call to keyInterceptor.start() per recording function.
    @Test func testExactlyOneStartCall() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        for funcName in ["startBatchRecording", "startStreamingRecording"] {
            let body = extractFunctionBody(named: funcName, from: source)
            guard let body else {
                Issue.record("\(funcName) not found")
                continue
            }
            let count = body.components(separatedBy: "keyInterceptor.start()").count - 1
            #expect(count == 1,
                    "Must call keyInterceptor.start() exactly once in \(funcName), found \(count)")
        }
    }

    /// The failure branch must call keyInterceptor.stop() to clean up.
    @Test func testFailureBranchStopsKeyInterceptor() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        for funcName in ["startBatchRecording", "startStreamingRecording"] {
            let body = extractFunctionBody(named: funcName, from: source)
            guard let body else {
                Issue.record("\(funcName) not found")
                continue
            }
            #expect(body.contains("keyInterceptor.stop()"),
                    "\(funcName) failure branch must call keyInterceptor.stop() to clean up")
        }
    }
}
