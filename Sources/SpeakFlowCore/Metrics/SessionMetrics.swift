import Foundation

/// Per-session observability payload for dictation runs.
public struct SessionMetrics: Codable, Sendable {
    public let sessionId: UUID
    public let providerId: String
    public let mode: ProviderMode
    public let startTime: Date
    public var endTime: Date?
    public var endReason: String?

    // Content / output
    public var wordsProduced: Int

    // Streaming reliability
    public var keepAlivesSent: Int
    public var reconnections: Int

    // Batch/streaming chunk lifecycle
    public var chunksSubmitted: Int
    public var chunksSucceeded: Int
    public var chunksFailed: Int

    // STT timing
    public var sttLatenciesMs: [Double]

    public init(
        sessionId: UUID,
        providerId: String,
        mode: ProviderMode,
        startTime: Date = Date(),
        endTime: Date? = nil,
        endReason: String? = nil,
        wordsProduced: Int = 0,
        keepAlivesSent: Int = 0,
        reconnections: Int = 0,
        chunksSubmitted: Int = 0,
        chunksSucceeded: Int = 0,
        chunksFailed: Int = 0,
        sttLatenciesMs: [Double] = []
    ) {
        self.sessionId = sessionId
        self.providerId = providerId
        self.mode = mode
        self.startTime = startTime
        self.endTime = endTime
        self.endReason = endReason
        self.wordsProduced = wordsProduced
        self.keepAlivesSent = keepAlivesSent
        self.reconnections = reconnections
        self.chunksSubmitted = chunksSubmitted
        self.chunksSucceeded = chunksSucceeded
        self.chunksFailed = chunksFailed
        self.sttLatenciesMs = sttLatenciesMs
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case providerId
        case mode
        case startTime
        case endTime
        case endReason
        case wordsProduced
        case keepAlivesSent
        case reconnections
        case chunksSubmitted
        case chunksSucceeded
        case chunksFailed
        case sttLatenciesMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        providerId = try container.decode(String.self, forKey: .providerId)
        let modeRaw = try container.decode(String.self, forKey: .mode)
        mode = ProviderMode(rawValue: modeRaw) ?? .batch
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        endReason = try container.decodeIfPresent(String.self, forKey: .endReason)
        wordsProduced = try container.decodeIfPresent(Int.self, forKey: .wordsProduced) ?? 0
        keepAlivesSent = try container.decodeIfPresent(Int.self, forKey: .keepAlivesSent) ?? 0
        reconnections = try container.decodeIfPresent(Int.self, forKey: .reconnections) ?? 0
        chunksSubmitted = try container.decodeIfPresent(Int.self, forKey: .chunksSubmitted) ?? 0
        chunksSucceeded = try container.decodeIfPresent(Int.self, forKey: .chunksSucceeded) ?? 0
        chunksFailed = try container.decodeIfPresent(Int.self, forKey: .chunksFailed) ?? 0
        sttLatenciesMs = try container.decodeIfPresent([Double].self, forKey: .sttLatenciesMs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(providerId, forKey: .providerId)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(endReason, forKey: .endReason)
        try container.encode(wordsProduced, forKey: .wordsProduced)
        try container.encode(keepAlivesSent, forKey: .keepAlivesSent)
        try container.encode(reconnections, forKey: .reconnections)
        try container.encode(chunksSubmitted, forKey: .chunksSubmitted)
        try container.encode(chunksSucceeded, forKey: .chunksSucceeded)
        try container.encode(chunksFailed, forKey: .chunksFailed)
        try container.encode(sttLatenciesMs, forKey: .sttLatenciesMs)
    }
}

public extension SessionMetrics {
    var totalDurationSeconds: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    var avgSTTLatencyMs: Double {
        guard !sttLatenciesMs.isEmpty else { return 0 }
        return sttLatenciesMs.reduce(0, +) / Double(sttLatenciesMs.count)
    }

    var p95STTLatencyMs: Double {
        guard !sttLatenciesMs.isEmpty else { return 0 }
        let sorted = sttLatenciesMs.sorted()
        let index = Int(Double(sorted.count - 1) * 0.95)
        return sorted[index]
    }
}

/// Stores active and recent session metrics for diagnostics/regression analysis.
public actor SessionMetricsStore {
    public static let shared = SessionMetricsStore()

    private struct Persisted: Codable {
        var completed: [SessionMetrics]
    }

    private static let maxCompletedSessions = 200
    private static let maxSTTLatencySamplesPerSession = 200

    private var activeSessions: [UUID: SessionMetrics] = [:]
    private var completedSessions: [SessionMetrics] = []

    private let storageURL: URL

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        completedSessions = Self.load(from: self.storageURL)
    }

    /// Start tracking a session and return the canonical session ID.
    @discardableResult
    public func startSession(sessionId: UUID = UUID(), providerId: String, mode: ProviderMode) -> UUID {
        if activeSessions[sessionId] == nil {
            activeSessions[sessionId] = SessionMetrics(
                sessionId: sessionId,
                providerId: providerId,
                mode: mode
            )
        }
        return sessionId
    }

    public func addWords(sessionId: UUID, count: Int) {
        guard count > 0, var metrics = activeSessions[sessionId] else { return }
        metrics.wordsProduced += count
        activeSessions[sessionId] = metrics
    }

    public func incrementKeepAlive(sessionId: UUID) {
        guard var metrics = activeSessions[sessionId] else { return }
        metrics.keepAlivesSent += 1
        activeSessions[sessionId] = metrics
    }

    public func incrementReconnection(sessionId: UUID) {
        guard var metrics = activeSessions[sessionId] else { return }
        metrics.reconnections += 1
        activeSessions[sessionId] = metrics
    }

    public func incrementChunkSubmitted(sessionId: UUID) {
        guard var metrics = activeSessions[sessionId] else { return }
        metrics.chunksSubmitted += 1
        activeSessions[sessionId] = metrics
    }

    public func incrementChunkSucceeded(sessionId: UUID) {
        guard var metrics = activeSessions[sessionId] else { return }
        metrics.chunksSucceeded += 1
        activeSessions[sessionId] = metrics
    }

    public func incrementChunkFailed(sessionId: UUID) {
        guard var metrics = activeSessions[sessionId] else { return }
        metrics.chunksFailed += 1
        activeSessions[sessionId] = metrics
    }

    public func recordSTTLatency(sessionId: UUID, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0,
              var metrics = activeSessions[sessionId] else { return }

        if metrics.sttLatenciesMs.count >= Self.maxSTTLatencySamplesPerSession {
            metrics.sttLatenciesMs.removeFirst()
        }
        metrics.sttLatenciesMs.append(milliseconds)
        activeSessions[sessionId] = metrics
    }

    public func endSession(sessionId: UUID, reason: String) {
        guard var metrics = activeSessions.removeValue(forKey: sessionId) else { return }
        metrics.endTime = Date()
        metrics.endReason = reason
        completedSessions.append(metrics)
        if completedSessions.count > Self.maxCompletedSessions {
            completedSessions.removeFirst(completedSessions.count - Self.maxCompletedSessions)
        }
        save()
    }

    public func activeSession(id: UUID) -> SessionMetrics? {
        activeSessions[id]
    }

    public func recentCompletedSessions(limit: Int = 20) -> [SessionMetrics] {
        guard limit > 0 else { return [] }
        return Array(completedSessions.suffix(limit))
    }

    /// Returns recent completed sessions whose `startTime` is at or after the
    /// supplied cutoff. Used by the dashboard's "recent sessions" fallback to
    /// hide sessions that pre-date the last `Statistics.reset()` so a reset
    /// truly zeros out user-visible breakdowns.
    public func recentCompletedSessions(after cutoff: Date, limit: Int = 20) -> [SessionMetrics] {
        guard limit > 0 else { return [] }
        let filtered = completedSessions.filter { $0.startTime >= cutoff }
        return Array(filtered.suffix(limit))
    }

    private static var defaultStorageURL: URL {
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })

        let base: URL
        if isTestRun {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("speakflow-test-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".speakflow")
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("session_metrics.json")
    }

    private static func load(from url: URL) -> [SessionMetrics] {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: raw) else { return [] }
        return decoded.completed
    }

    private func save() {
        let payload = Persisted(completed: completedSessions)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
