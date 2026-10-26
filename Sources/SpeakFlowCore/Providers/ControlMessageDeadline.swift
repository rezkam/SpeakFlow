import Foundation

private enum ControlMessageDeadlineError: LocalizedError {
    case timedOut
    var errorDescription: String? { "Graceful control message timed out" }
}

/// Do not join an operation that ignores cancellation. On timeout the caller must
/// still close the underlying transport, which releases any suspended socket send.
func withControlMessageDeadline(
    timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    guard timeout.isFinite, timeout > 0 else { throw ControlMessageDeadlineError.timedOut }
    let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let operationTask = Task {
        do {
            try await operation()
            continuation.yield(())
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    let timeoutTask = Task {
        do { try await Task.sleep(for: .seconds(timeout)) }
        catch { return }
        continuation.finish(throwing: ControlMessageDeadlineError.timedOut)
    }
    try await withTaskCancellationHandler {
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        try Task.checkCancellation()
    } onCancel: {
        continuation.finish(throwing: CancellationError())
    }
}
