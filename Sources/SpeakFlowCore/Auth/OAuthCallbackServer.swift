import Foundation
import OSLog
import os

/// Local HTTP server to receive OAuth callback.
///
/// All mutable shared state is protected by a single unfair lock to prevent races
/// between start/stop/accept paths and continuation resume.
public final class OAuthCallbackServer: @unchecked Sendable {
    private enum ClientResult {
        case ignored
        case completed(String?)
    }

    private struct State {
        var socket: Int32 = -1
        var isRunning = false
        var continuationConsumed = true
        var continuation: CheckedContinuation<String?, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private let port: UInt16
    private let expectedState: String

    private let successHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Authentication successful</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
        h1 { color: #10a37f; }
      </style>
    </head>
    <body>
      <h1>✓ Authentication successful</h1>
      <p>You can close this window and return to SpeakFlow.</p>
    </body>
    </html>
    """

    public init(expectedState: String, port: UInt16 = 1455) {
        self.expectedState = expectedState
        self.port = port
    }

    deinit {
        stop()
    }

    // MARK: - Thread-safe continuation management

    /// Resume the callback continuation exactly once.
    private func resumeOnce(returning value: String?) {
        let continuation = state.withLock { state -> CheckedContinuation<String?, Never>? in
            guard !state.continuationConsumed else { return nil }
            state.continuationConsumed = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }

        continuation?.resume(returning: value)
    }

    /// Bind/listen on localhost before the browser is opened so the socket is
    /// ready to accept the OAuth redirect immediately.
    ///
    /// Sequence: `prepareForCallback()` → open browser → `waitForPreparedCallback()`.
    /// This eliminates the startup race where the provider redirects before the
    /// socket is listening. Safe to call multiple times — idempotent.
    @discardableResult
    public func prepareForCallback() -> Bool {
        startIfNeeded()
    }

    /// Wait for OAuth callback after `prepareForCallback()` has already bound the socket.
    ///
    /// Use this in the `prepareForCallback()` → open browser → `waitForPreparedCallback()`
    /// sequence. Returns nil immediately if the server was not pre-started.
    ///
    /// - Parameter timeout: max seconds to wait before returning nil.
    /// - Returns: authorization code, or nil on timeout/cancellation/error.
    public func waitForPreparedCallback(timeout: TimeInterval = 120) async -> String? {
        let running = state.withLock { $0.isRunning }
        guard running else {
            Logger.auth.error("waitForPreparedCallback() called before prepareForCallback()")
            return nil
        }
        return await acceptAndWait(timeout: timeout)
    }

    /// Wait for OAuth callback, binding/listening first if not already running.
    ///
    /// For flows where the server is started and the browser opened in a single
    /// async context, prefer `prepareForCallback()` + `waitForPreparedCallback()`
    /// to avoid the startup race.
    ///
    /// - Parameter timeout: max seconds to wait before returning nil.
    /// - Returns: authorization code, or nil on timeout/cancellation/error.
    public func waitForCallback(timeout: TimeInterval = 120) async -> String? {
        guard startIfNeeded() else {
            Logger.auth.error("Failed to start OAuth callback server")
            return nil
        }
        return await acceptAndWait(timeout: timeout)
    }

    /// Shared wait body used by both public entry points.
    private func acceptAndWait(timeout: TimeInterval) async -> String? {
        defer { stop() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    state.continuation = continuation
                    state.continuationConsumed = false
                }

                Task {
                    await self.acceptConnections(timeout: timeout)
                }
            }
        } onCancel: {
            self.resumeOnce(returning: nil)
            self.stop()
        }
    }

    private func startIfNeeded() -> Bool {
        let alreadyRunning = state.withLock { $0.isRunning }
        if alreadyRunning {
            return true
        }

        let newSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard newSocket >= 0 else {
            Logger.auth.error("Failed to create socket")
            return false
        }

        var reuse: Int32 = 1
        _ = setsockopt(newSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(newSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            Logger.auth.error("Failed to bind to port \(self.port): \(String(cString: strerror(errno)))")
            Darwin.close(newSocket)
            return false
        }

        guard Darwin.listen(newSocket, 1) == 0 else {
            Logger.auth.error("Failed to listen on socket")
            Darwin.close(newSocket)
            return false
        }

        state.withLock { state in
            state.socket = newSocket
            state.isRunning = true
        }

        Logger.auth.info("OAuth callback server started on port \(self.port)")
        return true
    }

    private func acceptConnections(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)

        let currentSocket = state.withLock { $0.socket }
        guard currentSocket >= 0 else {
            resumeOnce(returning: nil)
            return
        }

        guard setNonBlocking(currentSocket) else {
            Logger.auth.error("Failed to set listener socket non-blocking")
            resumeOnce(returning: nil)
            return
        }

        while Date() < deadline {
            if Task.isCancelled {
                resumeOnce(returning: nil)
                return
            }

            let (running, sock) = state.withLock { ($0.isRunning, $0.socket) }
            guard running, sock >= 0 else { break }

            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(sock, sockPtr, &addrLen)
                }
            }

            if clientSocket >= 0 {
                guard setNonBlocking(clientSocket) else {
                    // One bad accepted client must not kill the whole login attempt:
                    // close it and keep listening for the real callback.
                    Logger.auth.error("Failed to set accepted client socket non-blocking")
                    Darwin.close(clientSocket)
                    continue
                }

                let result = handleClient(clientSocket)
                Darwin.close(clientSocket)

                switch result {
                case .ignored:
                    // Not a valid callback (noise, probe, wrong path, bad state, etc.).
                    // Keep accepting until the real redirect arrives or we time out.
                    continue
                case let .completed(code):
                    // A matching-state callback is terminal even when the provider
                    // returns an OAuth error instead of an authorization code.
                    resumeOnce(returning: code)
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Timeout or stopped.
        resumeOnce(returning: nil)
    }

    /// Handles one accepted connection to completion: reads the request, writes the
    /// matching HTTP response, and distinguishes ignorable connection noise from a
    /// terminal matching-state OAuth response. A terminal response can contain either
    /// an authorization code or a provider error represented by `completed(nil)`.
    private func handleClient(_ clientSocket: Int32) -> ClientResult {
        // Robustly read until end-of-headers. A single `read` is not guaranteed to
        // return the full HTTP request line; under load we can receive a partial
        // first packet (e.g. truncated query string), which causes false
        // state-mismatch 400 responses in OAuth tests and real callbacks.
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let headerTerminator = Data("\r\n\r\n".utf8)
        let maxHeaderBytes = 16 * 1024

        let readDeadline = Date().addingTimeInterval(1.0)
        while requestData.count < maxHeaderBytes, Date() < readDeadline {
            let bytesRead = Darwin.read(clientSocket, &buffer, buffer.count)

            if bytesRead > 0 {
                requestData.append(contentsOf: buffer.prefix(bytesRead))
                if requestData.range(of: headerTerminator) != nil {
                    break
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // Non-blocking socket may not have full headers yet.
                usleep(1_000)
                continue
            }

            sendResponse(clientSocket, status: "400 Bad Request", body: "Read error")
            return .ignored
        }

        guard !requestData.isEmpty,
              let request = String(data: requestData, encoding: .utf8),
              let firstLine = request.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Invalid request")
            return .ignored
        }

        let path = String(pathPart)

        guard path.hasPrefix("/auth/callback") else {
            sendResponse(clientSocket, status: "404 Not Found", body: "Not found")
            return .ignored
        }

        guard let queryStart = path.firstIndex(of: "?") else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Missing query parameters")
            return .ignored
        }

        let queryString = String(path[path.index(after: queryStart)...])
        let params = parseQueryString(queryString)

        guard let state = params["state"], state == expectedState else {
            // Info level, no request contents (query/code): this can be a stray
            // probe or an actual CSRF attempt, not a value worth logging either way.
            Logger.auth.info("OAuth callback rejected: state mismatch")
            sendResponse(clientSocket, status: "400 Bad Request", body: "State mismatch")
            return .ignored
        }

        guard let code = params["code"] else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Missing authorization code")
            return .completed(nil)
        }

        sendResponse(clientSocket, status: "200 OK", body: successHTML, contentType: "text/html")
        Logger.auth.info("Received OAuth callback with authorization code")
        return .completed(code)
    }

    private func parseQueryString(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                result[key] = value
            }
        }
        return result
    }

    private func sendResponse(_ socket: Int32, status: String, body: String, contentType: String = "text/plain") {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        _ = response.withCString { ptr in
            Darwin.write(socket, ptr, strlen(ptr))
        }
    }

    private func setNonBlocking(_ socket: Int32) -> Bool {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0
    }

    public func stop() {
        let socket = state.withLock { state -> Int32 in
            state.isRunning = false
            let socket = state.socket
            state.socket = -1
            return socket
        }

        if socket >= 0 {
            Darwin.close(socket)
        }

        resumeOnce(returning: nil)
        Logger.auth.debug("OAuth callback server stopped")
    }
}
