import Foundation
import OSLog

/// Local HTTP server to receive OAuth callback
public final class OAuthCallbackServer: @unchecked Sendable {
    private var server: (any NSObjectProtocol)?
    private var socket: Int32 = -1
    private var isRunning = false
    private var continuation: CheckedContinuation<String?, Never>?
    
    private let port: UInt16 = 1455
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
    
    public init(expectedState: String) {
        self.expectedState = expectedState
    }
    
    deinit {
        stop()
    }
    
    /// Start the server and wait for callback
    /// Returns the authorization code, or nil if cancelled/timeout
    public func waitForCallback(timeout: TimeInterval = 120) async -> String? {
        guard start() else {
            Logger.auth.error("Failed to start OAuth callback server")
            return nil
        }
        
        defer { stop() }
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                
                // Start listening in background
                Task {
                    await self.acceptConnections(timeout: timeout)
                }
            }
        } onCancel: {
            self.stop()
        }
    }
    
    private func start() -> Bool {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            Logger.auth.error("Failed to create socket")
            return false
        }
        
        // Allow port reuse
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind to localhost:1455
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            Logger.auth.error("Failed to bind to port \(self.port): \(String(cString: strerror(errno)))")
            Darwin.close(socket)
            socket = -1
            return false
        }
        
        guard Darwin.listen(socket, 1) == 0 else {
            Logger.auth.error("Failed to listen on socket")
            Darwin.close(socket)
            socket = -1
            return false
        }
        
        isRunning = true
        Logger.auth.info("OAuth callback server started on port \(self.port)")
        return true
    }
    
    private func acceptConnections(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        
        // Set socket to non-blocking
        let flags = fcntl(socket, F_GETFL, 0)
        fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        
        while isRunning && Date() < deadline {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(socket, sockPtr, &addrLen)
                }
            }
            
            if clientSocket >= 0 {
                handleClient(clientSocket)
                Darwin.close(clientSocket)
                return
            }
            
            // No connection yet, wait a bit
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        // Timeout or stopped
        continuation?.resume(returning: nil)
        continuation = nil
    }
    
    private func handleClient(_ clientSocket: Int32) {
        // Read request
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(clientSocket, &buffer, buffer.count)
        
        guard bytesRead > 0 else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "No data received")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        let request = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        
        // Parse the request line
        guard let firstLine = request.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Invalid request")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        let path = String(pathPart)
        
        // Only handle /auth/callback
        guard path.hasPrefix("/auth/callback") else {
            sendResponse(clientSocket, status: "404 Not Found", body: "Not found")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        // Parse query parameters
        guard let queryStart = path.firstIndex(of: "?") else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Missing query parameters")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        let queryString = String(path[path.index(after: queryStart)...])
        let params = parseQueryString(queryString)
        
        // Verify state
        guard let state = params["state"], state == expectedState else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "State mismatch")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        // Get code
        guard let code = params["code"] else {
            sendResponse(clientSocket, status: "400 Bad Request", body: "Missing authorization code")
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        
        // Success!
        sendResponse(clientSocket, status: "200 OK", body: successHTML, contentType: "text/html")
        
        Logger.auth.info("Received OAuth callback with authorization code")
        continuation?.resume(returning: code)
        continuation = nil
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
        isRunning = false
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
        Logger.auth.debug("OAuth callback server stopped")
    }
}
