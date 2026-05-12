import Foundation
import OSLog

public struct HotkeyDiagnosticEvent: Equatable, Sendable {
    public let name: String
    public let level: ObservabilityEventLevel
    public let metadata: [String: String]

    public init(
        name: String,
        level: ObservabilityEventLevel,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.level = level
        self.metadata = metadata
    }
}

public enum HotkeyDiagnostics {
    #if DEBUG
    // swiftlint:disable:next identifier_name
    public nonisolated(unsafe) static var _testEventHook: ((HotkeyDiagnosticEvent) -> Void)?
    #endif

    public static func record(
        _ name: String,
        level: ObservabilityEventLevel = .info,
        metadata: [String: String] = [:]
    ) {
        let event = HotkeyDiagnosticEvent(name: name, level: level, metadata: metadata)
        log(event)

        #if DEBUG
        _testEventHook?(event)
        #endif

        Task {
            await ObservabilityStore.shared.record(
                component: "Hotkey",
                name: name,
                level: level,
                metadata: metadata
            )
        }
    }

    private static func log(_ event: HotkeyDiagnosticEvent) {
        let metadata = metadataDescription(event.metadata)
        switch event.level {
        case .error:
            Logger.hotkey.error("\(event.name, privacy: .public) \(metadata, privacy: .public)")
        case .warning:
            Logger.hotkey.warning("\(event.name, privacy: .public) \(metadata, privacy: .public)")
        case .info:
            Logger.hotkey.info("\(event.name, privacy: .public) \(metadata, privacy: .public)")
        case .debug:
            Logger.hotkey.debug("\(event.name, privacy: .public) \(metadata, privacy: .public)")
        }
    }

    private static func metadataDescription(_ metadata: [String: String]) -> String {
        metadata
            .map { key, value in "\(key)=\(value)" }
            .sorted()
            .joined(separator: " ")
    }
}
