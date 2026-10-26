import Foundation

/// Missing or inconsistent milestones remain unknown, never zero-filled.
/// Response wait includes network delay, not just server processing. Upload timing
/// does not prove server receipt. TLS can overlap connect; do not sum both.
enum HTTPPhaseMetrics {
    struct Milestones {
        var fetchStart: Date?
        var dnsStart: Date?
        var dnsEnd: Date?
        var connectStart: Date?
        var connectEnd: Date?
        var tlsStart: Date?
        var tlsEnd: Date?
        var requestStart: Date?
        var requestEnd: Date?
        var responseStart: Date?
        var responseEnd: Date?
    }

    static func fields(_ times: Milestones) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, start, end) in [
            ("dnsMs", times.dnsStart, times.dnsEnd),
            ("connectMs", times.connectStart, times.connectEnd),
            ("tlsMs", times.tlsStart, times.tlsEnd),
            ("uploadMs", times.requestStart, times.requestEnd),
            ("responseWaitMs", times.requestEnd, times.responseStart),
            ("downloadMs", times.responseStart, times.responseEnd),
            ("timeToFirstByteMs", times.fetchStart, times.responseStart)
        ] {
            guard let start, let end else { continue }
            let milliseconds = end.timeIntervalSince(start) * 1000
            guard milliseconds.isFinite, milliseconds >= 0 else { continue }
            fields[key] = String(format: "%.3f", milliseconds)
        }
        return fields
    }
}
