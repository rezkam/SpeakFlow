import Foundation
import OSLog
import os

/// Local HTTP server to receive OAuth callback.
///
/// All mutable shared state is protected by a single unfair lock to prevent races
/// between start/stop/accept paths and continuation resume.
public final class OAuthCallbackServer: @unchecked Sendable {
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

    /// Start the server and wait for callback.
    /// Returns authorization code, or nil on timeout/cancellation/error.
    public func waitForCallback(timeout: TimeInterval = 120) async -> String? {
        guard start() else {
            Logger.auth.error("Failed to start OAuth callback server")
            return nil
        }

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

    private func start() -> Bool {
        let alreadyRunning = state.withLock { $0.isRunning }
        guard !alreadyRunning else {
            Logger.auth.warning("OAuth callback server already running")
            return false
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

        let flags = fcntl(currentSocket, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(currentSocket, F_SETFL, flags | O_NONBLOCK)
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
                handleClient(clientSocket)
                Darwin.close(clientSocket)
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Timeout or stopped.
        resumeOnce(returning: nil)
    }

    private func handleClient(_ clientSocket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(clientSocket, &buffer, buffer.count)

        guard bytesRead > 0 else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "No data received")
            resumeOnce(returning: nil)
            return
        }

        let request = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""

        guard let firstLine = request.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Invalid request")
            resumeOnce(returning: nil)
            return
        }

        let path = String(pathPart)

        guard path.hasPrefix("/auth/callback") else {
            sendResponse(clientSocket, status: "404 Not Found", body: "Not found")
            resumeOnce(returning: nil)
            return
        }

        guard let queryStart = path.firstIndex(of: "?") else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Missing query parameters")
            resumeOnce(returning: nil)
            return
        }

        let queryString = String(path[path.index(after: queryStart)...])
        let params = parseQueryString(queryString)

        guard let state = params["state"], state == expectedState else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "State mismatch")
            resumeOnce(returning: nil)
            return
        }

        guard let code = params["code"] else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Missing authorization code")
            resumeOnce(returning: nil)
            return
        }

        sendResponse(clientSocket, status: "200 OK", body: successHTML, contentType: "text/html")
        Logger.auth.info("Received OAuth callback with authorization code")
        resumeOnce(returning: code)
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
