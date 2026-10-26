import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("HTTP phase metrics")
struct HTTPPhaseMetricsTests {
    @Test func phasesUseActualMilestonesAndDoNotDoubleCountTLS() {
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        let fields = HTTPPhaseMetrics.fields(.init(
            fetchStart: date(0), dnsStart: date(1), dnsEnd: date(2),
            connectStart: date(2), connectEnd: date(5), tlsStart: date(3), tlsEnd: date(5),
            requestStart: date(5), requestEnd: date(6), responseStart: date(10), responseEnd: date(11)
        ))
        for (key, expected) in [
            "dnsMs": 1000.0, "connectMs": 3000, "tlsMs": 2000,
            "uploadMs": 1000, "responseWaitMs": 4000, "downloadMs": 1000, "timeToFirstByteMs": 10000
        ] {
            #expect(Double(fields[key] ?? "") == expected)
        }
        #expect(fields.count == 7, "Only allowlisted durations, never dates or endpoints")
    }

    @Test func absentAndInconsistentMilestonesRemainUnknown() {
        #expect(HTTPPhaseMetrics.fields(.init()).isEmpty)
        let fields = HTTPPhaseMetrics.fields(.init(
            dnsStart: Date(timeIntervalSince1970: 2), dnsEnd: Date(timeIntervalSince1970: 1),
            requestStart: Date(timeIntervalSince1970: 3), requestEnd: Date(timeIntervalSince1970: 3)
        ))
        #expect(fields["dnsMs"] == nil)
        #expect(fields["responseWaitMs"] == nil)
        #expect(Double(fields["uploadMs"] ?? "") == 0)
    }
}
