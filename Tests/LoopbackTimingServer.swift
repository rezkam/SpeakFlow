import Foundation
import Network

/// A loopback-only fixture. Request bytes stay in bounded memory and are never logged.
final class LoopbackTimingServer: @unchecked Sendable {
    private let listener: NWListener

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "fixture-http")
        let body = Data("fixture response".utf8)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        let reply = response
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveRequest(on: connection, queue: queue, progress: LoopbackRequestProgress(), reply: reply)
        }
        let readiness = AsyncThrowingStream<Void, Error> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(()); continuation.finish()
                case .failed(let error): continuation.finish(throwing: error)
                case .cancelled: continuation.finish(throwing: CancellationError())
                default: break
                }
            }
        }
        listener.start(queue: queue)
        for try await _ in readiness { break }
    }

    func request() -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(listener.port!.rawValue)
        components.path = "/fixture"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 0, count: 128)
        return request
    }

    func cancel() { listener.cancel() }
    deinit { listener.cancel() }

    private static func receiveRequest(on connection: NWConnection, queue: DispatchQueue,
                                       progress: LoopbackRequestProgress, reply: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            guard let data, error == nil else { connection.cancel(); return }
            var next = progress
            if next.receive(data) {
                // Keep the response milestone distinct from upload completion on loopback.
                queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if isComplete || next.isOversized {
                connection.cancel()
            } else {
                receiveRequest(on: connection, queue: queue, progress: next, reply: reply)
            }
        }
    }
}

/// Handles the fixed-length HTTP requests sent by this fixture's URLSession client.
struct LoopbackRequestProgress: Sendable {
    private var bytes = Data()
    var isOversized: Bool { bytes.count > 65536 }

    mutating func receive(_ chunk: Data) -> Bool {
        bytes.append(chunk)
        guard !isOversized, let separator = bytes.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else { return false }
        let lengthLine = header.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("content-length:")
        }
        guard let lengthLine, let length = Int(lengthLine.dropFirst("content-length:".count)
            .trimmingCharacters(in: .whitespaces)), length >= 0 else { return false }
        return bytes.count - separator.upperBound >= length
    }
}
