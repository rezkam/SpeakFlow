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
    public let buildGitDescribe: String
    public let buildGitCommit: String
    public let buildDisplayVersion: String
    public let component: String
    public let name: String
    public let level: ObservabilityEventLevel
    public let sessionId: UUID?
    public let metadata: [String: String]
}

private struct ObservabilityBuildMetadata: Sendable {
    let gitDescribe: String
    let gitCommit: String
    let displayVersion: String

    static let current = ObservabilityBuildMetadata()

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let environment = ProcessInfo.processInfo.environment
        gitDescribe = Self.nonEmpty(
            info["SpeakFlowBuildGitDescribe"] as? String,
            environment["SPEAKFLOW_BUILD_GIT_DESCRIBE"],
            "unknown"
        )
        gitCommit = Self.nonEmpty(
            info["SpeakFlowBuildGitCommit"] as? String,
            environment["SPEAKFLOW_BUILD_GIT_COMMIT"],
            "unknown"
        )
        displayVersion = Self.nonEmpty(
            info["SpeakFlowDisplayVersion"] as? String,
            info["CFBundleShortVersionString"] as? String,
            environment["SPEAKFLOW_DISPLAY_VERSION"],
            "unknown"
        )
    }

    private static func nonEmpty(_ candidates: String?...) -> String {
        for candidate in candidates {
            if let value = candidate, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return "unknown"
    }
}

public struct ObservabilityPathInfo: Sendable {
    public let baseDirectory: URL
    public let eventsFile: URL
}

/// Explicit context for isolated diagnostic stores, without inspecting the host.
public struct ObservabilityRuntimeContext: Sendable {
    public let profile: String
    public let processId: Int32
    public let processName: String
    public let systemContext: [String: String]

    public init(profile: String, processId: Int32, processName: String, systemContext: [String: String]) {
        self.profile = profile
        self.processId = processId
        self.processName = processName
        self.systemContext = systemContext
    }
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
            RuntimeIsolation.current.isIsolated
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

    private let runtimeContext: ObservabilityRuntimeContext?
    private let pathInfo: ObservabilityPathInfo
    private let maxFileBytes: UInt64
    private let maxRotatedFiles: Int
    private var config = Configuration()
    private var sequence: UInt64 = 0
    private var sessionSequences: [UUID: UInt64] = [:]
    private var handle: FileHandle?
    private var didRecordSystemContext = false

    public init(
        baseDirectory: URL? = nil,
        maxFileBytes: UInt64 = Config.observabilityMaxLogBytes,
        maxRotatedFiles: Int = Config.observabilityMaxRotatedLogFiles,
        runtimeContext: ObservabilityRuntimeContext? = nil
    ) {
        self.runtimeContext = runtimeContext
        let base = baseDirectory ?? RuntimePaths.defaultBaseDirectory
        self.pathInfo = ObservabilityPathInfo(
            baseDirectory: base,
            eventsFile: base.appendingPathComponent(Self.eventsFileName)
        )
        self.maxFileBytes = maxFileBytes
        self.maxRotatedFiles = max(0, maxRotatedFiles)
        self.handle = Self.prepareStorage(pathInfo: self.pathInfo, maxRotatedFiles: self.maxRotatedFiles)
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

    /// Whether events are currently written.
    public func isEnabled() -> Bool {
        config.enabled
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
            profile: runtimeContext?.profile ?? RuntimePaths.profileName,
            processId: runtimeContext?.processId ?? ProcessInfo.processInfo.processIdentifier,
            processName: runtimeContext?.processName ?? ProcessInfo.processInfo.processName,
            buildGitDescribe: ObservabilityBuildMetadata.current.gitDescribe,
            buildGitCommit: ObservabilityBuildMetadata.current.gitCommit,
            buildDisplayVersion: ObservabilityBuildMetadata.current.displayVersion,
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

    /// Owner-only POSIX permission bits enforced on every persisted observability artifact.
    /// Dictated text (with captureTextPayloads enabled) is keystroke-equivalent content
    /// and must never be readable by other local accounts.
    private static let privateFileMode = 0o600
    private static let privateDirectoryMode = 0o700

    /// Ensures the directory at `url` exists and is owner-only (0700), tightening it if it
    /// already existed with looser permissions (e.g. created by a prior app version).
    private static func ensurePrivateDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: privateDirectoryMode]
            )
        } else {
            try fileManager.setAttributes([.posixPermissions: privateDirectoryMode], ofItemAtPath: url.path)
        }
    }

    /// Ensures the file at `path` exists and is owner-only (0600), tightening it if it
    /// already existed with looser permissions (e.g. created by a prior app version).
    private static func ensurePrivateFile(atPath path: String) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: privateFileMode]
            guard fileManager.createFile(atPath: path, contents: nil, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            try fileManager.setAttributes([.posixPermissions: privateFileMode], ofItemAtPath: path)
        }
    }

    private static func rotatedEventsFile(pathInfo: ObservabilityPathInfo, index: Int) -> URL {
        pathInfo.eventsFile.deletingLastPathComponent()
            .appendingPathComponent("\(pathInfo.eventsFile.lastPathComponent).\(index)")
    }

    private static func prepareStorage(pathInfo: ObservabilityPathInfo, maxRotatedFiles: Int) -> FileHandle? {
        do {
            try ensurePrivateDirectory(at: pathInfo.baseDirectory)
            try ensurePrivateFile(atPath: pathInfo.eventsFile.path)
            if maxRotatedFiles > 0 {
                for index in 1...maxRotatedFiles {
                    let rotated = rotatedEventsFile(pathInfo: pathInfo, index: index)
                    if FileManager.default.fileExists(atPath: rotated.path) {
                        try ensurePrivateFile(atPath: rotated.path)
                    }
                }
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
        let context: [String: String] = runtimeContext?.systemContext ?? [
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

    #if DEBUG
    /// Exercise a real kernel write failure without changing the user's disk.
    func useReadOnlyEventsHandleForTesting() throws {
        try handle?.close()
        handle = try FileHandle(forReadingFrom: pathInfo.eventsFile)
    }
    #endif

    private func append(_ event: ObservabilityEvent) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                try container.encode(formatter.string(from: date))
            }
            var data = try encoder.encode(event)
            data.append(0x0A)
            try rotateIfNeeded(additionalBytes: UInt64(data.count))
            guard let handle else { return }
            try handle.write(contentsOf: data)
        } catch {
            // Best-effort diagnostics: observability must never crash product flows.
        }
    }

    private func rotateIfNeeded(additionalBytes: UInt64) throws {
        guard maxFileBytes > 0 else { return }
        let currentSize = try currentEventsFileSize()
        guard currentSize + additionalBytes > maxFileBytes else { return }

        try handle?.close()
        handle = nil

        let fileManager = FileManager.default
        if maxRotatedFiles == 0 {
            try? fileManager.removeItem(at: pathInfo.eventsFile)
        } else {
            let oldest = rotatedEventsFile(index: maxRotatedFiles)
            try? fileManager.removeItem(at: oldest)

            if maxRotatedFiles > 1 {
                for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
                    let source = rotatedEventsFile(index: index)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = rotatedEventsFile(index: index + 1)
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: source, to: destination)
                }
            }

            if fileManager.fileExists(atPath: pathInfo.eventsFile.path) {
                try fileManager.moveItem(at: pathInfo.eventsFile, to: rotatedEventsFile(index: 1))
            }
        }

        try Self.ensurePrivateFile(atPath: pathInfo.eventsFile.path)
        handle = try FileHandle(forWritingTo: pathInfo.eventsFile)
        try handle?.seekToEnd()
    }

    private func currentEventsFileSize() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: pathInfo.eventsFile.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func rotatedEventsFile(index: Int) -> URL {
        Self.rotatedEventsFile(pathInfo: pathInfo, index: index)
    }
}
