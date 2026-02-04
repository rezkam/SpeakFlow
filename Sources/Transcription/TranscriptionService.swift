import Foundation
import OSLog

/// Response from transcription API
struct TranscriptionResponse: Decodable {
    let text: String
}

/// Actor-based transcription service with async/await and automatic retry
actor TranscriptionService {
    static let shared = TranscriptionService()

    private let rateLimiter = RateLimiter()
    private var activeTasks: [Int: Task<String, Error>] = [:]

    /// Transcribe audio with automatic retry and rate limiting
    func transcribe(audio: Data) async throws -> String {
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
            let body = String(data: data, encoding: .utf8)
            throw TranscriptionError.httpError(statusCode: httpResponse.statusCode, body: body)
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
            let cookieString = credentials.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
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
