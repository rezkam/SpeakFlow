import AVFoundation
import CoreAudio
import Testing
@testable import SpeakFlowCore

@Suite("Microphone capture lifecycle")
@MainActor
struct MicrophoneCaptureTests {
    let first = MicrophoneDevice(id: 1, uid: "fixture-a", name: "Input A")
    let second = MicrophoneDevice(id: 2, uid: "fixture-b", name: "Input B")

    @Test func disconnectRebuildsCaptureAndReconnectWaitsForNextSession() async throws {
        let catalog = StubMicrophoneCatalog(.init(devices: [first, second], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, preferredUID: second.uid, monitor: false)
        let driver = SpyMicrophoneDriver()
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        var formats = 0
        try await capture.start { _ in formats += 1; return { _ in } }
        #expect(driver.devices == [2])
        catalog.value = .init(devices: [first], defaultID: 1)
        selection.refresh()
        try await waitUntil { selection.activeDevice == first }
        #expect(driver.devices == [2, 1])
        #expect(selection.activeDevice == first)
        catalog.value = .init(devices: [first, second], defaultID: 1)
        selection.refresh()
        #expect(driver.devices == [2, 1])
        #expect(formats == 2)
        capture.stop()
    }

    @Test func formatChangesRecreateConsumer() async throws {
        let catalog = StubMicrophoneCatalog(.init(devices: [first], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        var formats: [Double] = []
        try await capture.start { format in formats.append(format.sampleRate); return { _ in } }
        driver.rate = 48000
        driver.changed = true
        selection.refresh()
        try await waitUntil { formats.count == 2 }
        #expect(formats == [16000, 48000])
        capture.stop()
    }

    @Test func stopDetachesObserverAndClearsActiveInput() async throws {
        let catalog = StubMicrophoneCatalog(.init(devices: [first, second], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        try await capture.start { _ in { _ in } }
        capture.stop()
        catalog.value = .init(devices: [second], defaultID: 2)
        selection.refresh()
        #expect(driver.devices == [1])
        #expect(!driver.running)
        #expect(selection.activeDevice == nil)
    }

    @Test func noFallbackStopsCaptureAndReportsFailureOnce() async throws {
        let catalog = StubMicrophoneCatalog(.init(devices: [first], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        var failures = 0
        capture.onFailure = { _ in failures += 1 }
        try await capture.start { _ in { _ in } }
        catalog.value = .init(devices: [], defaultID: 0)
        selection.refresh()
        selection.refresh()
        #expect(failures == 1)
        #expect(!driver.running)
        #expect(selection.activeDevice == nil)
    }

    @Test func fallbackMustDeliverFramesBeforeItIsReportedReady() async throws {
        let catalog = StubMicrophoneCatalog(.init(devices: [first, second], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, preferredUID: second.uid, monitor: false)
        let driver = SpyMicrophoneDriver()
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver, startupTimeout: .milliseconds(1))
        var failures = 0
        capture.onFailure = { _ in failures += 1 }
        try await capture.start { _ in { _ in } }
        driver.hasDeliveredFrames = false
        catalog.value = .init(devices: [first], defaultID: 1)
        selection.refresh()
        #expect(selection.activeDevice != first, "A fallback without audio must not be reported ready")
        try await waitUntil { failures == 1 }
        #expect(selection.activeDevice == nil)
        #expect(!driver.running)
    }

    @Test func noFramesDoesNotPublishAFalseReadyInput() async {
        let catalog = StubMicrophoneCatalog(.init(devices: [first], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        driver.hasDeliveredFrames = false
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver, startupTimeout: .milliseconds(1))
        await #expect(throws: MicrophoneError.self) { try await capture.start { _ in { _ in } } }
        #expect(selection.activeDevice == nil)
        #expect(!driver.running)
        #expect(driver.devices.count == 3)
    }

    @Test func stopDuringReadinessCannotReviveCapture() async {
        let catalog = StubMicrophoneCatalog(.init(devices: [first], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        driver.hasDeliveredFrames = false
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        let startup = Task { try await capture.start { _ in { _ in } } }
        while driver.devices.isEmpty { await Task.yield() }
        capture.stop()
        driver.hasDeliveredFrames = true
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(!driver.running)
        #expect(selection.activeDevice == nil)
        #expect(driver.devices.count == 1)
    }

    @Test func taskCancellationStopsPendingCapture() async {
        let catalog = StubMicrophoneCatalog(.init(devices: [first], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        driver.hasDeliveredFrames = false
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        let startup = Task { try await capture.start { _ in { _ in } } }
        while driver.devices.isEmpty { await Task.yield() }
        startup.cancel()
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(!driver.running)
        #expect(selection.activeDevice == nil)
    }

    @Test func routingFailureDoesNotPublishAnActiveInput() async {
        let catalog = StubMicrophoneCatalog(.init(devices: [first], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let driver = SpyMicrophoneDriver()
        driver.fail = true
        let capture = RoutedMicrophoneCapture(selection: selection, driver: driver)
        await #expect(throws: MicrophoneError.self) { try await capture.start { _ in { _ in } } }
        #expect(selection.activeDevice == nil)
        #expect(!driver.running)
    }
}

@MainActor
final class SpyMicrophoneDriver: MicrophoneCaptureDriving {
    var devices: [UInt32] = []
    var hasDeliveredFrames = true
    var running = false
    var changed = false
    var fail = false
    var rate: Double = 16000
    func start(deviceID: UInt32, makeConsumer: (AVAudioFormat) throws -> MicrophoneBufferConsumer) throws {
        if fail { throw MicrophoneError.unavailable }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        _ = try makeConsumer(format)
        devices.append(deviceID)
        running = true
        changed = false
    }
    func configurationChanged() throws -> Bool { changed }
    func stop() { running = false }
}

@Suite("Microphone startup")
struct MicrophoneIOStartTests {
    @Test func activatingDeviceCanBecomeReady() async throws {
        var attempts = 0
        try startMicrophoneIO({
            attempts += 1
            return attempts < 3 ? kAudioHardwareNotRunningError : noErr
        }, pause: { _ in })
        #expect(attempts == 3)
    }

    @Test func permanentFailureDoesNotRetry() {
        var attempts = 0
        #expect(throws: MicrophoneError.self) {
            try startMicrophoneIO({ attempts += 1; return kAudio_ParamError }, pause: { _ in })
        }
        #expect(attempts == 1)
    }

    @Test func unavailableDeviceHasABoundedStartup() {
        var attempts = 0
        #expect(throws: MicrophoneError.self) {
            try startMicrophoneIO({ attempts += 1; return kAudioHardwareNotRunningError }, pause: { _ in })
        }
        #expect(attempts == 3)
    }
}
