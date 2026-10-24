import Foundation
import os

/// Decides whether this process must keep its data away from the user's real
/// stores, and where isolated data lives instead.
///
/// Every persistent store (statistics, session metrics, credentials, settings,
/// provider settings, hotkey settings) must resolve its location through this
/// one decision before its singleton initializes.
public enum RuntimeIsolation {
    private static let forced = OSAllocatedUnfairLock(initialState: false)

    /// Isolates this process from the user's stores. Test executables call it
    /// first thing, before any store singleton is touched.
    public static func isolateThisProcess() {
        forced.withLock { $0 = true }
    }

    /// The decision for this process.
    public static var current: Decision {
        Decision(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            bundlePath: Bundle.main.bundlePath,
            processId: ProcessInfo.processInfo.processIdentifier,
            forced: forced.withLock { $0 }
        )
    }

    public struct Decision: Sendable, Equatable {
        public let isIsolated: Bool
        private let processId: Int32

        public init(
            environment: [String: String],
            arguments: [String],
            bundlePath: String,
            processId: Int32,
            forced: Bool = false
        ) {
            let isXCTest = bundlePath.contains(".xctest") || arguments.contains { $0.contains("xctest") }
            // UI tests launch the real app binary, so XCTest detection cannot see them.
            let isUITestLaunch = environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
            let isExplicit = environment["SPEAKFLOW_ISOLATED_STORAGE"] == "1"
            isIsolated = forced || isXCTest || isUITestLaunch || isExplicit
            self.processId = processId
        }

        /// Replaces `~/.speakflow` for file-backed stores.
        public var dataDirectory: URL {
            if isIsolated {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("speakflow-test-\(processId)")
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".speakflow")
        }

        /// Defaults suite replacing `UserDefaults.standard`, or nil to use it.
        public func defaultsSuiteName(prefix: String) -> String? {
            isIsolated ? "\(prefix).\(processId)" : nil
        }

        /// Defaults for a settings store: a fresh per-process suite when
        /// isolated, the user's standard defaults otherwise.
        public func makeDefaults(prefix: String) -> UserDefaults {
            guard let suiteName = defaultsSuiteName(prefix: prefix),
                  let defaults = UserDefaults(suiteName: suiteName) else { return .standard }
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
    }
}
