#if DEBUG
import Foundation
import SpeakFlowCore

/// Exercises persistent singletons only beneath a verified synthetic home.
@MainActor
enum StorageIsolationProbe {
    static func run() async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agents/tests", isDirectory: true).standardizedFileURL
        guard let configuredHome = environment["CFFIXED_USER_HOME"],
              home.path == URL(fileURLWithPath: configuredHome).standardizedFileURL.path,
              home.path.hasPrefix(fixtures.path + "/"),
              FileManager.default.fileExists(atPath: home.appendingPathComponent("fixture-home-marker").path)
        else {
            print("FAIL: synthetic home was not established")
            return 1
        }

        let defaults = UserDefaults.standard
        let keys = ["settings.deepgram.model", "provider.active", "activationHotkey"]
        for key in keys { defaults.set("production-sentinel", forKey: key) }
        defaults.synchronize()

        Settings.shared.deepgramModel = "nova-3"
        ProviderSettings.shared.activeProviderId = ProviderId.mistralBatch
        HotkeySettings.shared.currentHotkey = .doubleTapControl
        guard Settings.shared.deepgramModel == "nova-3",
              ProviderSettings.shared.activeProviderId == ProviderId.mistralBatch,
              HotkeySettings.shared.currentHotkey == .doubleTapControl,
              keys.allSatisfy({ defaults.string(forKey: $0) == "production-sentinel" }) else {
            print("FAIL: defaults stores did not preserve production sentinels")
            return 1
        }

        do {
            try UnifiedAuthStorage.shared.setApiKey("synthetic-isolated-key", for: ProviderId.mistralBatch)
            guard UnifiedAuthStorage.shared.apiKey(for: ProviderId.mistralBatch) == "synthetic-isolated-key" else {
                print("FAIL: isolated credentials did not round-trip")
                return 1
            }
            let wordsBefore = Statistics.shared.totalWords
            Statistics.shared.recordTranscription(text: "fixture words", audioDurationSeconds: 1)
            Statistics.shared.flushIfDirty()
            let metrics = SessionMetricsStore.shared
            let session = await metrics.startSession(providerId: ProviderId.mistralBatch, mode: .batch)
            await metrics.addWords(sessionId: session, count: 2)
            await metrics.endSession(sessionId: session, reason: "fixture")
            guard await metrics.recentCompletedSessions().contains(where: { $0.sessionId == session && $0.wordsProduced == 2 }) else {
                print("FAIL: isolated session metrics did not round-trip")
                return 1
            }
            let isolatedDirectory = RuntimeIsolation.current.dataDirectory
            guard isolatedDirectory != home.appendingPathComponent(".speakflow"),
                  ["auth.json", "statistics.json", "session_metrics.json"].allSatisfy({
                      FileManager.default.fileExists(atPath: isolatedDirectory.appendingPathComponent($0).path)
                  }) else {
                print("FAIL: file stores did not write isolated artifacts")
                return 1
            }
            let statisticsData = try Data(contentsOf: isolatedDirectory.appendingPathComponent("statistics.json"))
            let statistics = try JSONSerialization.jsonObject(with: statisticsData) as? [String: Any]
            let metricsData = try Data(contentsOf: isolatedDirectory.appendingPathComponent("session_metrics.json"))
            let persistedMetrics = try JSONSerialization.jsonObject(with: metricsData) as? [String: Any]
            let completed = persistedMetrics?["completed"] as? [[String: Any]]
            let credentials = try String(contentsOf: isolatedDirectory.appendingPathComponent("auth.json"), encoding: .utf8)
            guard statistics?["totalWords"] as? Int == wordsBefore + 2,
                  completed?.contains(where: { $0["sessionId"] as? String == session.uuidString }) == true,
                  credentials.contains("synthetic-isolated-key") else {
                print("FAIL: isolated file contents did not preserve mutations")
                return 1
            }
        } catch {
            print("FAIL: isolated store operation failed")
            return 1
        }
        print("PASS: six persistent stores isolated and defaults sentinels preserved")
        return 0
    }
}
#endif
