import CoreGraphics
import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Borrowed callback event ownership", .serialized)
struct BorrowedEventOwnershipTests {
    @Test(arguments: [CGEventType.keyDown, .flagsChanged, .tapDisabledByTimeout, .tapDisabledByUserInput], [false, true])
    @MainActor
    func callbacksReturnBorrowedEventsWithoutRetaining(type: CGEventType, hasContext: Bool) throws {
        let listener = HotkeyListener(eventTapDriver: FakeHotkeyEventTapDriver().driver)
        let interceptor = KeyInterceptor(eventTapDriver: FakeEventTapDriver().driver)
        let event = try #require(CGEvent(source: nil))
        event.type = type
        event.setIntegerValueField(.keyboardEventKeycode, value: 0)
        let callbacks: [(CGEventTapCallBack, UnsafeMutableRawPointer)] = [
            (HotkeyListener.eventTapCallback, Unmanaged.passUnretained(listener).toOpaque()),
            (KeyInterceptor.eventTapCallback, Unmanaged.passUnretained(interceptor).toOpaque())
        ]
        for (callback, context) in callbacks {
            let before = CFGetRetainCount(event)
            let returned = callback(CGEventTapProxy(bitPattern: 1)!, type, event, hasContext ? context : nil)
            #expect(returned?.takeUnretainedValue() === event)
            let after = CFGetRetainCount(event)
            #expect(after == before, "Returning the incoming event must not add a retain")
            // Clean up only the measured leak on red; do not assume ownership on green.
            if after > before { returned?.release() }
        }
    }
}
