import SwiftUI
import SpeakFlowCore

// MARK: - AppState

private struct AppStateKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = AppState.shared
}

extension EnvironmentValues {
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}

// MARK: - RecordingController

private struct RecordingControllerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = RecordingController.shared
}

extension EnvironmentValues {
    var recordingController: RecordingController {
        get { self[RecordingControllerKey.self] }
        set { self[RecordingControllerKey.self] = newValue }
    }
}

// MARK: - PermissionController

private struct PermissionControllerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = PermissionController.shared
}

extension EnvironmentValues {
    var permissionController: PermissionController {
        get { self[PermissionControllerKey.self] }
        set { self[PermissionControllerKey.self] = newValue }
    }
}

// MARK: - AuthController

private struct AuthControllerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = AuthController.shared
}

extension EnvironmentValues {
    var authController: AuthController {
        get { self[AuthControllerKey.self] }
        set { self[AuthControllerKey.self] = newValue }
    }
}

// MARK: - Statistics

private struct StatisticsKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = Statistics.shared
}

extension EnvironmentValues {
    var statistics: Statistics {
        get { self[StatisticsKey.self] }
        set { self[StatisticsKey.self] = newValue }
    }
}
