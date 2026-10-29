import Foundation
import Network

/// A loopback-only fixture. It never persists or logs incoming request bytes.
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
            Self.receiveUpload(connection, queue: queue, reply: reply)
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

    private static func receiveUpload(_ connection: NWConnection, queue: DispatchQueue,
                                      reply: Data, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard error == nil else { connection.cancel(); return }
            var bytes = accumulated
            bytes.append(data ?? Data())
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                let lengthHeader = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                let value = lengthHeader?.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? "0"
                guard let length = Int(value), length >= 0 else { connection.cancel(); return }
                if bytes.count - boundary.upperBound >= length {
                    // Keep the response milestone distinct from upload completion on loopback.
                    queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
            }
            guard !complete else { connection.cancel(); return }
            receiveUpload(connection, queue: queue, reply: reply, accumulated: bytes)
        }
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
}
