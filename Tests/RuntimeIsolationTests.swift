import Foundation
import Testing
@testable import SpeakFlowCore

/// A UI-test launch runs the real app binary, so XCTest detection alone does
/// not see it. Statistics reset at UI-test launch used to wipe the user's real
/// usage history, and the harness overwrote the user's hotkey setting.
@Suite("Runtime Isolation")
struct RuntimeIsolationTests {
    private let appBundle = "/Applications/SpeakFlow.app"
    private let appBinary = "/Applications/SpeakFlow.app/Contents/MacOS/SpeakFlow"
    private var realData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".speakflow")
    }

    private func decision(environment: [String: String] = [:], forced: Bool = false) -> RuntimeIsolation.Decision {
        RuntimeIsolation.Decision(
            environment: environment, arguments: [appBinary], bundlePath: appBundle, processId: 4242, forced: forced
        )
    }

    @Test
    func normalAppLaunchUsesTheUsersStores() {
        let normal = decision()
        #expect(!normal.isIsolated)
        #expect(normal.dataDirectory == realData)
        #expect(normal.defaultsSuiteName(prefix: "nu.rez.speakflow.tests") == nil)
    }

    @Test
    func uiTestLaunchOfTheAppIsIsolated() {
        let uiTest = decision(environment: ["SPEAKFLOW_UI_TEST_MODE": "1"])
        #expect(uiTest.isIsolated)
        #expect(uiTest.dataDirectory != realData)
        #expect(uiTest.defaultsSuiteName(prefix: "nu.rez.speakflow.tests") != nil)
    }

    @Test
    func explicitlyIsolatedProcessIsIsolated() {
        #expect(decision(forced: true).isIsolated)
        #expect(decision(environment: ["SPEAKFLOW_ISOLATED_STORAGE": "1"]).isIsolated)
    }

    @Test
    func everyFileStoreResolvesThroughTheDecision() {
        let uiTest = decision(environment: ["SPEAKFLOW_UI_TEST_MODE": "1"])
        let isolatedDir = uiTest.dataDirectory.path
        #expect(Statistics.storageURL(for: uiTest).path.hasPrefix(isolatedDir))
        #expect(SessionMetricsStore.storageURL(for: uiTest).path.hasPrefix(isolatedDir))
        #expect(UnifiedAuthStorage.directory(for: uiTest).path.hasPrefix(isolatedDir))
    }
}
