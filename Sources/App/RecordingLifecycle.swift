import Foundation

/// Lifecycle hooks for pluggable recording subsystems.
///
/// Components can prepare/start/stop/cancel independently while
/// `RecordingController` remains focused on orchestration.
@MainActor
protocol RecordingComponent: AnyObject {
    /// Called before recording is considered started.
    /// Throw to abort startup.
    func prepareForRecording() throws

    /// Called after startup succeeds.
    func recordingDidStart()

    /// Called on normal stop.
    func recordingDidStop()

    /// Called on cancellation/abort.
    func recordingWasCancelled()
}

@MainActor
extension RecordingComponent {
    func prepareForRecording() throws {}
    func recordingDidStart() {}
    func recordingDidStop() {}
    func recordingWasCancelled() {}
}

/// Coordinates `RecordingComponent` lifecycle transitions.
@MainActor
final class RecordingLifecycleCoordinator {
    private var components: [any RecordingComponent] = []
    private var prepared = false

    func setComponents(_ components: [any RecordingComponent]) {
        self.components = components
        prepared = false
    }

    func prepareAndStart() throws {
        if !prepared {
            for component in components {
                try component.prepareForRecording()
            }
            prepared = true
        }
        for component in components {
            component.recordingDidStart()
        }
    }

    func stop() {
        for component in components {
            component.recordingDidStop()
        }
        prepared = false
    }

    func cancel() {
        for component in components.reversed() {
            component.recordingWasCancelled()
        }
        prepared = false
    }
}

/// Key interception lifecycle adapter.
@MainActor
final class KeyInterceptorRecordingComponent: RecordingComponent {
    private let interceptor: any KeyIntercepting
    private let targetPidProvider: () -> pid_t

    init(interceptor: any KeyIntercepting, targetPidProvider: @escaping () -> pid_t) {
        self.interceptor = interceptor
        self.targetPidProvider = targetPidProvider
    }

    func recordingDidStart() {
        interceptor.start(targetPid: targetPidProvider())
    }

    func recordingDidStop() {
        interceptor.stop()
    }

    func recordingWasCancelled() {
        interceptor.stop()
    }
}
