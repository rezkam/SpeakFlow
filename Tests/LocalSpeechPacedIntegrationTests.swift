import AVFoundation
import Darwin
import Foundation
import Testing
@testable import SpeakFlowCore

/// Public fixture audio only. Captures numeric measurements, never hypotheses or live audio.
@Suite("Paced local streaming", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_LOCAL_SPEECH_PROBES"] == "1"))
struct LocalSpeechPacedIntegrationTests {
    @MainActor @Test func publicSpeechRunsThroughTheLiveControllerAtCapturePace() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try #require(environment["SPEAKFLOW_LOCAL_MODEL_CACHE_ROOT"])
        let fixture = try #require(environment["SPEAKFLOW_PUBLIC_SPEECH_FIXTURE"])
        let descriptor = try #require(environment["SPEAKFLOW_PROBE_METRIC_FD"].flatMap(Int32.init))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture))
        try #require(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        try #require(file.length > 0 && file.length < 16000 * 30)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let floats = try #require(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: floats, count: Int(buffer.frameLength)))
        let pcm = Data(WavEncoder.encode(samples: samples, sampleRate: 16000).dropFirst(44))
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .nemotron1120 })
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: root, isDirectory: true))
        let before = probeMemory()
        let loadStart = ContinuousClock.now
        let lease = try await runtime.acquire(model)
        let loadSeconds = seconds(loadStart.duration(to: .now))
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        let loaded = probeMemory()
        let controller = LiveStreamingController(skipAudioCaptureForTesting: true)
        controller.keepAliveEnabled = false
        controller.reconnectEnabled = false
        controller.autoEndSilenceDuration = 0
        controller.turnStartStrategies = [.firstTranscription]
        var start = ContinuousClock.now
        var firstPartial: Double?
        var firstPartialAudio: Double?
        var finalAt: Double?
        var fedSeconds = 0.0
        var updates = 0, errors = 0, maximumQueued = 0
        var processPeak = loaded["processFootprintBytes"] ?? 0
        controller.onError = { _ in errors += 1 }
        controller.onTextUpdate = { _, _, isFinal, text in
            guard !text.isEmpty else { return }
            updates += 1
            if isFinal { finalAt = seconds(start.duration(to: .now)) }
            else if firstPartial == nil {
                firstPartial = seconds(start.duration(to: .now))
                firstPartialAudio = fedSeconds
            }
        }
        try #require(await controller.start(provider: provider, config: provider.buildSessionConfig()))
        start = .now
        for offset in stride(from: 0, to: pcm.count, by: 3200) {
            let end = min(offset + 3200, pcm.count)
            let nextSeconds = Double(end) / 32000
            try await Task.sleep(until: start + .seconds(nextSeconds), clock: .continuous)
            fedSeconds = nextSeconds
            controller._testEnqueueAudioFrame(Data(pcm[offset..<end]), capturedAt: start + .seconds(Double(offset) / 32000))
            maximumQueued = max(maximumQueued, controller._testPendingAudioChunkCount)
            processPeak = max(processPeak, probeMemory()["processFootprintBytes"] ?? 0)
        }
        let stopAt = seconds(start.duration(to: .now))
        await controller.stop(trailingFinalTimeout: 2)
        let stoppedAt = seconds(start.duration(to: .now))
        #expect(errors == 0)
        #expect(firstPartial != nil && finalAt != nil)
        #expect(controller._testDroppedAudioChunkCount == 0)
        await lease.release()
        try await runtime.unload(model.id)
        let cleaned = probeMemory()
        let metric: [String: Any] = [
            "model": model.id.rawValue, "revision": model.manifest.revision,
            "audioSeconds": Double(samples.count) / 16000, "loadSeconds": loadSeconds,
            "firstPartialWallSeconds": firstPartial as Any? ?? NSNull(),
            "firstPartialFedAudioSeconds": firstPartialAudio as Any? ?? NSNull(),
            "finalWallSeconds": finalAt as Any? ?? NSNull(), "stopRequestedSeconds": stopAt,
            "stopCompletedSeconds": stoppedAt, "stopDrainSeconds": stoppedAt - stopAt,
            "textUpdateCount": updates, "errors": errors, "maximumQueuedChunks": maximumQueued,
            "sampledProcessPeakBytes": processPeak, "before": before, "loaded": loaded, "cleaned": cleaned,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue
        ]
        let data = try JSONSerialization.data(withJSONObject: metric, options: [.sortedKeys])
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data + Data([10]))
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func probeMemory() -> [String: UInt64] {
        var values: [String: UInt64] = [:]
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { values["processFootprintBytes"] = info.phys_footprint }
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmCapacity = Int(vmCount)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: vmCapacity) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS {
            values["systemFreePages"] = UInt64(vm.free_count)
            values["systemActivePages"] = UInt64(vm.active_count)
            values["systemInactivePages"] = UInt64(vm.inactive_count)
            values["systemWiredPages"] = UInt64(vm.wire_count)
            values["systemCompressorPages"] = UInt64(vm.compressor_page_count)
            var pageSize: vm_size_t = 0
            if host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS { values["pageSizeBytes"] = UInt64(pageSize) }
        }
        return values
    }
}
