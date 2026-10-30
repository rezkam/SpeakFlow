import FluidAudio
import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - VAD model test dependency

/// Test-only access to FluidAudio's local Silero cache location.
///
/// The override makes cache-dependent test gating deterministic without changing
/// FluidAudio's production cache or touching the user's actual model files.
enum VADModelTestSupport {
    static let cacheRootOverrideEnvironmentKey = "SPEAKFLOW_VAD_MODEL_CACHE_ROOT"
    static let verificationEnvironmentKey = "SPEAKFLOW_VERIFY_VAD_MODEL"
    static let modelTestEnvironmentKey = "SPEAKFLOW_RUN_VAD_MODEL_TESTS"

    static func defaultCacheRoot(
        fileManager: FileManager = .default
    ) -> URL {
        VADModelCache.modelCacheRoot(environment: [:], fileManager: fileManager)
    }

    static func configuredCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        VADModelCache.modelCacheRoot(environment: environment, fileManager: fileManager)
    }

    static func modelURL(cacheRoot: URL) -> URL {
        cacheRoot
            .appendingPathComponent(LocalVADAssets.manifest.installationName, isDirectory: true)
            .appendingPathComponent(LocalVADAssets.manifest.modelDirectory)
    }

    static func hasLocalModel(
        cacheRoot: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        fileExists(modelURL(cacheRoot: cacheRoot).path)
    }

    static func platformSupportsVAD(isAvailable: Bool = VADProcessor.isAvailable) -> Bool {
        isAvailable
    }

    static func integrationTestsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        isVADAvailable: Bool = VADProcessor.isAvailable,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard environment[modelTestEnvironmentKey] == "1",
              platformSupportsVAD(isAvailable: isVADAvailable) else {
            return false
        }
        return hasLocalModel(
            cacheRoot: configuredCacheRoot(environment: environment, fileManager: fileManager),
            fileExists: fileExists
        )
    }

    static func verificationTestsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isVADAvailable: Bool = VADProcessor.isAvailable
    ) -> Bool {
        environment[verificationEnvironmentKey] == "1" && platformSupportsVAD(isAvailable: isVADAvailable)
    }
}

@Suite("VAD model cache location")
struct VADModelCacheLocationTests {
    @Test func isolatedProcessModelRootNeverUsesInstalledApplicationSupport() {
        let expected = RuntimeIsolation.current.dataDirectory
            .appendingPathComponent("Models", isDirectory: true)
        let root = VADModelTestSupport.configuredCacheRoot(environment: [:])
        #expect(root == expected)
    }

    @Test func modelPathUsesReviewedManifestIdentity() throws {
        let root = URL(fileURLWithPath: "/cache-root", isDirectory: true)
        let expected = root
            .appendingPathComponent(LocalVADAssets.manifest.installationName, isDirectory: true)
            .appendingPathComponent(LocalVADAssets.manifest.modelDirectory)
        #expect(VADModelTestSupport.modelURL(cacheRoot: root) == expected)
    }

    @Test func localModelDetectionDistinguishesPresentAndAbsentRoots() {
        let root = URL(fileURLWithPath: "/cache-root", isDirectory: true)
        let modelPath = VADModelTestSupport.modelURL(cacheRoot: root).path

        #expect(!VADModelTestSupport.hasLocalModel(cacheRoot: root, fileExists: { _ in false }))
        #expect(VADModelTestSupport.hasLocalModel(cacheRoot: root, fileExists: { $0 == modelPath }))
    }

    @Test func cacheRootOverrideIsUsed() {
        let override = "/deterministic-vad-cache"
        let configured = VADModelTestSupport.configuredCacheRoot(
            environment: [VADModelTestSupport.cacheRootOverrideEnvironmentKey: override]
        )
        #expect(configured.path == override)
    }

    @Test func modelTestsRequireExplicitOptInEvenWhenCacheIsPresent() {
        let root = URL(fileURLWithPath: "/cache-root", isDirectory: true)
        let modelPath = VADModelTestSupport.modelURL(cacheRoot: root).path
        let cacheEnvironment = [VADModelTestSupport.cacheRootOverrideEnvironmentKey: root.path]

        #expect(!VADModelTestSupport.integrationTestsEnabled(
            environment: cacheEnvironment,
            isVADAvailable: true,
            fileExists: { $0 == modelPath }
        ))
        #expect(VADModelTestSupport.integrationTestsEnabled(
            environment: cacheEnvironment.merging(
                [VADModelTestSupport.modelTestEnvironmentKey: "1"],
                uniquingKeysWith: { _, new in new }
            ),
            isVADAvailable: true,
            fileExists: { $0 == modelPath }
        ))
    }

    @Test func falseLikeModelTestOptInsRemainDisabled() {
        let root = URL(fileURLWithPath: "/cache-root", isDirectory: true)
        let modelPath = VADModelTestSupport.modelURL(cacheRoot: root).path
        for value in ["0", "false"] {
            #expect(!VADModelTestSupport.integrationTestsEnabled(
                environment: [
                    VADModelTestSupport.cacheRootOverrideEnvironmentKey: root.path,
                    VADModelTestSupport.modelTestEnvironmentKey: value
                ],
                isVADAvailable: true,
                fileExists: { $0 == modelPath }
            ))
        }
    }

    @Test func unsupportedPlatformsDisableModelAndVerificationTests() {
        let root = URL(fileURLWithPath: "/cache-root", isDirectory: true)
        let modelPath = VADModelTestSupport.modelURL(cacheRoot: root).path
        #expect(VADModelTestSupport.platformSupportsVAD(isAvailable: true))
        #expect(!VADModelTestSupport.platformSupportsVAD(isAvailable: false))
        #expect(!VADModelTestSupport.integrationTestsEnabled(
            environment: [
                VADModelTestSupport.cacheRootOverrideEnvironmentKey: root.path,
                VADModelTestSupport.modelTestEnvironmentKey: "1"
            ],
            isVADAvailable: false,
            fileExists: { $0 == modelPath }
        ))
        #expect(!VADModelTestSupport.verificationTestsEnabled(
            environment: [VADModelTestSupport.verificationEnvironmentKey: "1"],
            isVADAvailable: false
        ))
    }

    @Test func verificationRequiresExactOptInValue() {
        #expect(VADModelTestSupport.verificationTestsEnabled(
            environment: [VADModelTestSupport.verificationEnvironmentKey: "1"],
            isVADAvailable: true
        ))
        for value in ["", "0", "false"] {
            #expect(!VADModelTestSupport.verificationTestsEnabled(
                environment: [VADModelTestSupport.verificationEnvironmentKey: value],
                isVADAvailable: true
            ))
        }
    }
}

@Suite("VAD model verification", .enabled(if: VADModelTestSupport.verificationTestsEnabled()))
struct VADModelVerificationTests {
    @Test func verifySileroModelForRegressionCoverage() async throws {
        do {
            let vad = VADProcessor(config: .default)
            try await vad.initialize()
        } catch {
            throw VADModelVerificationError.verificationFailed(error)
        }
    }
}

private enum VADModelVerificationError: LocalizedError {
    case verificationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let error):
            return "Regression-core could not verify the Silero VAD model required for VADIntegrationTests: \(error.localizedDescription)"
        }
    }
}
