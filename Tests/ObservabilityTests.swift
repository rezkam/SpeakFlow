import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Observability")
struct ObservabilityTests {
    @Test func writesStructuredEventsToJSONL() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(baseDirectory: base)

        await store.applyConfiguration(
            enabled: true,
            verbosity: .verbose,
            captureSettingsSnapshot: true,
            captureSystemContext: false,
            captureTextPayloads: true
        )
        await store.record(
            component: "Test",
            name: "event_written",
            level: .info,
            metadata: ["key": "value"]
        )

        let events = try await loadEvents(from: store)
        #expect(events.contains { $0.component == "Test" && $0.name == "event_written" })
        #expect(events.contains { $0.metadata["key"] == "value" })
        #expect(events.allSatisfy { !$0.buildGitDescribe.isEmpty })
        #expect(events.allSatisfy { !$0.buildGitCommit.isEmpty })
        #expect(events.allSatisfy { !$0.buildDisplayVersion.isEmpty })
        #expect(await store.captureTextPayloadsEnabled() == true)
    }

    @Test func timestampsIncludeMilliseconds() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(baseDirectory: base)

        await store.applyConfiguration(
            enabled: true,
            verbosity: .verbose,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: false
        )
        await store.record(component: "Test", name: "timestamp_precision", level: .info)

        let pathInfo = await store.pathInfoValue()
        let lines = try String(contentsOf: pathInfo.eventsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let timestampPattern = #/"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"/#

        #expect(lines.contains { line in line.contains(timestampPattern) })
    }

    @Test func minimalVerbosityFiltersInfoAndDebug() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(baseDirectory: base)

        await store.applyConfiguration(
            enabled: true,
            verbosity: .minimal,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: false
        )

        await store.record(component: "Test", name: "debug_event", level: .debug)
        await store.record(component: "Test", name: "info_event", level: .info)
        await store.record(component: "Test", name: "warning_event", level: .warning)

        let events = try await loadEvents(from: store)
        #expect(events.count == 1)
        #expect(events[0].name == "warning_event")
        #expect(events[0].level == .warning)
    }

    @Test func settingsSnapshotDisabledSkipsSnapshotEvent() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(baseDirectory: base)

        await store.applyConfiguration(
            enabled: true,
            verbosity: .minimal,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: false
        )

        await store.recordSettingsSnapshot(sessionId: nil, settings: ["a": "b"])

        let events = try await loadEvents(from: store)
        #expect(events.isEmpty)
    }

    @Test func defaultPathInfoInTestsDoesNotPointToUserHomeObservabilityAppDir() {
        let info = ObservabilityStore.defaultPathInfo
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appDirPrefix = "\(home)/.speakflow/observability/app"

        #expect(!info.baseDirectory.path.hasPrefix(appDirPrefix))
        #expect(info.baseDirectory.path.contains("speakflow-observability"))
    }

    @Test func sessionScopedEventsReceiveMonotonicSessionSequence() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(baseDirectory: base)
        let sessionA = UUID()
        let sessionB = UUID()

        await store.applyConfiguration(
            enabled: true,
            verbosity: .verbose,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: false
        )
        await store.record(component: "Test", name: "global_event", level: .info)
        await store.record(component: "Test", name: "session_a_1", level: .info, sessionId: sessionA)
        await store.record(component: "Test", name: "session_a_2", level: .info, sessionId: sessionA)
        await store.record(component: "Test", name: "session_b_1", level: .info, sessionId: sessionB)

        let events = try await loadEvents(from: store)
        let global = events.first(where: { $0.name == "global_event" })
        let a1 = events.first(where: { $0.name == "session_a_1" })
        let a2 = events.first(where: { $0.name == "session_a_2" })
        let b1 = events.first(where: { $0.name == "session_b_1" })

        #expect(global?.sessionSequence == nil)
        #expect(a1?.sessionSequence == 1)
        #expect(a2?.sessionSequence == 2)
        #expect(b1?.sessionSequence == 1)
    }

    @Test func rotatesEventLogWithoutChangingVerbosity() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(
            baseDirectory: base,
            maxFileBytes: 900,
            maxRotatedFiles: 2
        )

        await store.applyConfiguration(
            enabled: true,
            verbosity: .verbose,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: false
        )

        for index in 0..<12 {
            await store.record(
                component: "Test",
                name: "rotated_\(index)",
                level: .debug,
                metadata: ["payload": String(repeating: "x", count: 160)]
            )
        }

        let pathInfo = await store.pathInfoValue()
        let currentEvents = try await loadEvents(from: store)
        #expect(currentEvents.contains { $0.name == "rotated_11" })
        #expect(
            FileManager.default.fileExists(
                atPath: pathInfo.eventsFile.deletingLastPathComponent()
                    .appendingPathComponent("events.jsonl.1").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: pathInfo.eventsFile.deletingLastPathComponent()
                    .appendingPathComponent("events.jsonl.3").path
            )
        )
    }

    @Test func eventsFileAndBaseDirectoryAreOwnerOnly() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(baseDirectory: base)

        await store.applyConfiguration(
            enabled: true,
            verbosity: .verbose,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: true
        )
        await store.record(component: "Test", name: "event_written", level: .info)

        let pathInfo = await store.pathInfoValue()
        let filePermissions = try posixPermissions(atPath: pathInfo.eventsFile.path)
        let dirPermissions = try posixPermissions(atPath: pathInfo.baseDirectory.path)

        #expect(filePermissions == 0o600)
        #expect(dirPermissions == 0o700)
    }

    @Test func migratesPreExistingWorldReadableStorageToOwnerOnly() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let eventsPath = base.appendingPathComponent("events.jsonl").path
        #expect(fileManager.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o644]))

        // Precondition: the pre-existing artifacts really were created with looser permissions.
        #expect(try posixPermissions(atPath: eventsPath) == 0o644)

        let store = ObservabilityStore(baseDirectory: base)
        let pathInfo = await store.pathInfoValue()

        #expect(try posixPermissions(atPath: pathInfo.eventsFile.path) == 0o600)
        #expect(try posixPermissions(atPath: pathInfo.baseDirectory.path) == 0o700)
    }

    @Test func rotatedEventsFilesRemainOwnerOnly() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("observability-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ObservabilityStore(
            baseDirectory: base,
            maxFileBytes: 900,
            maxRotatedFiles: 2
        )

        await store.applyConfiguration(
            enabled: true,
            verbosity: .verbose,
            captureSettingsSnapshot: false,
            captureSystemContext: false,
            captureTextPayloads: false
        )

        for index in 0..<12 {
            await store.record(
                component: "Test",
                name: "rotated_\(index)",
                level: .debug,
                metadata: ["payload": String(repeating: "x", count: 160)]
            )
        }

        let pathInfo = await store.pathInfoValue()
        let rotatedSibling = pathInfo.eventsFile.deletingLastPathComponent()
            .appendingPathComponent("events.jsonl.1")

        #expect(FileManager.default.fileExists(atPath: rotatedSibling.path))
        #expect(try posixPermissions(atPath: pathInfo.eventsFile.path) == 0o600)
        #expect(try posixPermissions(atPath: rotatedSibling.path) == 0o600)
    }

    private func posixPermissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return permissions.intValue
    }

    private func loadEvents(from store: ObservabilityStore) async throws -> [ObservabilityEvent] {
        let pathInfo = await store.pathInfoValue()
        let data = try Data(contentsOf: pathInfo.eventsFile)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 timestamp: \(value)"
            )
        }
        return try lines.map { line in
            try decoder.decode(ObservabilityEvent.self, from: Data(line.utf8))
        }
    }
}
