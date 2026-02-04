import Foundation

/// Authentication credentials loaded from local storage
public struct AuthCredentials: Sendable {
    public let accessToken: String
    public let accountId: String
    public let cookies: [String: String]

    public static func load() throws -> AuthCredentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")
        let authPath = authURL.path

        // P1 Security: Check for symlink to prevent path traversal attacks
        let attrs = try? FileManager.default.attributesOfItem(atPath: authPath)
        if let fileType = attrs?[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
            throw TranscriptionError.authenticationFailed(reason: "Auth file cannot be a symlink")
        }

        guard let authData = try? Data(contentsOf: authURL) else {
            throw TranscriptionError.authenticationFailed(reason: "Could not read auth.json")
        }

        guard let json = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let accountId = tokens["account_id"] as? String else {
            throw TranscriptionError.authenticationFailed(reason: "Invalid auth.json format")
        }

        return AuthCredentials(
            accessToken: accessToken,
            accountId: accountId,
            cookies: Cookies.load()
        )
    }
}
