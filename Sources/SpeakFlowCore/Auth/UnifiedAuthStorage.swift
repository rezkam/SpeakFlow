import Foundation
import os
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

    private let lock = OSAllocatedUnfairLock(initialState: ())

    private static let speakflowDir: URL = directory(for: RuntimeIsolation.current)

    static func directory(for isolation: RuntimeIsolation.Decision) -> URL {
        isolation.dataDirectory
    }

    static var fileURL: URL {
        let dir = speakflowDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auth.json")
    }

    private let fileURLOverride: URL?
    /// Advanced by logout and by every successful ChatGPT credential save, so
    /// a refresh or login exchange that started earlier cannot commit.
    private var chatGPTGeneration: UInt64 = 0

    private init() {
        fileURLOverride = nil
    }

    /// Storage backed by `fileURL` instead of the shared location (tests).
    init(fileURL: URL) {
        fileURLOverride = fileURL
    }

    private var storageFileURL: URL { fileURLOverride ?? Self.fileURL }

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

    /// Generation to pass back to `saveChatGPTCredentials(_:expectedGeneration:)`.
    public func chatGPTCredentialGeneration() -> UInt64 {
        lock.withLockUnchecked { _ in chatGPTGeneration }
    }

    public func saveChatGPTCredentials(_ credentials: OAuthCredentials, expectedGeneration: UInt64? = nil) throws {
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

        try lock.withLockUnchecked { _ in
            // A refresh or login exchange that started before a logout or a
            // newer login must not commit over it.
            if let expectedGeneration, expectedGeneration != chatGPTGeneration {
                throw AuthError.credentialsChanged
            }
            var content = try readFileUnlocked()
            content["chatgpt"] = sectionDict
            try writeFileUnlocked(content)
            chatGPTGeneration &+= 1
        }
    }

    public func loadChatGPTCredentials() -> OAuthCredentials? {
        lock.withLockUnchecked { _ in loadChatGPTUnlocked() }
    }

    private func loadChatGPTUnlocked() -> OAuthCredentials? {
        let content = readForLookupUnlocked()

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

    public func deleteChatGPTCredentials() throws {
        try lock.withLockUnchecked { _ in
            // Logout invalidates in-flight refreshes even if the removal fails.
            chatGPTGeneration &+= 1
            var content = try readFileUnlocked()
            content.removeValue(forKey: "chatgpt")
            if content.isEmpty {
                if FileManager.default.fileExists(atPath: storageFileURL.path) {
                    try FileManager.default.removeItem(at: storageFileURL)
                }
            } else {
                try writeFileUnlocked(content)
            }
        }
    }

    // MARK: - Provider API Keys

    public func apiKey(for providerId: String) -> String? {
        lock.withLockUnchecked { _ in
            let content = readForLookupUnlocked()
            guard let section = content[providerId] as? [String: Any] else { return nil }
            return section["api_key"] as? String
        }
    }

    public func setApiKey(_ key: String?, for providerId: String) throws {
        try lock.withLockUnchecked { _ in
            var content = try readFileUnlocked()
            if let key, !key.isEmpty {
                content[providerId] = ["api_key": key]
            } else {
                content.removeValue(forKey: providerId)
            }
            try writeFileUnlocked(content)
        }
    }

    public func removeApiKey(for providerId: String) throws {
        try lock.withLockUnchecked { _ in
            var content = try readFileUnlocked()
            content.removeValue(forKey: providerId)
            try writeFileUnlocked(content)
        }
    }

    // MARK: - Private File I/O

    /// Reads the credential file. A missing file is empty storage; a file that
    /// exists but cannot be read or decoded throws, so no write can replace it
    /// and lose the credentials it holds.
    private func readFileUnlocked() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: storageFileURL.path) else { return [:] }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: try Data(contentsOf: storageFileURL))
        } catch {
            throw CredentialStorageError.unreadable(error.localizedDescription)
        }
        guard let content = json as? [String: Any] else {
            throw CredentialStorageError.unreadable("not a credential dictionary")
        }
        return content
    }

    /// Read for lookups: unreadable storage yields no credential, logged.
    private func readForLookupUnlocked() -> [String: Any] {
        do {
            return try readFileUnlocked()
        } catch {
            Logger.auth.error("Credential storage unreadable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func writeFileUnlocked(_ content: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: content,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storageFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageFileURL.path
        )
    }
}

/// Credential storage exists but could not be used.
public enum CredentialStorageError: LocalizedError, Equatable {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return String(localized: "The credential file could not be read (\(reason)). It was left unchanged.")
        }
    }
}
