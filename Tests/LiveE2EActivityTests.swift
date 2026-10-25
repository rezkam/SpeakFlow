import IOKit.pwr_mgt
import Testing
@testable import SpeakFlowLiveE2E

@Suite("Live E2E idle-sleep protection", .serialized)
struct LiveE2EActivityTests {
    @Test func ownsAndReleasesNativeIdleSleepAssertion() throws {
        let activity = try LiveE2EActivity()
        let identifier = activity.assertionID
        let properties = try #require(IOPMAssertionCopyProperties(identifier)?.takeRetainedValue() as? [String: Any])
        #expect(properties[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypeNoIdleSleep)
        #expect(properties[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
        activity.finish()
        #expect(IOPMAssertionCopyProperties(identifier) == nil)
        activity.finish()
    }

    @Test func releasesAssertionOnScopeExit() throws {
        var identifier: IOPMAssertionID = 0
        do {
            let activity = try LiveE2EActivity()
            identifier = activity.assertionID
            #expect(IOPMAssertionCopyProperties(identifier) != nil)
            withExtendedLifetime(activity) {}
        }
        #expect(IOPMAssertionCopyProperties(identifier) == nil)
    }
}
