import CryptoKit
import Foundation

public enum ObservabilityEventLevel: String, Codable, Sendable {
    case error
    case warning
    case info
    case debug
}

public enum ObservabilityVerbosity: String, CaseIterable, Codable, Sendable {
    case minimal
    case standard
    case verbose

    public func includes(_ level: ObservabilityEventLevel) -> Bool {
        switch (self, level) {
        case (_, .error), (_, .warning):
            return true
        case (.minimal, .info), (.minimal, .debug):
            return false
        case (.standard, .info):
            return true
        case (.standard, .debug):
            return false
        case (.verbose, _):
            return true
        }
    }
}

public enum ObservabilityFingerprint {
    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ObservabilityEvent: Codable, Sendable {
    public let sequence: UInt64
    public let sessionSequence: UInt64?
    public let timestamp: Date
    public let profile: String
    public let processId: Int32
    public let processName: String
    public let component: String
    public let name: String
    public let level: ObservabilityEventLevel
    public let sessionId: UUID?
    public let metadata: [String: String]
}

public struct ObservabilityPathInfo: Sendable {
    public let baseDirectory: URL
    public let eventsFile: URL
}

public actor ObservabilityStore {
    public static let shared = ObservabilityStore()

    private struct Configuration: Sendable {
        var enabled: Bool = true
        var verbosity: ObservabilityVerbosity = .standard
        var captureSettingsSnapshot: Bool = true
        var captureSystemContext: Bool = true
        var captureTextPayloads: Bool = false
    }

    private static let eventsFileName = "events.jsonl"

    public nonisolated static var defaultPathInfo: ObservabilityPathInfo {
        let base = RuntimePaths.defaultBaseDirectory
        return ObservabilityPathInfo(
            baseDirectory: base,
            eventsFile: base.appendingPathComponent(eventsFileName)
        )
    }

    private enum RuntimePaths {
        static func isTestRun() -> Bool {
            Bundle.main.bundlePath.contains(".xctest")
                || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
                || ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
        }

        static var profileName: String {
            if let explicit = ProcessInfo.processInfo.environment["SPEAKFLOW_OBSERVABILITY_PROFILE"],
               !explicit.isEmpty {
                return explicit
            }
            return isTestRun() ? "test-\(ProcessInfo.processInfo.processIdentifier)" : "app"
        }

        static var defaultBaseDirectory: URL {
            if let explicitDir = ProcessInfo.processInfo.environment["SPEAKFLOW_OBSERVABILITY_DIR"],
               !explicitDir.isEmpty {
                return URL(fileURLWithPath: explicitDir, isDirectory: true)
            }
            if isTestRun() {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("speakflow-observability")
                    .appendingPathComponent(profileName)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".speakflow")
                .appendingPathComponent("observability")
                .appendingPathComponent(profileName)
        }
    }

    private let pathInfo: ObservabilityPathInfo
    private var config = Configuration()
    private var sequence: UInt64 = 0
    private var sessionSequences: [UUID: UInt64] = [:]
    private var handle: FileHandle?
    private var didRecordSystemContext = false

    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? RuntimePaths.defaultBaseDirectory
        self.pathInfo = ObservabilityPathInfo(
            baseDirectory: base,
            eventsFile: base.appendingPathComponent(Self.eventsFileName)
        )
        self.handle = Self.prepareStorage(pathInfo: self.pathInfo)
    }

    deinit {
        try? handle?.close()
    }

    public func pathInfoValue() -> ObservabilityPathInfo { pathInfo }

    public func applyConfiguration(
        enabled: Bool,
        verbosity: ObservabilityVerbosity,
        captureSettingsSnapshot: Bool,
        captureSystemContext: Bool,
        captureTextPayloads: Bool
    ) {
        let previousEnabled = config.enabled
        config.enabled = enabled
        config.verbosity = verbosity
        config.captureSettingsSnapshot = captureSettingsSnapshot
        config.captureSystemContext = captureSystemContext
        config.captureTextPayloads = captureTextPayloads

        guard enabled else { return }
        if !previousEnabled {
            didRecordSystemContext = false
        }
        record(
            component: "Observability",
            name: "config_applied",
            level: .info,
            metadata: [
                "enabled": enabled ? "true" : "false",
                "verbosity": verbosity.rawValue,
                "captureSettingsSnapshot": captureSettingsSnapshot ? "true" : "false",
                "captureSystemContext": captureSystemContext ? "true" : "false",
                "captureTextPayloads": captureTextPayloads ? "true" : "false"
            ]
        )
    }

    public func captureTextPayloadsEnabled() -> Bool {
        config.enabled && config.captureTextPayloads
    }

    public func record(
        component: String,
        name: String,
        level: ObservabilityEventLevel = .info,
        sessionId: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        guard config.enabled, config.verbosity.includes(level) else { return }
        ensureSystemContextRecorded(sessionId: sessionId)
        sequence &+= 1
        let sessionSequence: UInt64?
        if let sessionId {
            let next = (sessionSequences[sessionId] ?? 0) &+ 1
            sessionSequences[sessionId] = next
            sessionSequence = next
        } else {
            sessionSequence = nil
        }
        let event = ObservabilityEvent(
            sequence: sequence,
            sessionSequence: sessionSequence,
            timestamp: Date(),
            profile: RuntimePaths.profileName,
            processId: ProcessInfo.processInfo.processIdentifier,
            processName: ProcessInfo.processInfo.processName,
            component: component,
            name: name,
            level: level,
            sessionId: sessionId,
            metadata: metadata
        )
        append(event)
    }

    public func recordSettingsSnapshot(sessionId: UUID?, settings: [String: String]) {
        guard config.enabled, config.captureSettingsSnapshot else { return }
        record(
            component: "Settings",
            name: "settings_snapshot",
            level: .info,
            sessionId: sessionId,
            metadata: settings
        )
    }

    private static func prepareStorage(pathInfo: ObservabilityPathInfo) -> FileHandle? {
        do {
            try FileManager.default.createDirectory(
                at: pathInfo.baseDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: pathInfo.eventsFile.path) {
                FileManager.default.createFile(atPath: pathInfo.eventsFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: pathInfo.eventsFile)
            try handle.seekToEnd()
            return handle
        } catch {
            return nil
        }
    }

    private func ensureSystemContextRecorded(sessionId: UUID?) {
        guard config.captureSystemContext, !didRecordSystemContext else { return }
        didRecordSystemContext = true
        let env = ProcessInfo.processInfo.environment
        let context: [String: String] = [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundlePath": Bundle.main.bundlePath,
            "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
            "isTestRun": RuntimePaths.isTestRun() ? "true" : "false",
            "profile": RuntimePaths.profileName,
            "cwd": FileManager.default.currentDirectoryPath,
            "uiTestMode": env["SPEAKFLOW_UI_TEST_MODE"] ?? "0"
        ]
        record(
            component: "Runtime",
            name: "system_context",
            level: .info,
            sessionId: sessionId,
            metadata: context
        )
    }

    private func append(_ event: ObservabilityEvent) {
        guard let handle else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(event)
            handle.write(data)
            handle.write(Data([0x0A])) // newline
        } catch {
            // Best-effort diagnostics: observability must never crash product flows.
        }
    }
}
