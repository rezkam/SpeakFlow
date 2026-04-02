import Foundation
import OSLog

/// Response from transcription API
struct TranscriptionResponse: Decodable {
    let text: String
}

/// Actor-based transcription service with async/await and automatic retry
public actor TranscriptionService {
    public static let shared = TranscriptionService()

    /// Truncate error response bytes before converting to a String.
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

    /// Kept for MistralBatchProvider which scales timeout by file size.
    /// ChatGPT now uses a flat per-attempt timeout (Config.requestTimeout).
    public static func timeout(forDataSize dataSize: Int) -> Double {
        guard dataSize > Config.baseTimeoutDataSize else {
            return Config.requestTimeout
        }
        let range = Double(Config.maxAudioSizeBytes - Config.baseTimeoutDataSize)
        let excess = Double(min(dataSize, Config.maxAudioSizeBytes) - Config.baseTimeoutDataSize)
        let scaled = Config.requestTimeout + (Config.maxTimeout - Config.requestTimeout) * (excess / range)
        return min(scaled, Config.maxTimeout)
    }

    /// Transcribe audio.
    ///
    /// Retry strategy — bounded total wall-clock time:
    ///   • Each attempt has a hard deadline of `Config.requestTimeout` (15s).
    ///     This is enforced by a task-group race so stalled HTTP responses
    ///     are cancelled promptly — URLRequest.timeoutInterval alone is not
    ///     reliable for server stalls that accept TCP but never send bytes.
    ///   • On timeout or network error, waits `Config.retryDelay` (1s) then
    ///     retries on a fresh connection (flat delay, not exponential, because
    ///     the failure mode is a stall not server overload).
    ///   • Total worst-case wall clock:
    ///       maxAttempts(3) × requestTimeout(15s) + (maxAttempts-1) × retryDelay(1s) = 47s
    ///   • Non-retryable errors (auth, 4xx, decode) fail on the first attempt.
    public func transcribe(audio: Data) async throws -> String {
        do { try await rateLimiter.waitAndRecord() }
        catch is CancellationError { throw TranscriptionError.cancelled }

        var lastError: Error?

        for attempt in 1...Config.maxAttempts {
            try Task.checkCancellation()

            do {
                return try await performRequestWithDeadline(audio: audio)
            } catch is CancellationError {
                throw TranscriptionError.cancelled
            } catch let err as TranscriptionError where !err.isRetryable {
                throw err
            } catch {
                lastError = error
                Logger.transcription.warning(
                    "ChatGPT attempt \(attempt)/\(Config.maxAttempts) failed: \(error.localizedDescription)"
                )
                if attempt < Config.maxAttempts {
                    Logger.transcription.debug("Retrying in \(Config.retryDelay)s…")
                    try? await Task.sleep(for: .seconds(Config.retryDelay))
                }
            }
        }

        throw lastError ?? TranscriptionError.networkError(underlying: URLError(.unknown))
    }

    // MARK: - Private

    /// Perform one attempt with a hard task-level deadline.
    ///
    /// The deadline races the URLSession request against a timer set to
    /// `Config.requestTimeout`. Whichever finishes first wins; the other is
    /// cancelled. This reliably kills stalled HTTP responses that never send
    /// bytes — URLRequest.timeoutInterval only fires on idle (no I/O), so
    /// a server that accepts the connection but stalls can hang indefinitely.
    private func performRequestWithDeadline(audio: Data) async throws -> String {
        let credentials = try await AuthCredentials.load()
        let request = try buildRequest(
            audio: audio,
            credentials: credentials,
            timeout: Config.requestTimeout
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask {
                    try await URLSession.shared.data(for: request)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Config.requestTimeout))
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
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
            // Truncate at the Data level to avoid materializing large error payloads.
            // multi-megabyte responses into memory before truncation
            let body = Self.truncateErrorBody(data, maxBytes: 200)
            throw TranscriptionError.httpError(statusCode: httpResponse.statusCode, body: body.isEmpty ? nil : body)
        }

        // Decode response
        do {
            let transcriptionResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return transcriptionResponse.text
        } catch let decodingError as DecodingError {
            throw TranscriptionError.decodingFailed(underlying: decodingError)
        }
    }

    /// Build the multipart form request
    private func buildRequest(audio: Data, credentials: AuthCredentials, timeout: Double = Config.timeout) throws -> URLRequest {
        // Enforce a hard audio-size cap to avoid memory pressure from oversized uploads.
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
    // swiftlint:disable:next identifier_name
    func _testBuildRequest(
        audio: Data,
        credentials: AuthCredentials,
        timeout: Double = Config.timeout
    ) throws -> URLRequest {
        try buildRequest(audio: audio, credentials: credentials, timeout: timeout)
    }
}
#endif

extension TranscriptionService: TranscriptionServiceProviding {}
