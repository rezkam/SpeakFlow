import Foundation
import os

/// Opens a URLSession WebSocket and returns only after the HTTP upgrade succeeds.
enum WebSocketConnector {
    static func connect(
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> WebSocketConnection {
        let handshake = WebSocketOpeningHandshake()
        let session = URLSession(
            configuration: .default,
            delegate: handshake,
            delegateQueue: nil
        )
        let webSocketTask = session.webSocketTask(with: request)

        webSocketTask.resume()

        do {
            try await handshake.waitForOpen(timeout: timeout)
            return WebSocketConnection(
                urlSession: session,
                webSocketTask: webSocketTask
            )
        } catch {
            webSocketTask.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
    }
}

/// Bridges URLSession's WebSocket delegate callbacks into one awaitable handshake.
/// Completion is stored when a callback wins the race before the waiter is installed.
final class WebSocketOpeningHandshake: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct State {
        var result: Result<Void, Error>?
        var continuation: CheckedContinuation<Void, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func waitForOpen(timeout: TimeInterval) async throws {
        guard timeout > 0 else {
            throw WebSocketConnectionError.handshakeTimedOut
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completedResult = state.withLock { state -> Result<Void, Error>? in
                    if let result = state.result {
                        return result
                    }

                    precondition(state.continuation == nil, "WebSocket handshake already has a waiter")
                    state.continuation = continuation
                    state.timeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(timeout))
                        } catch {
                            return
                        }
                        self?.complete(with: .failure(WebSocketConnectionError.handshakeTimedOut))
                    }
                    return nil
                }

                if let completedResult {
                    continuation.resume(with: completedResult)
                }
            }
        } onCancel: {
            self.complete(with: .failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        complete(with: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        complete(with: .failure(Self.handshakeError(error, statusCode: statusCode)))
    }

    private static func handshakeError(_ error: Error?, statusCode: Int?) -> Error {
        if let statusCode, statusCode != 101 {
            return WebSocketConnectionError.handshakeRejected(statusCode: statusCode)
        }
        if let error {
            return WebSocketConnectionError.connectionFailed(error.localizedDescription)
        }
        return WebSocketConnectionError.connectionFailed(
            "WebSocket closed before the handshake completed"
        )
    }

    private func complete(with result: Result<Void, Error>) {
        let pending = state.withLock { state -> (
            CheckedContinuation<Void, Error>?,
            Task<Void, Never>?
        )? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            let timeoutTask = state.timeoutTask
            state.continuation = nil
            state.timeoutTask = nil
            return (continuation, timeoutTask)
        }

        pending?.1?.cancel()
        pending?.0?.resume(with: result)
    }

#if DEBUG
    // swiftlint:disable identifier_name
    func _testDidOpen() {
        complete(with: .success(()))
    }

    func _testDidComplete(error: Error?, statusCode: Int?) {
        complete(with: .failure(Self.handshakeError(error, statusCode: statusCode)))
    }
    // swiftlint:enable identifier_name
#endif
}
