import AppKit
import Foundation
import Testing
@testable import SpeakFlowCore

private final class FakeKeyMonitors: @unchecked Sendable {
    var global: ((NSEvent) -> Void)?
    var local: ((NSEvent) -> NSEvent?)?
    private let lock = NSLock()
    private var removals = 0
    var removedCount: Int { lock.withLock { removals } }
    var driver: HotkeyListener.EventMonitorDriver {
        .init(addGlobal: { [self] in global = $0; return NSObject() },
              addLocal: { [self] in local = $0; return NSObject() },
              remove: { [self] _ in lock.withLock { removals += 1 } })
    }
}

@Suite("Combination hotkey local monitoring", .serialized)
struct HotkeyLocalMonitorTests {
    @Test @MainActor
    func deinitRemovesBothCombinationMonitors() {
        let monitors = FakeKeyMonitors()
        var listener: HotkeyListener? = HotkeyListener(
            eventTapDriver: FakeHotkeyEventTapDriver().driver, eventMonitorDriver: monitors.driver
        )
        weak var released = listener
        listener?.start(type: .controlOptionD)
        listener = nil
        #expect(released == nil)
        #expect(monitors.removedCount == 2, "Deinitialization must remove both local and global monitors")
    }

    @Test(arguments: [HotkeyType.controlOptionD, .controlOptionSpace, .commandShiftD])
    @MainActor
    func bothMonitorRoutesActivateAndIgnoreRepeats(type: HotkeyType) async throws {
        let monitors = FakeKeyMonitors()
        let listener = HotkeyListener(eventTapDriver: FakeHotkeyEventTapDriver().driver,
                                      eventMonitorDriver: monitors.driver)
        var activations = 0
        listener.onActivate = { activations += 1 }
        listener.start(type: type)
        defer { listener.stop() }
        let local = try #require(monitors.local, "Combination detection must register a local monitor")
        let global = try #require(monitors.global)
        let key: UInt16 = type == .controlOptionSpace ? 49 : 2
        let flags: NSEvent.ModifierFlags = type == .commandShiftD ? [.command, .shift] : [.control, .option]
        func event(repeatKey: Bool) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
                isARepeat: repeatKey, keyCode: key))
        }
        let fresh = try event(repeatKey: false)
        #expect(local(fresh) === fresh, "Local observation must not swallow the app's keyboard event")
        global(fresh)
        let repeated = try event(repeatKey: true)
        _ = local(repeated)
        global(repeated)
        try await waitUntil { activations == 2 }
        #expect(activations == 2)
        listener.stop()
        #expect(monitors.removedCount == 2, "Stop must remove both registrations exactly once")
    }
}
