import AVFoundation

/// Rebuilds only capture on a route change, retaining queued audio and provider sessions.
@MainActor
final class RoutedMicrophoneCapture {
    private let driver: any MicrophoneCaptureDriving
    private let selection: MicrophoneSelection
    private var route: MicrophoneRoute
    private var observer: UUID?
    private var currentDevice: MicrophoneDevice?
    private var makeConsumer: ((AVAudioFormat) throws -> MicrophoneBufferConsumer)?
    private var generation: UInt64 = 0
    private var reconfiguration: Task<Void, Never>?
    private let startupTimeout: Duration
    var onFailure: ((Error) -> Void)?

    init(selection: MicrophoneSelection = .shared, driver: any MicrophoneCaptureDriving = HALMicrophoneDriver(),
         startupTimeout: Duration = .seconds(5)) {
        self.startupTimeout = startupTimeout
        self.driver = driver
        self.selection = selection
        route = MicrophoneRoute(preferredUID: selection.preferredUID)
    }

    func start(makeConsumer: @escaping (AVAudioFormat) throws -> MicrophoneBufferConsumer) async throws {
        stop()
        let startingGeneration = generation
        self.makeConsumer = makeConsumer
        selection.refresh()
        do {
            try await activateRoute(generation: startingGeneration)
            try Task.checkCancellation()
            guard generation == startingGeneration else { throw CancellationError() }
            observer = selection.observe { [weak self] in self?.refreshRoute() }
        } catch {
            if generation == startingGeneration { stop() }
            throw error
        }
    }

    func stop() {
        generation &+= 1
        reconfiguration?.cancel()
        reconfiguration = nil
        if let observer { selection.removeObserver(observer) }
        observer = nil
        driver.stop()
        makeConsumer = nil
        currentDevice = nil
        selection.captureStopped()
    }

    private func activateRoute(generation expected: UInt64) async throws {
        guard let makeConsumer else { throw MicrophoneError.unavailable }
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            guard let device = route.resolve(selection.snapshot) else { throw MicrophoneError.unavailable }
            driver.stop()
            try driver.start(deviceID: device.id, makeConsumer: makeConsumer)
            currentDevice = device
            let deadline = ContinuousClock.now + startupTimeout
            while !driver.hasDeliveredFrames, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                guard generation == expected else { throw CancellationError() }
            }
            guard generation == expected else { throw CancellationError() }
            if driver.hasDeliveredFrames {
                try Task.checkCancellation()
                selection.captured(device, fallback: route.preferredUID != nil && device.uid != route.preferredUID)
                return
            }
        }
        throw MicrophoneError.noAudioFrames
    }

    private func refreshRoute() {
        guard observer != nil, reconfiguration == nil else { return }
        do {
            guard let device = route.resolve(selection.snapshot) else { throw MicrophoneError.unavailable }
            guard try device != currentDevice || driver.configurationChanged() else { return }
            let expected = generation
            reconfiguration = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.activateRoute(generation: expected)
                } catch {
                    guard self.generation == expected else { return }
                    self.fail(error)
                }
                if self.generation == expected { self.reconfiguration = nil }
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        stop()
        selection.captureStopped(error: error.localizedDescription)
        onFailure?(error)
    }

    isolated deinit {
        reconfiguration?.cancel()
        if let observer { selection.removeObserver(observer) }
        driver.stop()
    }
}
