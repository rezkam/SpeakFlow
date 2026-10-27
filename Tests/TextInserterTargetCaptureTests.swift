import ApplicationServices
import Testing
@testable import SpeakFlow

@Suite("Accessibility target capture", .serialized)
@MainActor
struct TextInserterTargetCaptureTests {
    @Test func activatesAccessibilityBeforeCapturingTheEditor() {
        let field = AXUIElementCreateApplication(100_001)
        var activated = false
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.setCaptureAccessibilityForTesting(TargetCaptureAccessibility(
            frontmostPid: { 100_001 },
            prepareApplication: { _ in
                activated = true
                // Electron can enable the tree yet return notImplemented.
                return .notImplemented
            },
            systemFocus: { activated ? (.success, field) : (.cannotComplete, nil) },
            processId: { _ in 100_001 },
            window: { _ in nil },
            sameApplication: { $0 == $1 }
        ))

        #expect(inserter.captureTarget(), "Editor capture must activate its accessibility tree before querying focus")
        #expect(activated)
        #expect(inserter.targetPid == 100_001)
        #expect(inserter.targetElement != nil)
    }

    @Test(arguments: [true, false])
    func activationNeverCapturesAnotherApplication(focusChanges: Bool) {
        let field = AXUIElementCreateApplication(100_002)
        var frontmost: pid_t = 100_001
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = field
        inserter.targetPid = 100_001
        inserter.setCaptureAccessibilityForTesting(TargetCaptureAccessibility(
            frontmostPid: { frontmost },
            prepareApplication: { _ in
                if focusChanges { frontmost = 100_002 }
                return .success
            },
            systemFocus: { (.success, field) },
            processId: { _ in 100_002 },
            window: { _ in nil },
            sameApplication: { $0 == $1 }
        ))

        #expect(!inserter.captureTarget(), "Activation must never follow focus or accept a foreign application's field")
        #expect(inserter.targetElement == nil)
        #expect(inserter.targetPid == 0)
    }

    @Test(arguments: [AXError.apiDisabled, .cannotComplete, .noValue, .success])
    func activationWithoutAFocusedElementStillRefusesCapture(status: AXError) {
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.setCaptureAccessibilityForTesting(TargetCaptureAccessibility(
            frontmostPid: { 100_001 },
            prepareApplication: { _ in .success },
            systemFocus: { (status, nil) },
            processId: { _ in 100_001 },
            window: { _ in nil },
            sameApplication: { $0 == $1 }
        ))
        #expect(!inserter.captureTarget())
        #expect(inserter.targetElement == nil)
        #expect(inserter.targetPid == 0)
    }

    @Test func helperProcessOwnedByTheOriginalApplicationCanBeCaptured() {
        let field = AXUIElementCreateApplication(100_002)
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.setCaptureAccessibilityForTesting(TargetCaptureAccessibility(
            frontmostPid: { 100_001 },
            prepareApplication: { _ in .success },
            systemFocus: { (.success, field) },
            processId: { _ in 100_002 },
            window: { _ in nil },
            sameApplication: { $0 == 100_001 && $1 == 100_002 }
        ))
        #expect(inserter.captureTarget())
        #expect(inserter.targetPid == 100_002)
    }
}
