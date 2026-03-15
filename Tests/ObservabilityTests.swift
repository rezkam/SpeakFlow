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
        #expect(await store.captureTextPayloadsEnabled() == true)
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

    private func loadEvents(from store: ObservabilityStore) async throws -> [ObservabilityEvent] {
        let pathInfo = await store.pathInfoValue()
        let data = try Data(contentsOf: pathInfo.eventsFile)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines.map { line in
            try decoder.decode(ObservabilityEvent.self, from: Data(line.utf8))
        }
    }
}
