import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

/// Credential storage must never silently lose or keep credentials: an
/// unreadable file is not "no credentials", a failed write is not success, and
/// a token refresh that finishes after logout must not log the user back in.
@Suite("Credential Storage Safety", .serialized)
struct CredentialStorageTests {
    private func makeStorage() throws -> (UnifiedAuthStorage, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakflow-auth-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        return (UnifiedAuthStorage(fileURL: file), file)
    }

    private func credentials(_ token: String) -> OAuthCredentials {
        OAuthCredentials(accessToken: token, refreshToken: "r-\(token)", idToken: nil, accountId: "acct", lastRefresh: Date())
    }

    @Test
    func unreadableFileIsNotReplacedByAWrite() throws {
        let (storage, file) = try makeStorage()
        let original = Data("{ not json".utf8)
        try original.write(to: file)

        #expect(throws: (any Error).self) { try storage.setApiKey("new-key", for: ProviderId.deepgram) }
        #expect(try Data(contentsOf: file) == original,
                "An existing file that cannot be read must not be overwritten, or other credentials are lost")
        #expect(storage.apiKey(for: ProviderId.deepgram) == nil)
    }

    @Test
    func missingFileStartsEmpty() throws {
        let (storage, _) = try makeStorage()
        try storage.setApiKey("k1", for: ProviderId.deepgram)
        #expect(storage.apiKey(for: ProviderId.deepgram) == "k1")
    }

    @Test
    func writeFailuresAreReported() throws {
        let (storage, file) = try makeStorage()
        try storage.setApiKey("k1", for: ProviderId.deepgram)
        try storage.saveChatGPTCredentials(credentials("a"))
        let dir = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        #expect(throws: (any Error).self) { try storage.setApiKey("k2", for: ProviderId.deepgram) }
        #expect(throws: (any Error).self) { try storage.removeApiKey(for: ProviderId.deepgram) }
        #expect(throws: (any Error).self) { try storage.deleteChatGPTCredentials() }
        #expect(storage.apiKey(for: ProviderId.deepgram) == "k1")
    }

    @Test
    func saveStartedBeforeLogoutIsRejected() throws {
        let (storage, _) = try makeStorage()
        try storage.saveChatGPTCredentials(credentials("a"))
        let refreshStartedAt = storage.chatGPTCredentialGeneration()

        try storage.deleteChatGPTCredentials()

        #expect(throws: AuthError.credentialsChanged) {
            try storage.saveChatGPTCredentials(credentials("refreshed"), expectedGeneration: refreshStartedAt)
        }
        #expect(storage.loadChatGPTCredentials() == nil, "Logout must stick")
    }

    @Test
    func saveStartedBeforeANewerLoginIsRejected() throws {
        let (storage, _) = try makeStorage()
        try storage.saveChatGPTCredentials(credentials("a"))
        let refreshStartedAt = storage.chatGPTCredentialGeneration()

        try storage.saveChatGPTCredentials(credentials("newer-login"))

        #expect(throws: AuthError.credentialsChanged) {
            try storage.saveChatGPTCredentials(credentials("stale-refresh"), expectedGeneration: refreshStartedAt)
        }
        #expect(storage.loadChatGPTCredentials()?.accessToken == "newer-login")
    }
}

/// HTTP provider that holds the token response until released.
final class HeldTokenResponse: HTTPDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var release: CheckedContinuation<Void, Never>?
    private var released = false
    let body: Data

    init(body: Data) { self.body = body }

    var hasStarted: Bool { lock.withLock { started } }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { release = nil }
            return release
        }
        continuation?.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                started = true
                if released { return true }
                release = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return (body, response)
    }
}

@Suite("AuthController — Credential Mutation Failures")
struct AuthControllerCredentialFailureTests {
    struct WriteFailed: Error {}

    @Test @MainActor
    func failedLogoutIsReportedNotAnnouncedAsSuccess() {
        let banner = SpyBannerPresenter()
        let controller = AuthController(
            appState: banner,
            providerSettings: SpyProviderSettings(),
            providerRegistry: SpyProviderRegistry(),
            deleteChatGPTCredentials: { throw WriteFailed() }
        )

        controller.handleLogout()

        #expect(banner.bannerMessages.contains { $0.1 == .error })
        #expect(!banner.bannerMessages.contains { $0.0.contains("Logged out") })
    }

    @Test @MainActor
    func failedKeyRemovalIsReportedAndKeepsTheActiveProvider() {
        let settings = SpyProviderSettings()
        settings.activeProviderId = ProviderId.deepgram
        settings.storedKeys[ProviderId.deepgram] = "key"
        settings.mutationError = WriteFailed()
        let banner = SpyBannerPresenter()
        let controller = AuthController(
            appState: banner, providerSettings: settings, providerRegistry: SpyProviderRegistry()
        )

        controller.handleRemoveApiKey(for: ProviderId.deepgram)

        #expect(banner.bannerMessages.contains { $0.1 == .error })
        #expect(settings.activeProviderId == ProviderId.deepgram)
    }
}

/// Lives in the suite that serializes every swap of OpenAICodexAuth.httpProvider.
extension HTTPDataProviderTestabilityTests {
    private static func jwt(accountId: String) throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try encode(["alg": "none"])
        let payload = try encode(["https://api.openai.com/auth": ["chatgpt_account_id": accountId]])
        return "\(header).\(payload).sig"
    }

    @Test
    func refreshThatCompletesAfterLogoutDoesNotLogBackIn() async throws {
        let saved = OpenAICodexAuth.httpProvider
        defer { OpenAICodexAuth.httpProvider = saved }
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": try Self.jwt(accountId: "acct"), "refresh_token": "new-refresh", "expires_in": 3600
        ])
        let held = HeldTokenResponse(body: body)
        OpenAICodexAuth.httpProvider = held
        let current = OAuthCredentials(accessToken: "old", refreshToken: "old-refresh", idToken: nil, accountId: "acct", lastRefresh: .distantPast)
        try OpenAICodexAuth.saveCredentials(current)

        let refresh = Task { try await OpenAICodexAuth.refreshTokens(current) }
        try await waitUntilAsync { held.hasStarted }
        try OpenAICodexAuth.deleteCredentials()
        held.open()
        _ = try? await refresh.value

        #expect(OpenAICodexAuth.loadCredentials() == nil,
                "A refresh that finishes after logout must not restore the credentials")
    }
}
