import Foundation
import CryptoKit
import OSLog

/// OAuth credentials for ChatGPT transcription
public struct OAuthCredentials: Codable, Sendable {
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

/// Protocol abstracting URLSession's `data(for:)` for dependency injection in tests.
public protocol HTTPDataProvider: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataProvider {}

/// Actor that serializes token refresh operations so concurrent callers share a single in-flight refresh.
public actor TokenRefreshCoordinator {
    public static let shared = TokenRefreshCoordinator()

    private var inFlightRefresh: Task<OAuthCredentials, Error>?
    private let refreshFn: @Sendable (OAuthCredentials) async throws -> OAuthCredentials

    /// Create a coordinator.
    /// - Parameter refreshFn: The function used to refresh credentials.
    ///   Defaults to `OpenAICodexAuth.refreshTokens` but can be overridden in tests.
    public init(refreshFn: @escaping @Sendable (OAuthCredentials) async throws -> OAuthCredentials = { creds in
        try await OpenAICodexAuth.refreshTokens(creds)
    }) {
        self.refreshFn = refreshFn
    }

    /// Refresh tokens, coalescing concurrent callers into a single network request.
    /// If a refresh is already in flight, all callers await the same result.
    public func refreshIfNeeded(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        try await _refreshCore(credentials, counted: false)
    }

    /// Number of times a fresh refresh task was started (test observability).
    public private(set) var refreshStartCount = 0

    /// Variant that also increments the start counter (for tests).
    public func refreshIfNeededCounted(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        try await _refreshCore(credentials, counted: true)
    }

    /// Shared refresh implementation. Coalesces concurrent callers into a single
    /// in-flight task. When `counted` is true, increments `refreshStartCount`
    /// each time a *new* refresh is started (for test observability).
    private func _refreshCore(_ credentials: OAuthCredentials, counted: Bool) async throws -> OAuthCredentials {
        // If there's already a refresh in flight, join it
        if let existing = inFlightRefresh {
            return try await existing.value
        }

        if counted { refreshStartCount += 1 }

        // Start a new refresh
        let refreshFn = self.refreshFn
        let task = Task<OAuthCredentials, Error> {
            defer { self.clearInFlight() }
            return try await refreshFn(credentials)
        }
        inFlightRefresh = task
        return try await task.value
    }

    private func clearInFlight() {
        inFlightRefresh = nil
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

    /// HTTP data provider — defaults to `URLSession.shared`.
    /// Override in tests to inject a mock (e.g. one returning canned responses).
    /// - Important: Set this **only** in test setUp before any concurrent access.
    /// Protected by OSAllocatedUnfairLock to prevent data races on concurrent reads/writes.
    private static let _httpProviderLock = OSAllocatedUnfairLock<any HTTPDataProvider>(initialState: URLSession.shared)

    public static var httpProvider: any HTTPDataProvider {
        get { _httpProviderLock.withLock { $0 } }
        set { _httpProviderLock.withLock { $0 = newValue } }
    }
    
    private static let storage = UnifiedAuthStorage.shared
    
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
    
    // MARK: - Form Encoding

    /// Build an `application/x-www-form-urlencoded` body using strict encoding that is
    /// safe for opaque token values (e.g. values containing `&`, `=`, `+`).
    ///
    /// NOTE: `URLComponents.percentEncodedQuery` keeps `+` unescaped, but in
    /// form-encoded bodies `+` can be interpreted as space. We therefore encode
    /// with a stricter character set so literal `+` becomes `%2B`.
    static func formURLEncodedBody(_ params: [String: String]) -> Data {
        let encoded = params
            .sorted { $0.key < $1.key }
            .map { "\(formPercentEncode($0.key))=\(formPercentEncode($0.value))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static let formAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func formPercentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowedCharacters) ?? ""
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

        request.httpBody = formURLEncodedBody(params)
        
        let (data, response) = try await httpProvider.data(for: request)
        
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

        request.httpBody = formURLEncodedBody(params)
        
        let (data, response) = try await httpProvider.data(for: request)
        
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
    
    // MARK: - Credential Storage (delegated to UnifiedAuthStorage)

    public static func saveCredentials(_ credentials: OAuthCredentials) throws {
        try storage.saveChatGPTCredentials(credentials)
        Logger.auth.debug("Credentials saved")
    }

    public static func loadCredentials() -> OAuthCredentials? {
        storage.loadChatGPTCredentials()
    }

    public static func deleteCredentials() {
        storage.deleteChatGPTCredentials()
        Logger.auth.info("Credentials deleted")
    }
    
    /// Get valid access token, refreshing if needed.
    /// Concurrent callers share a single in-flight refresh via `TokenRefreshCoordinator`.
    public static func getValidAccessToken() async throws -> String {
        guard var credentials = loadCredentials() else {
            throw AuthError.notLoggedIn
        }
        
        // Refresh if older than 1 hour — coalesced so concurrent callers share one request
        if credentials.shouldRefresh(after: 3600) {
            credentials = try await TokenRefreshCoordinator.shared.refreshIfNeeded(credentials)
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
            return String(localized: "Not logged in to OpenAI. Please login first.")
        case .tokenExchangeFailed(let message):
            return String(localized: "Failed to exchange authorization code: \(message)")
        case .tokenRefreshFailed(let message):
            return String(localized: "Failed to refresh token: \(message)")
        case .missingAccountId:
            return String(localized: "Could not extract account ID from token")
        case .stateMismatch:
            return String(localized: "OAuth state mismatch - possible security issue")
        case .missingCode:
            return String(localized: "Missing authorization code")
        }
    }
}

