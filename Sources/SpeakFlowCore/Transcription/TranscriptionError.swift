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
}
