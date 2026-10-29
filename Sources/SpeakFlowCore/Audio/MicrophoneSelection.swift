import Foundation
import Observation

/// Preference and live catalog shared by settings, the menu, and both capture paths.
@MainActor
@Observable
public final class MicrophoneSelection {
    public static let shared = MicrophoneSelection(
        catalog: MicrophoneCatalog(), defaults: RuntimeIsolation.current.makeDefaults(prefix: "microphone.tests")
    )
    public private(set) var snapshot = MicrophoneSnapshot(devices: [], defaultID: 0)
    public private(set) var preferredUID: String?
    public private(set) var activeDevice: MicrophoneDevice?
    public private(set) var captureMessage: String?
    public private(set) var catalogFailed = false
    @ObservationIgnored private let defaults: UserDefaults?
    private static let preferenceKey = "preferredMicrophoneUID"
    @ObservationIgnored private let catalog: any MicrophoneCatalogProviding
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [UUID: () -> Void] = [:]

    public init(catalog: any MicrophoneCatalogProviding, preferredUID: String? = nil,
                defaults: UserDefaults? = nil, monitor: Bool = true) {
        self.catalog = catalog
        self.defaults = defaults
        self.preferredUID = preferredUID ?? defaults?.string(forKey: Self.preferenceKey)
        refresh()
        if monitor {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    isolated deinit { timer?.invalidate() }

    public var resolvedDevice: MicrophoneDevice? {
        MicrophoneDevice.resolve(preferredUID: preferredUID, devices: snapshot.devices, defaultID: snapshot.defaultID)
    }

    public var preferenceUnavailable: Bool {
        guard let preferredUID else { return false }
        return !snapshot.devices.contains { $0.uid == preferredUID }
    }

    public func label(for device: MicrophoneDevice) -> String {
        let duplicates = snapshot.devices.filter { $0.name == device.name }
        guard duplicates.count > 1, let index = duplicates.firstIndex(of: device) else { return device.name }
        return "\(device.name) (\(index + 1))"
    }

    public var menuStatusText: String {
        if catalogFailed { return "Could not refresh inputs" }
        if let activeDevice { return "Recording: \(label(for: activeDevice))" }
        guard let device = resolvedDevice else { return "No input available" }
        return "Using: \(label(for: device))"
    }

    public func statusText(isRecording: Bool) -> String {
        if catalogFailed { return "Microphones could not be refreshed. Check your audio devices." }
        if let captureMessage, activeDevice == nil { return captureMessage }
        if snapshot.devices.isEmpty { return "No microphones found. Connect an input device to continue." }
        if isRecording, let activeDevice {
            let prefix = captureMessage.map { $0 + " " } ?? ""
            return prefix + "Recording with \(label(for: activeDevice)). Changes apply to the next recording."
        }
        guard let device = resolvedDevice else { return "No system input is available. Choose a connected microphone." }
        if preferenceUnavailable {
            return "Preferred microphone unavailable. Using \(label(for: device)) until it reconnects."
        }
        return "Using \(label(for: device)). If disconnected, SpeakFlow switches to the system input."
    }

    public func select(_ uid: String?) {
        preferredUID = uid
        defaults?.set(uid, forKey: Self.preferenceKey)
        if activeDevice == nil { captureMessage = nil }
    }

    public func refresh() {
        do {
            let next = try catalog.snapshot()
            if next != snapshot { snapshot = next }
            catalogFailed = false
        } catch {
            catalogFailed = true
            // Do not report a stale device as available after a catalog failure.
            snapshot = MicrophoneSnapshot(devices: [], defaultID: 0)
        }
        for observer in Array(observers.values) { observer() }
    }

    func observe(_ action: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func captured(_ device: MicrophoneDevice, fallback: Bool) {
        activeDevice = device
        captureMessage = fallback ? "Microphone disconnected. Switched to the system input." : nil
    }

    func captureStopped(error: String? = nil) {
        activeDevice = nil
        captureMessage = error
    }
}
