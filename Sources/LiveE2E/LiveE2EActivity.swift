import Foundation
import IOKit.pwr_mgt

/// Keep file playback and its timers runnable during unattended timing checks.
/// This does not prevent explicit user sleep, lid closure, or system shutdown.
final class LiveE2EActivity {
    private(set) var assertionID: IOPMAssertionID = 0
    private var active = false

    init() throws {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "File audio timing verification" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "LiveE2EActivity", code: Int(result))
        }
        active = true
    }

    func finish() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        active = false
    }

    deinit {
        if active { IOPMAssertionRelease(assertionID) }
    }
}
