import Foundation

/// Authentication credentials for OpenAI API
public struct AuthCredentials: Sendable {
    public let accessToken: String
    public let accountId: String

    /// Load credentials from OAuth storage
    /// Throws if not logged in or tokens are invalid
    public static func load() async throws -> AuthCredentials {
        // Try to get valid access token (will refresh if needed)
        let accessToken = try await OpenAICodexAuth.getValidAccessToken()
        
        // Load full credentials for account ID
        guard let credentials = OpenAICodexAuth.loadCredentials() else {
            throw TranscriptionError.authenticationFailed(reason: "Not logged in. Please login via the menu.")
        }
        
        return AuthCredentials(
            accessToken: accessToken,
            accountId: credentials.accountId
        )
    }
    
    /// Synchronous load for cases where we can't use async
    /// Note: This won't auto-refresh tokens
    public static func loadSync() throws -> AuthCredentials {
        guard let credentials = OpenAICodexAuth.loadCredentials() else {
            throw TranscriptionError.authenticationFailed(reason: "Not logged in. Please login via the menu.")
        }
        
        // Check if expired
        if credentials.isExpired {
            throw TranscriptionError.authenticationFailed(reason: "Session expired. Please login again.")
        }
        
        return AuthCredentials(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId
        )
    }
}
