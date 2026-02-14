import Foundation
import OSLog

/// Centralized storage for all provider credentials in `~/.speakflow/auth.json`.
///
/// Stores ChatGPT OAuth tokens and provider API keys (Deepgram, etc.) in a single
/// JSON file. Each provider occupies a top-level key:
/// ```json
/// {
///   "chatgpt": { "tokens": { ... }, "last_refresh": "..." },
///   "deepgram": { "api_key": "..." }
/// }
/// ```
/// Thread-safe via internal locking for concurrent read-modify-write operations.
public final class UnifiedAuthStorage: @unchecked Sendable {
    public static let shared = UnifiedAuthStorage()

    private let lock = NSLock()

    private static let speakflowDir: URL = {
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
        if isTestRun {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("speakflow-test-\(ProcessInfo.processInfo.processIdentifier)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".speakflow")
    }()

    static var fileURL: URL {
        let dir = speakflowDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auth.json")
    }

    private init() {}

    // MARK: - ChatGPT OAuth

    struct ChatGPTSection: Codable {
        var tokens: Tokens
        var lastRefresh: String

        enum CodingKeys: String, CodingKey {
            case tokens
            case lastRefresh = "last_refresh"
        }

        struct Tokens: Codable {
            var idToken: String?
            var accessToken: String
            var refreshToken: String
            var accountId: String

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountId = "account_id"
            }
        }
    }

    public func saveChatGPTCredentials(_ credentials: OAuthCredentials) throws {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let section = ChatGPTSection(
            tokens: .init(
                idToken: credentials.idToken,
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                accountId: credentials.accountId
            ),
            lastRefresh: iso8601.string(from: credentials.lastRefresh)
        )

        let sectionData = try JSONEncoder().encode(section)
        guard let sectionDict = try JSONSerialization.jsonObject(with: sectionData) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed("Failed to encode credentials")
        }

        lock.lock()
        defer { lock.unlock() }
        var content = readFileUnlocked()
        content["chatgpt"] = sectionDict
        try writeFileUnlocked(content)
    }

    public func loadChatGPTCredentials() -> OAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return loadChatGPTUnlocked()
    }

    private func loadChatGPTUnlocked() -> OAuthCredentials? {
        let content = readFileUnlocked()

        guard let section = content["chatgpt"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: section),
              let chatgpt = try? JSONDecoder().decode(ChatGPTSection.self, from: data) else {
            return nil
        }

        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lastRefresh = iso8601.date(from: chatgpt.lastRefresh) ?? Date.distantPast

        return OAuthCredentials(
            accessToken: chatgpt.tokens.accessToken,
            refreshToken: chatgpt.tokens.refreshToken,
            idToken: chatgpt.tokens.idToken,
            accountId: chatgpt.tokens.accountId,
            lastRefresh: lastRefresh
        )
    }

    public func deleteChatGPTCredentials() {
        lock.lock()
        defer { lock.unlock() }
        var content = readFileUnlocked()
        content.removeValue(forKey: "chatgpt")
        if content.isEmpty {
            try? FileManager.default.removeItem(at: Self.fileURL)
        } else {
            try? writeFileUnlocked(content)
        }
    }

    // MARK: - Provider API Keys

    public func apiKey(for providerId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let content = readFileUnlocked()
        guard let section = content[providerId] as? [String: Any] else { return nil }
        return section["api_key"] as? String
    }

    public func setApiKey(_ key: String?, for providerId: String) {
        lock.lock()
        defer { lock.unlock() }
        var content = readFileUnlocked()
        if let key, !key.isEmpty {
            content[providerId] = ["api_key": key]
        } else {
            content.removeValue(forKey: providerId)
        }
        try? writeFileUnlocked(content)
    }

    public func removeApiKey(for providerId: String) {
        lock.lock()
        defer { lock.unlock() }
        var content = readFileUnlocked()
        content.removeValue(forKey: providerId)
        try? writeFileUnlocked(content)
    }

    // MARK: - Private File I/O

    private func readFileUnlocked() -> [String: Any] {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path),
              let data = try? Data(contentsOf: Self.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func writeFileUnlocked(_ content: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.fileURL.path
        )
    }
}
