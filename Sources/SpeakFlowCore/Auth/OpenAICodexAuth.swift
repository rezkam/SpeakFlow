import Foundation
import CryptoKit
import OSLog

/// OAuth credentials for OpenAI Codex (matches ~/.codex/auth.json format)
public struct OAuthCredentials: Codable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String?
    public var accountId: String
    public var lastRefresh: Date
    
    public var isExpired: Bool {
        // Access tokens typically expire in 10 days, but we refresh more frequently
        Date().timeIntervalSince(lastRefresh) > 86400 // 24 hours
    }
    
    /// Check if token should be refreshed (within given seconds of last refresh)
    public func shouldRefresh(after seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastRefresh) > seconds
    }
}

/// Codex auth.json file format (matches ~/.codex/auth.json exactly)
private struct CodexAuthFile: Codable {
    var auth_mode: String
    var OPENAI_API_KEY: String?
    var tokens: CodexTokens
    var last_refresh: String
    
    struct CodexTokens: Codable {
        var id_token: String?
        var access_token: String
        var refresh_token: String
        var account_id: String
    }
}

/// OpenAI Codex OAuth authentication
public final class OpenAICodexAuth {
    // OAuth constants (same as Codex Desktop)
    private static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scope = "openid profile email offline_access"
    private static let jwtClaimPath = "https://api.openai.com/auth"
    
    // Credential storage path: ~/.speakflow/auth.json (SpeakFlow's own storage)
    private static var credentialsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let speakflowDir = home.appendingPathComponent(".speakflow")
        try? FileManager.default.createDirectory(at: speakflowDir, withIntermediateDirectories: true)
        return speakflowDir.appendingPathComponent("auth.json")
    }
    
    // MARK: - PKCE
    
    private struct PKCE {
        let verifier: String
        let challenge: String
    }
    
    private static func generatePKCE() -> PKCE {
        // Generate 32 random bytes for verifier
        var verifierBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        let verifier = base64URLEncode(Data(verifierBytes))
        
        // SHA-256 hash for challenge
        let verifierData = Data(verifier.utf8)
        let hash = SHA256.hash(data: verifierData)
        let challenge = base64URLEncode(Data(hash))
        
        return PKCE(verifier: verifier, challenge: challenge)
    }
    
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - State
    
    private static func generateState() -> String {
        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        return stateBytes.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Authorization URL
    
    public struct AuthorizationFlow {
        public let url: URL
        public let verifier: String
        public let state: String
    }
    
    public static func createAuthorizationFlow() -> AuthorizationFlow {
        let pkce = generatePKCE()
        let state = generateState()
        
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex"),
        ]
        
        return AuthorizationFlow(
            url: components.url!,
            verifier: pkce.verifier,
            state: state
        )
    }
    
    // MARK: - Token Exchange
    
    public static func exchangeCodeForTokens(code: String, flow: AuthorizationFlow) async throws -> OAuthCredentials {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": flow.verifier,
            "redirect_uri": redirectURI,
        ]
        
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.auth.error("Token exchange failed: \(errorText)")
            throw AuthError.tokenExchangeFailed(errorText)
        }
        
        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String
            let id_token: String?
            let expires_in: Int
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        guard let accountId = extractAccountId(from: tokenResponse.access_token) else {
            throw AuthError.missingAccountId
        }
        
        let credentials = OAuthCredentials(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            idToken: tokenResponse.id_token,
            accountId: accountId,
            lastRefresh: Date()
        )
        
        // Save credentials in Codex format
        try saveCredentials(credentials)
        
        Logger.auth.info("Successfully logged in to OpenAI Codex")
        return credentials
    }
    
    // MARK: - Token Refresh
    
    public static func refreshTokens(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": clientId,
        ]
        
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.auth.error("Token refresh failed: \(errorText)")
            throw AuthError.tokenRefreshFailed(errorText)
        }
        
        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String
            let id_token: String?
            let expires_in: Int
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        guard let accountId = extractAccountId(from: tokenResponse.access_token) else {
            throw AuthError.missingAccountId
        }
        
        let newCredentials = OAuthCredentials(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            idToken: tokenResponse.id_token,
            accountId: accountId,
            lastRefresh: Date()
        )
        
        // Save updated credentials
        try saveCredentials(newCredentials)
        
        Logger.auth.info("Successfully refreshed OpenAI Codex tokens")
        return newCredentials
    }
    
    // MARK: - JWT Parsing
    
    private static func extractAccountId(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        
        var base64 = String(parts[1])
        // Add padding if needed
        while base64.count % 4 != 0 {
            base64 += "="
        }
        // Convert from base64url to base64
        base64 = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        guard let payloadData = Data(base64Encoded: base64) else { return nil }
        
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = payload[jwtClaimPath] as? [String: Any],
              let accountId = auth["chatgpt_account_id"] as? String else {
            return nil
        }
        
        return accountId
    }
    
    // MARK: - Credential Storage (Codex format: ~/.codex/auth.json)
    
    public static func saveCredentials(_ credentials: OAuthCredentials) throws {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let authFile = CodexAuthFile(
            auth_mode: "chatgpt",
            OPENAI_API_KEY: nil,
            tokens: CodexAuthFile.CodexTokens(
                id_token: credentials.idToken,
                access_token: credentials.accessToken,
                refresh_token: credentials.refreshToken,
                account_id: credentials.accountId
            ),
            last_refresh: iso8601Formatter.string(from: credentials.lastRefresh)
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(authFile)
        
        // Write with restricted permissions (600)
        let fileURL = credentialsURL
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        
        Logger.auth.debug("Credentials saved to \(fileURL.path)")
    }
    
    public static func loadCredentials() -> OAuthCredentials? {
        let fileURL = credentialsURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let authFile = try JSONDecoder().decode(CodexAuthFile.self, from: data)
            
            // Parse last_refresh date
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let lastRefresh = iso8601Formatter.date(from: authFile.last_refresh) ?? Date()
            
            return OAuthCredentials(
                accessToken: authFile.tokens.access_token,
                refreshToken: authFile.tokens.refresh_token,
                idToken: authFile.tokens.id_token,
                accountId: authFile.tokens.account_id,
                lastRefresh: lastRefresh
            )
        } catch {
            Logger.auth.error("Failed to load credentials: \(error.localizedDescription)")
            return nil
        }
    }
    
    public static func deleteCredentials() {
        try? FileManager.default.removeItem(at: credentialsURL)
        Logger.auth.info("Credentials deleted")
    }
    
    /// Get valid access token, refreshing if needed
    public static func getValidAccessToken() async throws -> String {
        guard var credentials = loadCredentials() else {
            throw AuthError.notLoggedIn
        }
        
        // Refresh if older than 1 hour
        if credentials.shouldRefresh(after: 3600) {
            credentials = try await refreshTokens(credentials)
        }
        
        return credentials.accessToken
    }
    
    /// Check if user is logged in (has valid credentials file)
    public static var isLoggedIn: Bool {
        loadCredentials() != nil
    }
}

// MARK: - Errors

public enum AuthError: LocalizedError {
    case notLoggedIn
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case missingAccountId
    case stateMismatch
    case missingCode
    
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to OpenAI. Please login first."
        case .tokenExchangeFailed(let message):
            return "Failed to exchange authorization code: \(message)"
        case .tokenRefreshFailed(let message):
            return "Failed to refresh token: \(message)"
        case .missingAccountId:
            return "Could not extract account ID from token"
        case .stateMismatch:
            return "OAuth state mismatch - possible security issue"
        case .missingCode:
            return "Missing authorization code"
        }
    }
}

// MARK: - Logger Extension

extension Logger {
    static let auth = Logger(subsystem: "app.monodo.speakflow", category: "auth")
}
