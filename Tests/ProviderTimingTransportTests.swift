import Foundation
import Network
import os
import Testing
@testable import SpeakFlowCore

private final class TimingFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Suite("Provider timing transport")
struct ProviderTimingTransportTests {
    @Test func loopbackFixtureWaitsForTheEntireUpload() {
        var request = LoopbackRequestProgress()
        let completed = ["POST /fixture HTTP/1.1\r\nContent-Len", "gth: 4\r\n\r\na", "bc", "d"]
            .map { request.receive(Data($0.utf8)) }
        #expect(completed == [false, false, false, true])
    }

    @Test func loopbackFixtureWaitsForCompleteUploadBeforeReplying() async throws {
        let server = try await LoopbackTimingServer()
        defer { server.cancel() }
        let portNumber = try #require(server.request().url?.port)
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(portNumber)))
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        defer { connection.cancel() }
        let received = OSAllocatedUnfairLock(initialState: false)
        connection.start(queue: DispatchQueue(label: "fixture-http-client"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            if let data, !data.isEmpty { received.withLock { $0 = true } }
        }
        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
        // Split the body across writes, as a real upload can arrive in multiple reads.
        try await send(Data("POST /fixture HTTP/1.1\r\nHost: fixture.invalid\r\nContent-Length: 4\r\n\r\na".utf8))
        try await Task.sleep(for: .milliseconds(100))
        try #require(!received.withLock { $0 }, "The fixture must not respond to a partial upload")
        try await send(Data("bcd".utf8))
        let deadline = ContinuousClock.now + .seconds(3)
        while !received.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.withLock { $0 }, "The fixture must reply after the complete upload")
    }

    @Test func nativeLoopbackRequestCollectsActualNetworkMilestones() async throws {
        let server = try await LoopbackTimingServer()
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let events = TimingEvents()
        let data = try await ProviderTiming.$sink.withValue({ events.append($0) }) {
            let transport = TimedHTTPDataProvider(session: session, provider: .chatgptBatch)
            return try await transport.data(for: server.request()).0
        }
        #expect(data == Data("fixture response".utf8))
        let summary = try #require(events.values.first { $0.name == "http_task_metrics" })
        #expect(summary.metadata["metricsAvailable"] == "true")
        #expect(events.values.filter { $0.name == "http_task_metrics" }.count == 1)
        let transaction = try #require(events.values.first { $0.name == "http_transaction_metrics" })
        for key in ["uploadMs", "responseWaitMs", "downloadMs", "timeToFirstByteMs"] {
            #expect(Double(transaction.metadata[key] ?? "") != nil, "Native URLSession must supply \(key)")
        }
        #expect(transaction.metadata["httpStatus"] == "200")
        #expect(transaction.metadata["fetchType"] == "network")
        #expect(transaction.metadata["requestBodyBytesSent"] == "128")
        #expect(!String(describing: transaction.metadata).contains("localhost"))
    }

    @Test func realURLSessionReportsMetricsAvailabilityAndKeepsCorrelation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = TimedHTTPDataProvider(session: session, provider: .chatgptBatch)
        let events = TimingEvents()
        let correlation = ProviderTiming.Correlation(sessionId: UUID())
        let (data, _) = try await ProviderTiming.$sink.withValue({ events.append($0) }) {
            try await ProviderTiming.$correlation.withValue(correlation) {
                try await transport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/upload")!))
            }
        }
        #expect(data == Data("fixture response".utf8))
        let summary = try #require(events.values.first { $0.name == "http_task_metrics" })
        #expect(summary.metadata["requestId"] == correlation.requestId.uuidString)
        #expect(summary.sessionId == correlation.sessionId)
        #expect(Int(summary.metadata["transactionCount"] ?? "") != nil)
        #expect(summary.metadata["metricsAvailable"] != nil)
        #expect(Double(summary.metadata["elapsedMs"] ?? "") != nil)
        #expect(!String(describing: events.values.map(\.metadata)).contains("fixture.invalid"))
        #expect(!String(describing: events.values.map(\.metadata)).contains("fixture response"))
    }
}
