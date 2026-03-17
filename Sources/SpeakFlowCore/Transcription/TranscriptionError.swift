import Foundation

/// Errors that can occur during transcription
public enum TranscriptionError: Error, LocalizedError {
    case authenticationFailed(reason: String)
    case networkError(underlying: Error)
    case invalidResponse(data: Data?)
    case httpError(statusCode: Int, body: String?)
    case decodingFailed(underlying: Error)
    case rateLimited(retryAfter: TimeInterval?)
    case cancelled
    case audioTooLarge(size: Int, maxSize: Int)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body ?? "Unknown error")"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .rateLimited(let retryAfter):
            if let delay = retryAfter {
                return "Rate limited, retry after \(delay)s"
            }
            return "Rate limited"
        case .cancelled:
            return "Request cancelled"
        case .audioTooLarge(let size, let maxSize):
            let sizeMB = Double(size) / 1_000_000
            let maxMB = Double(maxSize) / 1_000_000
            return String(format: "Audio too large (%.1fMB > %.0fMB limit)", sizeMB, maxMB)
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .networkError:
            return true
        case .rateLimited:
            return true
        case .httpError(let code, _):
            // Retry on server errors (5xx)
            return code >= 500
        default:
            return false
        }
    }

    /// Whether this error indicates an authentication or authorization failure.
    /// Used to show targeted user guidance (e.g. "re-login" or "check API key").
    public var isAuthenticationError: Bool {
        switch self {
        case .authenticationFailed:
            return true
        case .httpError(let code, _):
            return code == 401 || code == 403
        default:
            return false
        }
    }
}

// MARK: - Transcription Error Classification

/// Classifies any transcription error for user-facing messaging.
/// Works across all provider error types (TranscriptionError, MistralBatchError, DeepgramError, etc.)
public enum TranscriptionErrorKind: Sendable {
    /// Authentication or authorization failure — user needs to re-login or check API key
    case authentication
    /// Rate limited — user should wait and try again
    case rateLimited
    /// Network connectivity issue
    case network
    /// Any other error
    case other

    /// Classify an arbitrary error from any transcription provider.
    public static func classify(_ error: Error) -> TranscriptionErrorKind {
        // TranscriptionError (ChatGPT batch provider)
        if let te = error as? TranscriptionError {
            if te.isAuthenticationError { return .authentication }
            if case .rateLimited = te { return .rateLimited }
            if case .networkError = te { return .network }
            return .other
        }

        // Check for HTTP status codes embedded in localized descriptions as a fallback
        // for provider-specific error types (MistralBatchError, DeepgramError, etc.)
        let desc = error.localizedDescription
        if desc.contains("401") || desc.contains("403")
            || desc.localizedCaseInsensitiveContains("authentication failed")
            || desc.localizedCaseInsensitiveContains("not configured") {
            return .authentication
        }
        if desc.contains("429") || desc.localizedCaseInsensitiveContains("rate limit") {
            return .rateLimited
        }
        if desc.localizedCaseInsensitiveContains("network error") {
            return .network
        }

        return .other
    }
}
