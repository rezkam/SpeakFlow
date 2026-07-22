import OSLog

/// Logging levels used by provider components.
public enum ProviderLogLevel: Sendable, Equatable {
    case debug
    case info
    case warning
    case error
}

/// Visibility applied to provider log messages.
public enum ProviderLogVisibility: Sendable, Equatable {
    case `public`
    case privateHash
}

/// Injectable logging boundary for provider components that process transcript data.
public protocol ProviderLogging: Sendable {
    func log(_ message: String, level: ProviderLogLevel, visibility: ProviderLogVisibility)
}

/// Production adapter that preserves OSLog categories and privacy treatment.
public struct OSLogProviderLogger: ProviderLogging, Sendable {
    private let logger: Logger

    public init(category: String) {
        self.logger = Logger(subsystem: "SpeakFlow", category: category)
    }

    public func log(_ message: String, level: ProviderLogLevel, visibility: ProviderLogVisibility) {
        switch visibility {
        case .public:
            logPublic(message, level: level)
        case .privateHash:
            logPrivateHash(message, level: level)
        }
    }

    private func logPublic(_ message: String, level: ProviderLogLevel) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    private func logPrivateHash(_ message: String, level: ProviderLogLevel) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .private(mask: .hash))")
        case .info: logger.info("\(message, privacy: .private(mask: .hash))")
        case .warning: logger.warning("\(message, privacy: .private(mask: .hash))")
        case .error: logger.error("\(message, privacy: .private(mask: .hash))")
        }
    }
}
