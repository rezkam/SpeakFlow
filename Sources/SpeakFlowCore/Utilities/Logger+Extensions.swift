import OSLog

// MARK: - Structured Logging
public extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.monodo.speakflow"

    /// Audio recording and processing
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Transcription API and queue
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    /// Accessibility and microphone permissions
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Hotkey detection and handling
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    /// General app lifecycle
    static let app = Logger(subsystem: subsystem, category: "app")
}
