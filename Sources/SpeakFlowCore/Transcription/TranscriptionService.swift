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

    /// Compute timeout scaled to audio data size.
    ///
    /// Small files (≤ `baseTimeoutDataSize`, ~480KB / ~15s) use the base 10s timeout.
    /// Larger files scale linearly up to `maxTimeout` (30s) at `maxAudioSizeBytes` (25MB).
    /// This keeps short chunks snappy while giving large uploads enough time.
    ///
    /// Formula (above threshold):
    ///   timeout = base + (max - base) × (size - baseSize) / (maxSize - baseSize)
    public static func timeout(forDataSize dataSize: Int) -> Double {
        guard dataSize > Config.baseTimeoutDataSize else {
            return Config.timeout
        }
        let range = Double(Config.maxAudioSizeBytes - Config.baseTimeoutDataSize)
        let excess = Double(min(dataSize, Config.maxAudioSizeBytes) - Config.baseTimeoutDataSize)
        let scaled = Config.timeout + (Config.maxTimeout - Config.timeout) * (excess / range)
        return min(scaled, Config.maxTimeout)
    }

    /// Transcribe audio with automatic retry and rate limiting
    public func transcribe(audio: Data) async throws -> String {
        // Wait for rate limit and record request atomically
        do {
            try await rateLimiter.waitAndRecord()
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        }

        let requestTimeout = Self.timeout(forDataSize: audio.count)

        // Perform request with retry
        return try await withRetry(maxAttempts: Config.maxRetries) {
            try await self.performRequest(audio: audio, timeout: requestTimeout)
        }
    }

    // MARK: - Private Methods

    /// Retry helper with exponential backoff and jitter
    private func withRetry<T: Sendable>(
        maxAttempts: Int,
        operation: @Sendable @escaping () async throws -> T
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
    private func performRequest(audio: Data, timeout: Double = Config.timeout) async throws -> String {
        let credentials = try await AuthCredentials.load()
        let request = try buildRequest(audio: audio, credentials: credentials, timeout: timeout)

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
    private func buildRequest(audio: Data, credentials: AuthCredentials, timeout: Double = Config.timeout) throws -> URLRequest {
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
        request.timeoutInterval = timeout

        // Headers
        // Headers matching Codex Desktop exactly
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        
        // User-Agent format matching Codex Desktop: Codex Desktop/{version} ({platform}; {arch})
        var utsname = utsname()
        uname(&utsname)
        let machine = withUnsafePointer(to: &utsname.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        // Use Codex Desktop version format (YYMMDD.HHMM)
        let codexVersion = "260205.1301"
        request.setValue("Codex Desktop/\(codexVersion) (darwin; \(machine))", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

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

#if DEBUG
extension TranscriptionService {
    /// Test seam for validating request construction behavior without real network calls.
    func _testBuildRequest(
        audio: Data,
        credentials: AuthCredentials,
        timeout: Double = Config.timeout
    ) throws -> URLRequest {
        try buildRequest(audio: audio, credentials: credentials, timeout: timeout)
    }
}
#endif
