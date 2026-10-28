import Testing
@testable import SpeakFlowCore

@Suite("Retained provider finals at normal stop", .serialized)
struct StreamingStopSettlementTests {
    @Test @MainActor
    func normalStopSettlesRetainedFinalsExactlyOnce() async {
        let controller = LiveStreamingController()
        controller.minimumFinalWordCount = 3
        let collector = TextUpdateCollector()
        collector.wire(controller)
        controller.handleEvent(.finalResult(.init(transcript: "hello", start: 0, duration: 1, isFinal: true)))
        controller.handleEvent(.finalResult(.init(transcript: "world", start: 1, duration: 1, isFinal: true)))
        #expect(collector.finals.isEmpty)
        await controller.stop(trailingFinalTimeout: 0)
        await controller.stop(trailingFinalTimeout: 0)
        #expect(collector.finals.map(\.fullText) == ["hello world"])
        #expect(collector.screenText == "hello world ")
    }

    @Test @MainActor
    func untimedProviderFinalSettlesAtStop() async {
        let controller = LiveStreamingController()
        controller.minimumFinalWordCount = 3
        let collector = TextUpdateCollector()
        collector.wire(controller)
        controller.handleEvent(.finalResult(.init(transcript: "hello", isFinal: true)))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(collector.finals.map(\.fullText) == ["hello"])
        #expect(collector.screenText == "hello ")
    }

    @Test @MainActor
    func untimedFinalCannotAccumulateWithTimedRevision() async {
        let controller = LiveStreamingController()
        controller.minimumFinalWordCount = 3
        let collector = TextUpdateCollector()
        collector.wire(controller)
        controller.handleEvent(.finalResult(.init(transcript: "old", isFinal: true)))
        controller.handleEvent(.finalResult(.init(transcript: "revised", start: 1, duration: 1, isFinal: true)))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(collector.finals.map(\.fullText) == ["revised"])
        #expect(collector.screenText == "revised ")
    }

    @Test @MainActor
    func retainedFinalDoesNotPromoteSubsequentInterim() async {
        let controller = LiveStreamingController()
        controller.minimumFinalWordCount = 3
        let collector = TextUpdateCollector()
        collector.wire(controller)
        controller.handleEvent(.finalResult(.init(transcript: "hello", start: 0, duration: 1, isFinal: true)))
        controller.handleEvent(.interim(.init(transcript: "unconfirmed", start: 1, duration: 1)))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(collector.finals.map(\.fullText) == ["hello"])
        #expect(collector.screenText == "hello ")
    }

    @Test @MainActor
    func stopDoesNotPromoteArbitraryInterimOrCancelledFinals() async {
        let controller = LiveStreamingController()
        controller.minimumFinalWordCount = 3
        let collector = TextUpdateCollector()
        collector.wire(controller)
        controller.handleEvent(.interim(.init(transcript: "unconfirmed")))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(collector.finals.isEmpty)
        controller.handleEvent(.finalResult(.init(transcript: "cancelled", start: 0, duration: 1, isFinal: true)))
        await controller.cancel()
        await controller.stop(trailingFinalTimeout: 0)
        #expect(collector.finals.allSatisfy { $0.fullText.isEmpty })
    }
}
