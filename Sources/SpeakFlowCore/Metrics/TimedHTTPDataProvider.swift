import Foundation

/// Uses a per-task delegate without replacing the session or its connection pool.
struct TimedHTTPDataProvider: HTTPDataProvider {
    let session: URLSession
    let provider: ProviderTiming.Provider

    init(session: URLSession = .shared, provider: ProviderTiming.Provider) {
        self.session = session
        self.provider = provider
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let recorder = ProviderTiming.activeAttempt?.recorder ?? ProviderTiming.Recorder(provider: provider)
        let delegate = HTTPMetricsDelegate(recorder: recorder)
        defer { delegate.completeIfNeeded() }
        return try await session.data(for: request, delegate: delegate)
    }
}

final class HTTPMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let recorder: ProviderTiming.Recorder
    private let start = ContinuousClock.now
    private let lock = NSLock()
    private var completed = false

    init(recorder: ProviderTiming.Recorder) { self.recorder = recorder }

    private func claimCompletion() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    /// Some transports (including custom URLProtocol implementations) supply no metrics.
    func completeIfNeeded() {
        guard claimCompletion() else { return }
        recorder.emit("http_task_metrics", [
            "elapsedMs": ProviderTiming.Attempt.milliseconds(since: start),
            "metricsCollected": "false", "metricsAvailable": "false", "transactionCount": "0"
        ])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard claimCompletion() else { return }
        recorder.emit("http_task_metrics", [
            "elapsedMs": String(format: "%.3f", metrics.taskInterval.duration * 1000),
            "metricsCollected": "true", "metricsAvailable": String(!metrics.transactionMetrics.isEmpty),
            "transactionCount": String(metrics.transactionMetrics.count), "redirectCount": String(metrics.redirectCount)
        ])
        for (index, transaction) in metrics.transactionMetrics.enumerated() {
            var fields = HTTPPhaseMetrics.fields(.init(
                fetchStart: transaction.fetchStartDate,
                dnsStart: transaction.domainLookupStartDate, dnsEnd: transaction.domainLookupEndDate,
                connectStart: transaction.connectStartDate, connectEnd: transaction.connectEndDate,
                tlsStart: transaction.secureConnectionStartDate, tlsEnd: transaction.secureConnectionEndDate,
                requestStart: transaction.requestStartDate, requestEnd: transaction.requestEndDate,
                responseStart: transaction.responseStartDate, responseEnd: transaction.responseEndDate
            ))
            fields["transaction"] = String(index)
            fields["reusedConnection"] = String(transaction.isReusedConnection)
            fields["requestBodyBytesSent"] = String(transaction.countOfRequestBodyBytesSent)
            fields["responseBodyBytesReceived"] = String(transaction.countOfResponseBodyBytesReceived)
            fields["fetchType"] = Self.fetchType(transaction.resourceFetchType)
            fields["protocol"] = ["h2", "h3", "http/1.1"].contains(transaction.networkProtocolName ?? "")
                ? transaction.networkProtocolName : "unknown"
            if let response = transaction.response as? HTTPURLResponse {
                fields["httpStatus"] = String(response.statusCode)
            }
            recorder.emit("http_transaction_metrics", fields)
        }
    }

    private static func fetchType(_ value: URLSessionTaskMetrics.ResourceFetchType) -> String {
        switch value {
        case .networkLoad: return "network"
        case .serverPush: return "server_push"
        case .localCache: return "cache"
        default: return "unknown"
        }
    }
}
