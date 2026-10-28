import AppKit
import ApplicationServices
import SpeakFlowCore

/// Enables the active app's accessibility tree ahead of the hotkey. Never captures a field.
@MainActor
final class ApplicationAccessibilityPrewarmer {
    private let center: NotificationCenter
    private let frontmostPid: () -> pid_t?
    private let isAllowed: () -> Bool
    private let prepare: @Sendable (pid_t) -> Void
    private var observers: [NSObjectProtocol] = []
    private var inFlight: [pid_t: UUID] = [:]

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostPid: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        isAllowed: @escaping () -> Bool = { !RuntimeIsolation.current.isIsolated && AXIsProcessTrusted() },
        prepare: @escaping @Sendable (pid_t) -> Void = { _ = TargetCaptureAccessibility.prepareApplication($0) }
    ) {
        self.center = center
        self.frontmostPid = frontmostPid
        self.isAllowed = isAllowed
        self.prepare = prepare
    }

    func start() {
        guard isAllowed(), observers.isEmpty else { return }
        observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.prepareFrontmostApplication() }
            }
        }
        prepareFrontmostApplication()
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
        inFlight.removeAll()
    }

    private func prepareFrontmostApplication() {
        guard !observers.isEmpty, isAllowed(),
              let pid = frontmostPid(), pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              inFlight[pid] == nil else { return }
        let ticket = UUID()
        inFlight[pid] = ticket
        let prepare = prepare
        // AX can block on another process. No AX request runs on the main actor here.
        Task.detached(priority: .userInitiated) { [weak self] in
            prepare(pid)
            await self?.finished(pid, ticket: ticket)
        }
    }

    private func finished(_ pid: pid_t, ticket: UUID) {
        guard inFlight[pid] == ticket else { return }
        inFlight[pid] = nil
    }
}
