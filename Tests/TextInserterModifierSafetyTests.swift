import ApplicationServices
import Testing
@testable import SpeakFlow

@Suite("TextInserter Modifier Safety")
struct TextInserterModifierSafetyTests {
    @MainActor
    @Test
    func hasActiveModifiersDetectsPressedFlags() {
        #expect(!TextInserter._testHasActiveModifiers([]))
        #expect(TextInserter._testHasActiveModifiers(.maskCommand))
        #expect(TextInserter._testHasActiveModifiers(.maskControl))
        #expect(TextInserter._testHasActiveModifiers(.maskAlternate))
        #expect(TextInserter._testHasActiveModifiers(.maskShift))
    }

    @MainActor
    @Test
    func waitForModifiersReleasedSucceedsWhenReleasedBeforeTimeout() async {
        let inserter = TextInserter.shared
        let sequence: [CGEventFlags] = [.maskCommand, .maskCommand, []]
        var index = 0

        let released = await inserter._testWaitForModifiersReleased(maxAttempts: 5) {
            let value = sequence[min(index, sequence.count - 1)]
            index += 1
            return value
        }

        #expect(released)
    }

    @MainActor
    @Test
    func waitForModifiersReleasedFailsWhenStillPressedAtTimeout() async {
        let inserter = TextInserter.shared
        let released = await inserter._testWaitForModifiersReleased(maxAttempts: 2) {
            .maskCommand
        }

        #expect(!released)
    }
}
