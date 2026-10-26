import AppKit
import Testing
@testable import SpeakFlowCore

private final class SyntheticMonitorToken: NSObject, @unchecked Sendable {}

@Suite("Native local hotkey routing", .serialized)
struct HotkeyNativeMonitorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func applicationDispatchReachesTheLocalMonitor() async throws {
        guard NativeUIProbeSupport.isChild(for: "HotkeyNativeMonitorTests") else {
            try NativeUIProbeSupport.runChild(suite: "HotkeyNativeMonitorTests")
            return
        }
        _ = NSApplication.shared
        let driver = HotkeyListener.EventMonitorDriver(
            addGlobal: { _ in SyntheticMonitorToken() },
            addLocal: HotkeyListener.EventMonitorDriver.system.addLocal,
            remove: { if !($0 is SyntheticMonitorToken) { NSEvent.removeMonitor($0) } }
        )
        let listener = HotkeyListener(eventTapDriver: FakeHotkeyEventTapDriver().driver,
                                      eventMonitorDriver: driver)
        var activations = 0
        listener.onActivate = { activations += 1 }
        for type in [HotkeyType.controlOptionD, .controlOptionSpace, .commandShiftD] {
            listener.start(type: type)
            let previous = activations
            let flags: NSEvent.ModifierFlags = type == .commandShiftD ? [.command, .shift] : [.control, .option]
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
                isARepeat: false, keyCode: type == .controlOptionSpace ? 49 : 2))
            NSApp.sendEvent(event)
            try await waitUntil { activations == previous + 1 }
            listener.stop()
            NSApp.sendEvent(event)
            // A main-actor barrier lets any incorrectly registered callback execute.
            await Task { @MainActor in }.value
            #expect(activations == previous + 1, "Stop must remove the real local monitor")
        }
    }
}
