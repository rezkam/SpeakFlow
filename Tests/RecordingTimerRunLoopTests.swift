import AppKit
import Foundation
import Testing
import os
@testable import SpeakFlowCore

@Suite("Recording native timer modes", .serialized)
struct RecordingTimerRunLoopTests {
    @MainActor @Test
    func nativeTimersFireWhileTrackingAndRetireOnStop() async throws {
        let suite = "RecordingTimerRunLoopTests"
        guard NativeUIProbeSupport.isChild(for: suite) else {
            try NativeUIProbeSupport.runChild(suite: suite)
            return
        }
        for cancel in [false, true] {
            try await checkNativeTimers(cancel: cancel)
        }
    }

    @MainActor
    private func checkNativeTimers(cancel: Bool) async throws {
        let settings = Settings.shared
        let savedVAD = settings.vadEnabled
        let savedAutoEnd = settings.autoEndEnabled
        settings.vadEnabled = false
        settings.autoEndEnabled = false
        defer {
            settings.vadEnabled = savedVAD
            settings.autoEndEnabled = savedAutoEnd
        }
        let counts = OSAllocatedUnfairLock(initialState: (processing: 0, check: 0))
        let recorder = StreamingRecorder()
        recorder.nativeTimerTickForTesting = { kind in
            counts.withLock {
                switch kind {
                case .processing: $0.processing += 1
                case .check: $0.check += 1
                }
            }
        }
        await recorder.startMock(audioData: [])
        defer { recorder.cancel() }

        // Exercise the real native timer callbacks in the mode AppKit uses for
        // menu/window tracking, without opening menus or capturing user input.
        let trackingMode = CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), trackingMode)
        func track(for seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
            }
        }
        track(for: 0.65)
        let active = counts.withLock { $0 }
        #expect(active.processing > 0)
        #expect(active.check > 0)
        if cancel { recorder.cancel() } else { recorder.stop() }
        await recorder.waitForStopCompletion()
        let retired = counts.withLock { $0 }
        track(for: 0.65)
        let after = counts.withLock { $0 }
        #expect(after.processing == retired.processing)
        #expect(after.check == retired.check)
    }
}
