import AppKit
import Foundation

enum LocalModelResourceEvent: Equatable { case memoryPressure, sleep, wake, thermalWarning, thermalRecovered }

/// Listens without changing system settings. Recovery never starts capture or downloads.
@MainActor
final class LocalModelResourceMonitor {
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let pressure: DispatchSourceMemoryPressure

    init(notifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         onEvent: @escaping @MainActor (LocalModelResourceEvent) -> Void) {
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { Task { @MainActor in onEvent(.memoryPressure) } }
        pressure.resume()
        observers.append(notifications.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { _ in
                let high = [.serious, .critical].contains(thermalState())
                Task { @MainActor in onEvent(high ? .thermalWarning : .thermalRecovered) }
            })
        for (name, event) in [(NSWorkspace.willSleepNotification, LocalModelResourceEvent.sleep),
                              (NSWorkspace.didWakeNotification, LocalModelResourceEvent.wake)] {
            workspaceObservers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onEvent(event) }
            })
        }
    }

    isolated deinit {
        pressure.cancel()
        for observer in observers { notifications.removeObserver(observer) }
        for observer in workspaceObservers { workspaceNotifications.removeObserver(observer) }
    }
}
