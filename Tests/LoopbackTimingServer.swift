import Foundation
import Network

/// A loopback-only fixture. It never captures or logs incoming request bytes.
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
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
}
