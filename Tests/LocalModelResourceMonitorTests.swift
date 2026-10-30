import AppKit
import Foundation
import Testing
@testable import SpeakFlow

@Suite("Local model resource notifications")
struct LocalModelResourceMonitorTests {
    @MainActor @Test func sleepWakeAndThermalNotificationsUseExplicitRecoveryEvents() async throws {
        let notifications = NotificationCenter(), workspace = NotificationCenter()
        var events: [LocalModelResourceEvent] = []
        let monitor = LocalModelResourceMonitor(notifications: notifications, workspaceNotifications: workspace,
            thermalState: { .serious }, onEvent: { events.append($0) })
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        notifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await waitUntil { events.count == 3 }
        #expect(events == [.sleep, .wake, .thermalWarning])
        withExtendedLifetime(monitor) {}
    }
}
