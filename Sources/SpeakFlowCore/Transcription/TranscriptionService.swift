import Foundation
import OSLog

/// Response from transcription API
struct TranscriptionResponse: Decodable {
    let text: String
}

/// Actor-based transcription service with async/await and automatic retry
public actor TranscriptionService {
    public static let shared = TranscriptionService()

    /// P2 Security: Truncate error body Data before converting to String
    /// This prevents loading multi-megabyte error responses into memory
    public static func truncateErrorBody(_ data: Data, maxBytes: Int = 200) -> String {
        if data.count <= maxBytes {
            return String(data: data, encoding: .utf8) ?? ""
        }
        // Truncate at Data level to avoid loading full string into memory
        let truncatedData = data.prefix(maxBytes)
        let truncatedString = String(data: truncatedData, encoding: .utf8) ?? ""
        return truncatedString + "..."
    }

    private let rateLimiter = RateLimiter()
    private var activeTasks: [Int: Task<String, Error>] = [:]

    /// Transcribe audio with automatic retry and rate limiting
    public func transcribe(audio: Data) async throws -> String {
        // Wait for rate limit
        await rateLimiter.waitIfNeeded()
        await rateLimiter.recordRequest()

        // Perform request with retry
        return try await withRetry(maxAttempts: Config.maxRetries) {
            try await self.performRequest(audio: audio)
        }
    }

    /// Cancel all active transcription tasks
    func cancelAll() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    // MARK: - Private Methods

    /// Retry helper with exponential backoff and jitter
    private func withRetry<T>(
        maxAttempts: Int,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                // Check for cancellation before each attempt
                try Task.checkCancellation()
                return try await operation()
            } catch is CancellationError {
                throw TranscriptionError.cancelled
            } catch let error as TranscriptionError where !error.isRetryable {
                // Non-retryable errors fail immediately
                throw error
            } catch {
                lastError = error
                Logger.transcription.warning("Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")

                if attempt < maxAttempts {
                    // Exponential backoff with jitter
                    let baseDelay = Config.retryBaseDelay * pow(2.0, Double(attempt - 1))
                    let jitter = Double.random(in: 0...0.5) * baseDelay
                    let delay = baseDelay + jitter

                    Logger.transcription.debug("Retrying in \(String(format: "%.1f", delay))s...")
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }

        throw lastError ?? TranscriptionError.networkError(underlying: URLError(.unknown))
    }

    /// Perform the actual network request
    private func performRequest(audio: Data) async throws -> String {
        let credentials = try AuthCredentials.load()
        let request = try buildRequest(audio: audio, credentials: credentials)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            throw TranscriptionError.networkError(underlying: urlError)
        } catch {
            throw TranscriptionError.networkError(underlying: error)
        }

        // Validate HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse(data: data)
        }

        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw TranscriptionError.rateLimited(retryAfter: retryAfter)
        }

        // Validate status code
        guard (200...299).contains(httpResponse.statusCode) else {
            // P2 Security: Truncate error body at Data level to prevent loading
            // multi-megabyte responses into memory before truncation
            let body = Self.truncateErrorBody(data, maxBytes: 200)
            throw TranscriptionError.httpError(statusCode: httpResponse.statusCode, body: body.isEmpty ? nil : body)
        }

        // Decode response
        do {
            let transcriptionResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return transcriptionResponse.text
        } catch let decodingError as DecodingError {
            // Try legacy format (plain JSON object with "text" key)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text
            }
            throw TranscriptionError.decodingFailed(underlying: decodingError)
        }
    }

    /// Build the multipart form request
    private func buildRequest(audio: Data, credentials: AuthCredentials) throws -> URLRequest {
        // P0 Security: Validate audio size to prevent memory exhaustion and DoS
        guard audio.count <= Config.maxAudioSizeBytes else {
            let sizeMB = Double(audio.count) / 1_000_000
            let maxMB = Double(Config.maxAudioSizeBytes) / 1_000_000
            Logger.transcription.error("Audio too large: \(String(format: "%.1f", sizeMB))MB > \(String(format: "%.0f", maxMB))MB limit")
            throw TranscriptionError.audioTooLarge(size: audio.count, maxSize: Config.maxAudioSizeBytes)
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/transcribe") else {
            throw TranscriptionError.authenticationFailed(reason: "Invalid URL")
        }

        let boundary = "----SwiftBoundary\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.timeout

        // Headers
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("Codex Desktop/260202.0859 (darwin; arm64)", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if !credentials.cookies.isEmpty {
            // P1 Security: Sanitize cookie values to prevent header injection
            let cookieString = credentials.cookies.compactMap { key, value -> String? in
                // Remove any CR/LF that could inject headers
                let safeKey = key.replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: ";", with: "")
                let safeValue = value.replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: ";", with: "")
                // P1 Fix: Skip cookies with empty key or value to avoid malformed headers
                guard !safeKey.isEmpty, !safeValue.isEmpty else { return nil }
                return "\(safeKey)=\(safeValue)"
            }.joined(separator: "; ")
            if !cookieString.isEmpty {
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            }
        }

        // Build multipart body (using Data(_:) for ASCII-safe strings)
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body
        return request
    }
}
