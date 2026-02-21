import Foundation
import OSLog

/// Tracks and persists usage statistics as a JSON file in `~/.speakflow/`.
///
/// Uses `Codable` for clean serialization, independent of UserDefaults and
/// bundle identifiers. The file is written atomically on every mutation to
/// avoid data loss.
@MainActor
public final class Statistics {
    public static let shared = Statistics()

    // MARK: - Persisted Data

    private struct Data: Codable {
        var totalSecondsTranscribed: Double = 0
        var totalCharacters: Int = 0
        var totalWords: Int = 0
        var totalApiCalls: Int = 0
    }

    private var data: Data

    private static let storageURL: URL = {
        let base: URL
        // Detect test runner: main bundle path contains .xctest, or xctest is in args
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
        if isTestRun {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("speakflow-test-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".speakflow")
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("statistics.json")
    }()

    private init() {
        if let fileData = try? Foundation.Data(contentsOf: Self.storageURL),
           let decoded = try? JSONDecoder().decode(Data.self, from: fileData) {
            data = decoded
        } else {
            data = Data()
        }
    }

    // MARK: - Public Counters

    public var totalSecondsTranscribed: Double { data.totalSecondsTranscribed }
    public var totalCharacters: Int { data.totalCharacters }
    public var totalWords: Int { data.totalWords }
    public var totalApiCalls: Int { data.totalApiCalls }

    /// Convenience aliases for automation/testing.
    public var apiCallCount: Int { data.totalApiCalls }
    public var wordCount: Int { data.totalWords }

    // MARK: - Dirty-flag debounce
    //
    // Previous: every mutation called `save()` immediately, performing a
    //   `JSONEncoder().encode()` + atomic `Data.write()` (two syscalls) per call.
    //   `Transcription.transcribe()` calls `recordApiCall()` then
    //   `recordTranscription()` on every chunk — so two disk flushes per chunk.
    //
    // Now: mutations mark the data dirty and schedule a 5-second flush Task.
    // Concurrent mutations within the same 5s window share one flush.
    // `save()` is called immediately only from `reset()` (to preserve the
    // zero-state on disk) and from `flushIfDirty()` on app background/terminate.
    //
    // Safety: `@MainActor` isolation means no race between `markDirty`,
    //   `scheduleFlush`, and `flushIfDirty`. The flush Task captures `[weak self]`
    //   so it doesn't prevent deallocation in tests.

    private var isDirty = false
    private var flushTask: Task<Void, Never>?

    /// Mark data as needing a flush and arm the debounce timer if not already armed.
    private func markDirty() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                self?.flushIfDirty()
                self?.flushTask = nil
            }
        }
    }

    /// Write to disk if dirty. Called by the debounce timer and at app lifecycle events.
    public func flushIfDirty() {
        guard isDirty else { return }
        isDirty = false
        save()
    }

    // MARK: - Recording

    public func recordTranscription(text: String, audioDurationSeconds: Double) {
        data.totalSecondsTranscribed += audioDurationSeconds
        data.totalCharacters += text.count

        let words = text.split(whereSeparator: { $0.isWhitespace })
        data.totalWords += words.count
        markDirty()

        Logger.app.debug("Stats updated: +\(String(format: "%.1f", audioDurationSeconds))s, +\(text.count) chars, +\(words.count) words")
    }

    public func recordApiCall() {
        data.totalApiCalls += 1
        markDirty()
    }

    public func reset() {
        flushTask?.cancel()
        flushTask = nil
        isDirty = false
        data = Data()
        save()
        Logger.app.info("Statistics reset")
    }

    // MARK: - Formatting

    @MainActor private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    @MainActor private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formatCount(_ value: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public var formattedDuration: String {
        let seconds = max(data.totalSecondsTranscribed, 0)
        if seconds == 0 { return String(localized: "0s") }
        return Self.durationFormatter.string(from: seconds) ?? String(localized: "0s")
    }

    public var formattedCharacters: String { formatCount(data.totalCharacters) }
    public var formattedWords: String { formatCount(data.totalWords) }
    public var formattedApiCalls: String { formatCount(data.totalApiCalls) }

#if DEBUG
    // swiftlint:disable:next identifier_name
    static var _testFormatterIdentity: ObjectIdentifier {
        ObjectIdentifier(decimalFormatter)
    }

    // swiftlint:disable:next identifier_name
    static func _testFormatCount(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
#endif

    // MARK: - Persistence

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.storageURL, options: .atomic)
        } catch {
            Logger.app.error("Failed to save statistics: \(error.localizedDescription)")
        }
    }
}

extension Statistics: StatisticsProviding {}
