import Foundation

/// Numeric and categorical diagnostics only. Never accept request or response payloads.
enum ProviderTiming {
    enum Provider: String, Sendable {
        case chatgptBatch = "chatgpt-batch"
        case mistralBatch = "mistral-batch"
        case otherBatch = "other-batch"
    }

    enum Phase: String, Sendable {
        case scheduling, configuration, authentication, transport, decode
        case rateLimit = "rate_limit"
        case requestBuild = "request_build"
        case retryDelay = "retry_delay"
        case providerCall = "provider_call"
    }

    struct Correlation: Sendable {
        var requestId = UUID()
        var sessionId: UUID?
    }

    struct Event: Sendable {
        let name: String
        let sessionId: UUID?
        let metadata: [String: String]
    }

    @TaskLocal static var sink: (@Sendable (Event) -> Void)?
    @TaskLocal static var correlation: Correlation?
    @TaskLocal static var activeAttempt: Attempt?

    struct Recorder: Sendable {
        let provider: Provider
        let correlation: Correlation
        let sink: @Sendable (Event) -> Void
        var attempt = 0

        init(provider: Provider, correlation: Correlation? = ProviderTiming.correlation) {
            self.provider = provider
            self.correlation = correlation ?? Correlation()
            sink = ProviderTiming.sink ?? { event in
                Task {
                    await ObservabilityStore.shared.record(
                        component: "ProviderTiming", name: event.name,
                        sessionId: event.sessionId, metadata: event.metadata
                    )
                }
            }
        }

        func emit(_ name: String, _ fields: [String: String] = [:]) {
            var metadata = fields
            metadata["schemaVersion"] = "1"
            metadata["provider"] = provider.rawValue
            metadata["requestId"] = correlation.requestId.uuidString
            metadata["attempt"] = String(attempt)
            sink(Event(name: name, sessionId: correlation.sessionId, metadata: metadata))
        }

        func measure<T: Sendable>(
            _ phase: Phase, operation: @Sendable () async throws -> T
        ) async rethrows -> T {
            let start = ContinuousClock.now
            do {
                let result = try await operation()
                phaseFinished(phase, since: start)
                return result
            } catch {
                phaseFinished(phase, since: start, error: error)
                throw error
            }
        }

        func measureSync<T>(_ phase: Phase, operation: () throws -> T) rethrows -> T {
            let start = ContinuousClock.now
            do {
                let result = try operation()
                phaseFinished(phase, since: start)
                return result
            } catch {
                phaseFinished(phase, since: start, error: error)
                throw error
            }
        }

        func phaseFinished(_ phase: Phase, since start: ContinuousClock.Instant, error: Error? = nil) {
            emit("provider_phase_finished", [
                "phase": phase.rawValue, "elapsedMs": Attempt.milliseconds(since: start),
                "outcome": Attempt.outcome(error: error, status: nil, code: (error as? URLError)?.code.rawValue)
            ])
        }

        func withAttempt<T: Sendable>(
            _ number: Int, operation: @Sendable (Attempt) async throws -> T
        ) async throws -> T {
            var recorder = self
            recorder.attempt = number
            let attempt = Attempt(recorder: recorder)
            recorder.emit("provider_attempt_started")
            do {
                let value = try await ProviderTiming.$activeAttempt.withValue(attempt) {
                    try await operation(attempt)
                }
                attempt.finish(error: nil)
                return value
            } catch {
                attempt.finish(error: error)
                throw error
            }
        }
    }

    final class Attempt: @unchecked Sendable {
        let recorder: Recorder
        private let start = ContinuousClock.now
        private let lock = NSLock()
        private var status: Int?
        private var urlErrorCode: Int?

        init(recorder: Recorder) { self.recorder = recorder }

        func received(_ response: URLResponse) {
            lock.withLock { status = (response as? HTTPURLResponse)?.statusCode }
        }

        func transportFailed(_ error: Error) {
            lock.withLock { urlErrorCode = (error as? URLError)?.code.rawValue }
        }

        func finish(error: Error?) {
            let (status, code) = lock.withLock { (self.status, self.urlErrorCode) }
            var fields = [
                "elapsedMs": Self.milliseconds(since: start),
                "outcome": Self.outcome(error: error, status: status, code: code)
            ]
            if let status { fields["httpStatus"] = String(status) }
            if let code { fields["urlErrorCode"] = String(code) }
            if let error = error as? TranscriptionError { fields["retryable"] = String(error.isRetryable) }
            if let error = error as? MistralBatchError { fields["retryable"] = String(error.isRetryable) }
            recorder.emit("provider_attempt_finished", fields)
        }

        fileprivate static func outcome(error: Error?, status: Int?, code: Int?) -> String {
            guard let error else { return "success" }
            if error is CancellationError || code == URLError.cancelled.rawValue { return "cancelled" }
            if code == URLError.timedOut.rawValue { return "timeout" }
            if let error = error as? TranscriptionError {
                switch error {
                case .cancelled: return "cancelled"
                case .authenticationFailed: return "authentication_error"
                case .rateLimited: return "rate_limited"
                case .invalidResponse, .decodingFailed: return "invalid_response"
                case .networkError(let underlying):
                    return outcome(error: underlying, status: status, code: (underlying as? URLError)?.code.rawValue)
                default: break
                }
            }
            if status == 429 { return "rate_limited" }
            if status == 401 || status == 403 { return "authentication_error" }
            if let status, !(200...299).contains(status) { return "http_error" }
            if case MistralBatchError.invalidResponse = error { return "invalid_response" }
            if error is URLError || code != nil { return "transport_error" }
            if case MistralBatchError.networkError = error { return "transport_error" }
            return "failure"
        }

        static func milliseconds(since start: ContinuousClock.Instant) -> String {
            let duration = start.duration(to: .now)
            return String(format: "%.3f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
    }
}
