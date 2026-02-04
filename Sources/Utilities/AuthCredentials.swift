import Foundation

/// Authentication credentials loaded from local storage
struct AuthCredentials: Sendable {
    let accessToken: String
    let accountId: String
    let cookies: [String: String]

    static func load() throws -> AuthCredentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")

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
