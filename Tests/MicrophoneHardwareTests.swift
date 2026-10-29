import AVFoundation
import CoreAudio
import Foundation
import os
import Testing
@testable import SpeakFlowCore

@Suite("Microphone hardware", .serialized)
struct MicrophoneHardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_MICROPHONE_HARDWARE"] == "1")) @MainActor
    func baselineDefaultInputDeliversFrames() async throws {
        let frames = OSAllocatedUnfairLock(initialState: 0)
        let engine: AVAudioEngine = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                do {
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
                        frames.withLock { $0 += Int(buffer.frameLength) }
                    }
                    try engine.start()
                    continuation.resume(returning: engine)
                } catch { continuation.resume(throwing: error) }
            }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while frames.withLock({ $0 == 0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Baseline default input: \(frames.withLock { $0 }) frames")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                continuation.resume()
            }
        }
        #expect(frames.withLock { $0 > 0 }, "Unmodified system-default capture must deliver frames")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_MICROPHONE_HARDWARE"] == "1")) @MainActor
    func eachInputDeliversFramesAndPreservesSystemDefault() async throws {
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                     "Microphone permission is required for hardware verification")
        let catalog = MicrophoneCatalog()
        let before = try catalog.snapshot()
        try #require(!before.devices.isEmpty, "Hardware verification requires a connected input")
        var devices = before.devices
        if ProcessInfo.processInfo.environment["SPEAKFLOW_MICROPHONE_BUILTIN_ONLY"] == "1" {
            devices = devices.filter { device in
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var transport: UInt32 = 0
                var size = UInt32(MemoryLayout.size(ofValue: transport))
                return AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &transport) == noErr
                    && transport == kAudioDeviceTransportTypeBuiltIn
            }
            try #require(!devices.isEmpty, "A built-in microphone is required for this hardware scope")
        }
        for (index, device) in devices.enumerated() {
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout.size(ofValue: transport))
            _ = AudioObjectGetPropertyData(device.id, &transportAddress, 0, nil, &transportSize, &transport)
            let isVirtual = transport == kAudioDeviceTransportTypeVirtual
            let selection = MicrophoneSelection(catalog: catalog, preferredUID: device.uid, monitor: false)
            let frames = OSAllocatedUnfairLock(initialState: 0)
            let capture = RoutedMicrophoneCapture(selection: selection)
            try await capture.start { _ in
                return { @Sendable buffer in
                    let count = Int(buffer.frameLength)
                    frames.withLock { $0 += count }
                }
            }
            let deadline = ContinuousClock.now + .seconds(15)
            while frames.withLock({ $0 == 0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let routedToRequestedDevice = selection.activeDevice?.uid == device.uid
            #expect(routedToRequestedDevice, "Capture must use the requested input")
            let receivedFrames = frames.withLock { $0 }
            print("Input \(index + 1): \(receivedFrames) frames; virtual=\(isVirtual)")
            #expect(receivedFrames > 0, "The selected input must deliver frames")
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    capture.stop()
                    continuation.resume()
                }
            }
        }
        let after = try catalog.snapshot()
        let systemDefaultUnchanged = before.defaultID == after.defaultID
        #expect(systemDefaultUnchanged, "App selection must preserve the system default")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_MICROPHONE_HARDWARE"] == "1")) @MainActor
    func eachInputReachesBothRecordingPipelines() async throws {
        try #require(ProcessInfo.processInfo.environment["SPEAKFLOW_ALLOW_TEST_AUDIO_CAPTURE"] == "1",
                     "Enable explicit test audio capture for pipeline verification")
        let catalog = MicrophoneCatalog()
        let devices = try catalog.snapshot().devices
        try #require(!devices.isEmpty)
        for (index, device) in devices.enumerated() {
            let selection = MicrophoneSelection(catalog: catalog, preferredUID: device.uid, monitor: true)
            let settings = SpySettings()
            settings.vadEnabled = false
            settings.autoEndEnabled = false
            settings.idleNudgeEnabled = false
            settings.audioNoiseGateEnabled = false
            settings.observabilityEnabled = false
            settings.skipSilentChunks = false
            let recorder = StreamingRecorder(settings: settings, microphoneSelection: selection, playSoundEffect: { _ in })
            var wavBytes = 0
            recorder.onChunkReady = { wavBytes += $0.wavData.count }
            try #require(await recorder.start())
            let deadline = ContinuousClock.now + .seconds(15)
            while await recorder._testAudioBufferDuration() < 1.1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            recorder.stop()
            await recorder.waitForStopCompletion()
            #expect(wavBytes > 44, "The selected input must reach the batch WAV output")

            let provider = MockStreamingProvider()
            let session = MockStreamingSession()
            provider.mockSession = session
            let streaming = LiveStreamingController(microphoneSelection: selection)
            streaming.keepAliveEnabled = false
            streaming.onError = { error in
                if case MicrophoneError.hardware(let status) = error {
                    print("Capture startup status:", status)
                } else { print("Capture startup error type:", type(of: error)) }
            }
            try #require(await streaming.start(provider: provider, config: .default))
            let streamDeadline = ContinuousClock.now + .seconds(15)
            while await session.sentAudioChunks.isEmpty, ContinuousClock.now < streamDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(1100))
            #expect(selection.activeDevice != nil, "Capture must remain healthy while hardware monitoring is active")
            let pcmBytes = await session.sentAudioChunks.reduce(0) { $0 + $1.count }
            await streaming.stop(trailingFinalTimeout: 0)
            #expect(pcmBytes > 0, "The selected input must reach the streaming PCM queue")
            print("Input \(index + 1): batch and streaming verified")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_MICROPHONE_HARDWARE"] == "1")) @MainActor
    func liveFallbackKeepsPreferenceAndRebuildsTheConsumer() async throws {
        let snapshot = try MicrophoneCatalog().snapshot()
        let fallback = try #require(snapshot.devices.first { $0.id == snapshot.defaultID })
        let preferred = try #require(snapshot.devices.first { $0.uid != fallback.uid })
        let catalog = StubMicrophoneCatalog(.init(devices: [fallback, preferred], defaultID: fallback.id))
        let selection = MicrophoneSelection(catalog: catalog, preferredUID: preferred.uid, monitor: false)
        let capture = RoutedMicrophoneCapture(selection: selection)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        var consumers = 0
        try await capture.start { _ in
            consumers += 1
            return { @Sendable buffer in
                let count = Int(buffer.frameLength)
                frames.withLock { $0 += count }
            }
        }
        defer { capture.stop() }
        func waitForFrames() async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while frames.withLock({ $0 == 0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(frames.withLock { $0 > 0 })
        }
        try await waitForFrames()
        catalog.value = .init(devices: [fallback], defaultID: fallback.id)
        selection.refresh()
        let routeDeadline = ContinuousClock.now + .seconds(15)
        while selection.activeDevice?.uid != fallback.uid, ContinuousClock.now < routeDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        frames.withLock { $0 = 0 }
        try await waitForFrames()
        let usingFallback = selection.activeDevice?.uid == fallback.uid
        #expect(usingFallback)
        let preferenceRetained = selection.preferredUID == preferred.uid
        #expect(preferenceRetained)
        #expect(consumers == 2)
        catalog.value = snapshot
        selection.refresh()
        #expect(consumers == 2, "Reconnection must not interrupt a fallback recording")
        let after = try MicrophoneCatalog().snapshot()
        let defaultUnchanged = after.defaultID == snapshot.defaultID
        #expect(defaultUnchanged)
    }
}
