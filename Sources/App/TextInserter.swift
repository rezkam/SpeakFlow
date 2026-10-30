import AppKit
import ApplicationServices
import OSLog
import SpeakFlowCore

/// Queues and delivers text to the captured UI element via Unicode text bursts or paced CGEvent typing.
///
/// This component handles all text insertion operations by:
/// - Capturing the currently focused accessibility element before recording starts
/// - Waiting for the user to return focus to the captured element before each operation
/// - Serializing all text operations (insertions, deletions, Enter key) into a task queue
/// - Synthesizing keystrokes character-by-character using CGEvent Unicode strings
/// - Waiting for modifier keys to be released to prevent corruption
///
/// **Focus Protection:** If the user switches apps during transcription, each queued
/// operation pauses and waits for the user to return to the target app voluntarily
/// (never steals focus). If the user doesn't return within the configured
/// `focusWaitTimeout`, pending operations are discarded to avoid blocking forever.
///
/// **Thread Safety:** All public methods are `@MainActor` and maintain a serial task queue.
/// Each operation awaits the queue tail before executing, ensuring ordered text output.
@MainActor
final class TextInserter: TextInserting {
    static let shared = TextInserter()

    // MARK: - Configuration Constants

    /// Maximum characters that can be inserted in a single operation (safety limit).
    /// 
    /// Calculation basis (engineering-safe estimates):
    /// - Average speaking rate: ~150 words/minute (conversational English)
    ///   - Range: 120-180 wpm depending on speaker and context
    ///   - Source: Typical presentation/conversation rates
    /// - Average characters per word: ~6 chars (including spaces & punctuation)
    ///   - Breakdown: ~4.7 letter average + ~1 space + ~0.3 punctuation
    ///   - Conservative estimate; dense technical speech may reach 7+ chars/word
    /// - Expected character rate: ~900 characters/minute (150 × 6)
    ///   - Fast/dense speech: up to ~1,050 chars/min (150 × 7)
    /// - Target capacity: 1 hour maximum session = ~54,000 characters nominal
    ///
    /// Capacity analysis for 1-hour limit:
    /// - 10-minute chunks: ~9,000 chars nominal (9% of limit)
    /// - 1-hour full recording: ~54,000 chars nominal (54% of limit)
    /// - 1-hour streaming session: ~54,000 chars nominal (54% of limit)
    /// - Fast/dense speakers (7 chars/word): ~63,000 chars (63% of limit)
    ///
    /// The 100K limit provides ~1.85× safety margin over expected 1-hour usage
    /// at normal speaking rates, or ~1.6× margin for fast/dense speech. This
    /// prevents excessive memory usage from malformed transcriptions while
    /// accommodating edge cases without truncation.
    private static let maxTextInsertionLength = 100_000

    /// Delay in microseconds between individual keystrokes (8.5ms).
    /// This gives editors and browser-based inputs more time to settle layout,
    /// selection, and internal input state between synthesized key events.
    /// The value stays slower than the old 5ms cadence that could trigger caret
    /// jumps, but avoids the visibly sluggish 12ms RC cadence.
    private static let keystrokeDelayMicroseconds: UInt32 = 8_500

    /// Delay in nanoseconds between modifier key release checks (10ms).
    /// When detecting if Cmd/Ctrl/Option/Shift are released, we poll
    /// with this interval to avoid busy-waiting.
    private static let modifierCheckDelayNanoseconds: UInt64 = 10_000_000

    /// Maximum attempts to wait for modifier keys to be released.
    /// At 10ms per attempt, 100 attempts = 1 second maximum wait.
    /// This prevents infinite loops if a modifier key is stuck.
    private static let maxModifierReleaseAttempts = 100

    /// Virtual key code for the Delete key (backspace on macOS).
    private static let deleteKeyCode: CGKeyCode = 51

    /// Virtual key code for the Enter/Return key.
    private static let enterKeyCode: CGKeyCode = 36

    /// Delay in nanoseconds for the Enter key up event (10ms).
    /// Separating key-down and key-up events ensures proper registration.
    private static let enterKeyDelayNanoseconds: UInt64 = 10_000_000

    // MARK: - State

    /// The UI element that had focus when recording started.
    var targetElement: AXUIElement?

    /// PID of the app that owned the target element when recording started.
    /// Used for reliable app-level focus comparison (CFEqual on AXUIElements
    /// is unreliable across time — the same element can return different refs).
    var targetPid: pid_t = 0

    /// Bundle identifier of the target app captured at recording start.
    ///
    /// Some apps route focused UI through helper processes (for example
    /// `com.vendor.App.helper`). In those cases, AX focused PID can differ from
    /// the main app PID even when the user is still in the same app.
    private var targetBundleIdentifier: String?
    private var targetApplicationURL: URL?

    /// Test-only override for `isTargetAppFrontmost()`.
    ///
    /// Set to `true` or `false` in unit tests to produce a deterministic result
    /// without depending on the live system frontmost-application state.
    /// Defaults to `nil` (production behavior).
    var testIsTargetFrontmost: Bool?

    /// Source of current modifier-key flags, consulted before each synthetic key pair.
    /// Defaults to live hardware state;
    /// tests inject a scripted sequence (see `_testSetFlagsProvider`) so the
    /// real insertion paths can be driven deterministically.
    private var flagsProvider: () -> CGEventFlags = { TextInserter.currentHardwareModifierFlags() }

    /// Sink that actually posts a synthetic `CGEvent` to the system. Defaults
    /// to the real `CGEvent.post(tap:)`. Tests replace this with a recorder
    /// (see `_testSetEventPoster`) so the modifier-safety gate can be
    /// exercised end-to-end without emitting real OS events.
    private var eventPoster: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    /// Reports where keyboard focus is relative to the captured target; nil
    /// when Accessibility cannot answer. Tests inject a deterministic observer.
    private var focusObserver: ((TextInserter) -> FocusObservation?)?
    private var focusWaitTimeoutProvider: () -> Double = { Settings.shared.focusWaitTimeout }

    /// Why the last focus check failed, recorded when typing pauses.
    private var lastFocusMismatch = "otherApp"

    /// Window of the captured field, used when the field itself cannot answer.
    private var targetWindow: AXUIElement?

    /// Liveness check for the captured target process. Production uses AppKit;
    /// tests inject a deterministic process identity without requiring a GUI app.
    private var isTargetProcessRunning: (pid_t) -> Bool = {
        NSRunningApplication(processIdentifier: $0) != nil
    }

    /// The current task chain for text operations.
    /// Each new operation creates a task that awaits this one, forming a serial queue.
    private var textInsertionTask: Task<Void, Never>?

    /// Number of operations currently queued.
    /// Bounded by `Config.maxQueuedTextInsertions` to prevent unbounded memory growth.
    private var queuedInsertionCount = 0
    private var queueGeneration: UInt64 = 0
    private var streamingCommittedText = ""
    private var streamingPostedText = ""
    private var pendingStreamingSnapshot: String?
    private var streamingReconciliationQueued = false
    /// Monotonic operation sequence used to correlate queued text actions.
    private var operationSequence: UInt64 = 0
    private var observabilitySessionId: UUID?

    struct EditorSnapshot: Equatable {
        var text: String
        var selection: NSRange
    }

    var editorSnapshotForTesting: (() -> EditorSnapshot?)?
    private var bulkDeliveryFailed = false
    var onBulkInsertionFailure: (() -> Void)?
    var onDeliveryFailure: (() -> Void)?
    private var streamingActive = false
    private var streamingDeliveryFailed = false
    private var streamingDesiredText = ""

    private func editorSnapshot() -> EditorSnapshot? {
        if let editorSnapshotForTesting { return editorSnapshotForTesting() }
        guard let targetElement else { return nil }
        var value: CFTypeRef?
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(targetElement, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(targetElement, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(selection, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
        return EditorSnapshot(text: text, selection: NSRange(location: range.location, length: range.length))
    }

    private func refuseStreamingDelivery() {
        guard !streamingDeliveryFailed else { return }
        streamingDeliveryFailed = true
        onDeliveryFailure?()
        observabilityEvent("streaming_delivery_unverified", level: .warning)
    }

    private var captureAccessibility = TargetCaptureAccessibility.live

    private init() {}

    private func observabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .debug,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        let settings = Settings.shared
        guard settings.observabilityEnabled,
              settings.observabilityVerbosity.includes(level) else { return }
        let payload = metadata()
        Task {
            await ObservabilityStore.shared.record(
                component: "TextInserter",
                name: name,
                level: level,
                sessionId: self.observabilitySessionId,
                metadata: payload
            )
        }
    }

    private func nextOperationId() -> UInt64 {
        operationSequence &+= 1
        return operationSequence
    }

    private func metadataForTextPayload(_ text: String) -> [String: String] {
        var metadata: [String: String] = [
            "textChars": String(text.count),
            "textFingerprint": ObservabilityFingerprint.sha256(text)
        ]
        if Settings.shared.observabilityCaptureTextPayloads {
            metadata["text"] = text
        }
        return metadata
    }

    func setObservabilitySessionId(_ sessionId: UUID?) {
        observabilitySessionId = sessionId
    }

    // MARK: - Target Capture

    /// Captures the currently focused UI element and its app PID.
    ///
    /// Call this immediately before starting recording to establish which
    /// app should receive transcribed text. Before each text operation,
    /// `ensureTargetFocused()` checks that the same app is still frontmost
    /// and waits (up to `focusWaitTimeout`) if the user has switched away.
    ///
    /// If no element has focus or accessibility permissions are denied, clears
    /// the target and returns false. Without a target every synthetic action
    /// fails closed, so callers must not start a recording.
    #if DEBUG
    var captureTargetForTesting: (() -> Bool)?
    #endif

    @discardableResult
    func captureTarget() -> Bool {
        #if DEBUG
        if let captureTargetForTesting { return captureTargetForTesting() }
        #endif
        let originalPid = captureAccessibility.frontmostPid()
        if let pid = originalPid, pid > 0 {
            let activationStatus = captureAccessibility.prepareApplication(pid)
            observabilityEvent(
                "target_accessibility_activation_requested",
                metadata: ["status": String(activationStatus.rawValue)]
            )
        }
        let (status, focusedElement) = captureAccessibility.systemFocus()
        if status == .success, let axElement = focusedElement,
           let pid = captureAccessibility.processId(axElement), pid > 0 {
            if let originalPid {
                guard captureAccessibility.frontmostPid() == originalPid else {
                    return refuseTargetCapture(reason: "focus_changed", status: status)
                }
                guard captureAccessibility.sameApplication(originalPid, pid) else {
                    return refuseTargetCapture(reason: "foreign_owner", status: status)
                }
            }
            AXUIElementSetMessagingTimeout(axElement, Self.fieldQueryTimeoutSeconds)
            targetElement = axElement
            targetWindow = captureAccessibility.window(axElement)
            targetPid = pid
            targetBundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            targetApplicationURL = ApplicationOwnership.applicationURL(for: pid)
            return true
        }
        return refuseTargetCapture(reason: "focused_element_unavailable", status: status)
    }

    private func refuseTargetCapture(reason: String, status: AXError) -> Bool {
        targetElement = nil
        targetWindow = nil
        targetPid = 0
        targetBundleIdentifier = nil
        targetApplicationURL = nil
        observabilityEvent(
            "target_capture_failed", level: .warning,
            metadata: ["reason": reason, "status": String(status.rawValue)]
        )
        return false
    }

    // MARK: - Text Operations

    /// Provider diffs describe intent, not delivery. Compute the actual correction
    /// only when this snapshot reaches the queue head, using posted key pairs.
    func updateStreamingText(_ text: String, isFinal: Bool) {
        adoptClearedFieldAfterCompletedSegment()
        streamingActive = true
        let segment = sanitizeTextForInsertion(text)
        let desired = streamingCommittedText + segment + (isFinal && !segment.isEmpty ? " " : "")
        if isFinal { streamingCommittedText = desired }
        streamingDesiredText = desired
        pendingStreamingSnapshot = desired
        guard !streamingReconciliationQueued else { return }
        // One dedicated worker and one latest-snapshot slot stay bounded even when
        // the ordinary insertion queue is full. Never drop the terminal snapshot.
        streamingReconciliationQueued = true
        let operationId = nextOperationId()
        let generation = queueGeneration
        let previousTask = textInsertionTask
        textInsertionTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.queueGeneration == generation {
                    self.streamingReconciliationQueued = false
                }
            }
            await previousTask?.value
            guard let self else { return }
            while self.queueGeneration == generation, !Task.isCancelled,
                  let desired = self.pendingStreamingSnapshot {
                self.pendingStreamingSnapshot = nil
                let common = zip(self.streamingPostedText, desired).prefix { $0 == $1 }.count
                let deleteCount = self.streamingPostedText.count - common
                if deleteCount > 0 {
                    let completed = await self.deleteCharsAsync(
                        deleteCount, operationId: operationId, generation: generation,
                        onCharacterDeleted: { [weak self] in
                            guard let self, self.queueGeneration == generation else { return }
                            self.streamingPostedText.removeLast()
                        }
                    )
                    guard completed else { return }
                }
                await self.typeTextAsync(
                    String(desired.dropFirst(common)), operationId: operationId, generation: generation,
                    onCharacterPosted: { [weak self] character in
                        guard let self, self.queueGeneration == generation else { return }
                        self.streamingPostedText.append(character)
                    }
                )
            }
        }
    }

    private func adoptClearedFieldAfterCompletedSegment() {
        // Clearing a settled utterance retires its text, not the next utterance.
        // Never rebase while a key or provider revision may still be in flight.
        guard !streamingDeliveryFailed, !streamingReconciliationQueued,
              pendingStreamingSnapshot == nil, queuedInsertionCount == 0,
              !streamingPostedText.isEmpty, streamingPostedText == streamingCommittedText,
              isTargetAppFrontmost(), let current = editorSnapshot(),
              current.text.isEmpty, current.selection == NSRange(location: 0, length: 0) else { return }
        streamingCommittedText = ""
        streamingPostedText = ""
        streamingDesiredText = ""
    }

    /// Queues an atomic tail replacement (delete then type) as a single queue item.
    ///
    /// This prevents split queue-drop behavior where deletion is accepted but the
    /// matching insertion is dropped under queue pressure (or vice versa), which can
    /// corrupt streaming interim correction order.
    func replaceTail(replacingChars: Int, with text: String) {
        let textToInsert = sanitizeTextForInsertion(text)
        guard replacingChars > 0 || !textToInsert.isEmpty else { return }
        let operationId = nextOperationId()
        guard queuedInsertionCount < Config.maxQueuedTextInsertions else {
            observabilityEvent(
                "replace_tail_dropped_queue_full",
                level: .warning,
                metadata: [
                    "operationId": String(operationId),
                    "queuedInsertionCount": String(queuedInsertionCount)
                ]
            )
            return
        }
        observabilityEvent(
            "replace_tail_queued",
            metadata: [
                "operationId": String(operationId),
                "replacingChars": String(replacingChars),
                "queueDepthBefore": String(queuedInsertionCount)
            ]
            .merging(metadataForTextPayload(textToInsert), uniquingKeysWith: { _, new in new })
        )

        queuedInsertionCount += 1
        let generation = queueGeneration
        let previousTask = textInsertionTask

        textInsertionTask = Task { @MainActor [weak self] in
            defer {
                self?.decrementQueuedInsertionCount(for: generation)
            }
            await previousTask?.value
            guard let self else { return }

            if replacingChars > 0 {
                let deleted = await self.deleteCharsAsync(
                    replacingChars, operationId: operationId, generation: generation
                )
                guard deleted else { return }
            }
            if !textToInsert.isEmpty {
                await self.typeTextAsync(textToInsert, operationId: operationId, generation: generation)
            }
        }
    }

    /// Queues completed batch text in Unicode bursts without clipboard access or typing delays.
    func insertTextInBulk(_ text: String) {
        let text = sanitizeTextForInsertion(text)
        guard !text.isEmpty, !bulkDeliveryFailed else { return }
        guard queuedInsertionCount < Config.maxQueuedTextInsertions else {
            refuseBulkDelivery()
            return
        }
        queuedInsertionCount += 1
        let generation = queueGeneration
        let previousTask = textInsertionTask
        textInsertionTask = Task { @MainActor [weak self] in
            defer { self?.decrementQueuedInsertionCount(for: generation) }
            await previousTask?.value
            guard let self, self.isCurrent(generation), !Task.isCancelled,
                  !self.bulkDeliveryFailed else { return }
            await self.insertBatchText(text, generation: generation)
        }
    }

    private func refuseBulkDelivery() {
        guard !bulkDeliveryFailed else { return }
        bulkDeliveryFailed = true
        observabilityEvent("bulk_insertion_failed", level: .warning)
        onBulkInsertionFailure?()
    }

    private func insertBatchText(_ text: String, generation: UInt64) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            refuseBulkDelivery()
            return
        }
        let chunks = BatchTextPayload.chunks(text)
        for (index, chunk) in chunks.enumerated() {
            guard isCurrent(generation), !Task.isCancelled else { return }
            guard await ensureTargetFocused(generation: generation) else {
                if isCurrent(generation), !Task.isCancelled { refuseBulkDelivery() }
                return
            }
            // Space supplies a neutral backing key; the Unicode payload carries the text.
            // Never turn embedded line breaks into synthetic Return or Tab keys.
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false) else {
                refuseBulkDelivery()
                return
            }
            var units = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.flags = []
            up.flags = []
            guard await postGuardedKeyPair(down, up, generation: generation) else {
                if isCurrent(generation), !Task.isCancelled { refuseBulkDelivery() }
                return
            }
            if index + 1 < chunks.count {
                // Let input queues drain and cancellation/focus changes run between bursts.
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        if isCurrent(generation), !Task.isCancelled {
            observabilityEvent("bulk_insertion_posted")
        }
    }

    /// Queues text for insertion into the focused element.
    ///
    /// The text is sanitized to allow only letters, numbers, punctuation, symbols,
    /// whitespace, newlines, and tabs. Characters outside these categories are
    /// removed to prevent control sequences or invalid Unicode from corrupting
    /// the insertion pipeline.
    ///
    /// Operations are serialized: this call creates a new `Task` that awaits the
    /// previous operation before typing. If the queue is full (exceeds
    /// `Config.maxQueuedTextInsertions`), the text is silently dropped to prevent
    /// unbounded memory growth during rapid transcription.
    ///
    /// - Parameter text: The transcribed text to insert. Will be sanitized and truncated
    ///   if longer than `maxTextInsertionLength`.
    func insertText(_ text: String) {
        let textToInsert = sanitizeTextForInsertion(text)
        let operationId = nextOperationId()

        // Ignore empty text or if queue is full
        guard !textToInsert.isEmpty else {
            return
        }
        guard queuedInsertionCount < Config.maxQueuedTextInsertions else {
            observabilityEvent(
                "insert_text_dropped_queue_full",
                level: .warning,
                metadata: [
                    "operationId": String(operationId),
                    "queuedInsertionCount": String(queuedInsertionCount)
                ]
            )
            return
        }

        observabilityEvent(
            "insert_text_queued",
            metadata: [
                "operationId": String(operationId),
                "queueDepthBefore": String(queuedInsertionCount)
            ]
            .merging(metadataForTextPayload(textToInsert), uniquingKeysWith: { _, new in new })
        )
        queuedInsertionCount += 1
        let generation = queueGeneration
        let previousTask = textInsertionTask

        // Chain this insertion after the previous operation
        textInsertionTask = Task { @MainActor [weak self] in
            defer {
                self?.decrementQueuedInsertionCount(for: generation)
            }
            await previousTask?.value
            await self?.typeTextAsync(textToInsert, operationId: operationId, generation: generation)
        }
    }

    /// Queues deletion of the specified number of characters.
    ///
    /// Sends Delete (Backspace) key events to remove characters from the end
    /// of the text field. Each deletion is a separate key-down/key-up pair
    /// with a small delay between deletions to ensure the receiving application
    /// processes them correctly.
    ///
    /// Operations are serialized in the task queue. Before deleting, focus is
    /// restored to the target element.
    ///
    /// - Parameter count: Number of characters to delete. Must be > 0.
    func deleteChars(_ count: Int) {
        guard count > 0 else { return }
        let operationId = nextOperationId()
        guard queuedInsertionCount < Config.maxQueuedTextInsertions else {
            observabilityEvent(
                "delete_chars_dropped_queue_full",
                level: .warning,
                metadata: [
                    "operationId": String(operationId),
                    "queuedInsertionCount": String(queuedInsertionCount)
                ]
            )
            return
        }

        observabilityEvent(
            "delete_chars_queued",
            metadata: [
                "operationId": String(operationId),
                "deleteCount": String(count),
                "queueDepthBefore": String(queuedInsertionCount)
            ]
        )
        let previousTask = textInsertionTask
        queuedInsertionCount += 1
        let generation = queueGeneration

        textInsertionTask = Task { @MainActor [weak self] in
            defer {
                self?.decrementQueuedInsertionCount(for: generation)
            }
            await previousTask?.value
            _ = await self?.deleteCharsAsync(count, operationId: operationId, generation: generation)
        }
    }

    // MARK: - Enter Key

    /// Queues an Enter (Return) key press after all pending text operations.
    ///
    /// This simulates pressing the Enter key, which typically submits forms,
    /// inserts newlines, or triggers other default actions in the focused element.
    /// The operation is serialized in the task queue after all preceding text
    /// insertions and deletions complete, with focus restoration.
    ///
    /// Note: Unlike `insertText(_:)` and `deleteChars(_:)`, this does not
    /// increment the queue count (not bounded by `maxQueuedTextInsertions`).
    func pressEnterKey() {
        let operationId = nextOperationId()
        let generation = queueGeneration
        let previousTask = textInsertionTask
        observabilityEvent(
            "press_enter_queued",
            metadata: [
                "operationId": String(operationId),
                "queueDepthBefore": String(queuedInsertionCount)
            ]
        )

        textInsertionTask = Task { [weak self] in
            await previousTask?.value

            guard let self, self.isCurrent(generation), !Task.isCancelled else { return }
            guard !self.bulkDeliveryFailed else { return }
            if self.streamingActive &&
                (self.streamingDeliveryFailed || self.streamingDesiredText != self.streamingPostedText) {
                self.refuseStreamingDelivery()
                return
            }
            guard await self.ensureTargetFocused(generation: generation),
                  let keyDown = CGEvent(
                      keyboardEventSource: nil,
                      virtualKey: Self.enterKeyCode,
                      keyDown: true
                  ),
                  let keyUp = CGEvent(
                      keyboardEventSource: nil,
                      virtualKey: Self.enterKeyCode,
                      keyDown: false
                  ),
                  await self.postGuardedKeyPair(
                      keyDown,
                      keyUp,
                      generation: generation,
                      releaseDelayNanoseconds: Self.enterKeyDelayNanoseconds
                  ) else { return }
            self.observabilityEvent(
                "press_enter_emitted",
                metadata: ["operationId": String(operationId)]
            )
        }
    }

    // MARK: - Task Management

    /// The currently pending insertion task, if any.
    ///
    /// Exposed so callers (like `RecordingController`) can await pending
    /// insertions before performing cleanup or state transitions.
    var pendingTask: Task<Void, Never>? { textInsertionTask }

    /// Waits for all pending text insertion operations to complete.
    ///
    /// Use this before stopping recording or transitioning states to ensure
    /// all queued text has been delivered to the target application.
    func waitForPendingInsertions() async {
        await textInsertionTask?.value
    }

    /// Whether an operation enqueued under `generation` may still act.
    /// `cancelAndReset()` and `reset()` start a new generation, which retires
    /// every operation queued before them, including ones already running.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == queueGeneration
    }

    private func decrementQueuedInsertionCount(for generation: UInt64) {
        guard generation == queueGeneration else { return }
        queuedInsertionCount = max(0, queuedInsertionCount - 1)
    }

    /// Cancels any in-flight text operations and resets all state.
    ///
    /// Call this when the user manually stops recording or when an error occurs.
    /// This immediately stops all queued operations and clears the target element.
    func cancelAndReset() {
        bulkDeliveryFailed = false
        pendingStreamingSnapshot = nil
        streamingReconciliationQueued = false
        streamingCommittedText = ""
        streamingPostedText = ""
        streamingDesiredText = ""
        streamingActive = false
        streamingDeliveryFailed = false
        textInsertionTask?.cancel()
        textInsertionTask = nil
        queueGeneration &+= 1
        queuedInsertionCount = 0
        targetElement = nil
        targetWindow = nil
        targetPid = 0
        targetBundleIdentifier = nil
        targetApplicationURL = nil
    }

    /// Clears bookkeeping without cancelling tasks.
    ///
    /// Used when text insertions completed naturally (e.g., all transcriptions
    /// finished and were typed successfully). Unlike `cancelAndReset()`, this
    /// doesn't interrupt any tasks — it just resets state for the next session.
    func reset() {
        bulkDeliveryFailed = false
        pendingStreamingSnapshot = nil
        streamingReconciliationQueued = false
        streamingCommittedText = ""
        streamingPostedText = ""
        streamingDesiredText = ""
        streamingActive = false
        streamingDeliveryFailed = false
        textInsertionTask = nil
        queueGeneration &+= 1
        queuedInsertionCount = 0
        targetElement = nil
        targetWindow = nil
        targetPid = 0
        targetBundleIdentifier = nil
        targetApplicationURL = nil
    }

    // MARK: - Private Helpers

    private func sanitizeTextForInsertion(_ text: String) -> String {
        // Sanitize: only allow safe printable characters and whitespace
        let sanitized = text.filter {
            $0.isLetter || $0.isNumber || $0.isPunctuation ||
            $0.isSymbol || $0.isWhitespace || $0 == "\n" || $0 == "\t"
        }

        // Truncate to safety limit if needed
        if sanitized.count > Self.maxTextInsertionLength {
            return String(sanitized.prefix(Self.maxTextInsertionLength))
        }
        return sanitized
    }

    private func deleteCharsAsync(
        _ count: Int, operationId: UInt64, generation: UInt64,
        onCharacterDeleted: (() -> Void)? = nil
    ) async -> Bool {
        guard count > 0 else { return true }
        observabilityEvent(
            "delete_chars_started",
            metadata: [
                "operationId": String(operationId),
                "deleteCount": String(count)
            ]
        )

        // Ensure the target element has focus before deleting
        guard await ensureTargetFocused(generation: generation) else { return false }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        // Send Delete key events one at a time
        for _ in 0..<count {
            // Check for cancellation between deletions
            try? Task.checkCancellation()
            if Task.isCancelled { return false }

            // Re-check focus between deletions — if the user switched apps
            // mid-stream, wait for return or timeout
            guard await ensureTargetFocused(generation: generation) else { return false }

            // Create key-down and key-up events for the Delete key
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.deleteKeyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.deleteKeyCode,
                keyDown: false
            ) else { continue }

            guard await postGuardedKeyPair(keyDown, keyUp, generation: generation) else { return false }
            onCharacterDeleted?()

            // Small delay to ensure the app processes the deletion
            try? await Task.sleep(
                nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000
            )
        }
        observabilityEvent(
            "delete_chars_completed",
            metadata: [
                "operationId": String(operationId),
                "deleteCount": String(count)
            ]
        )
        return true
    }

    /// Delay between focus checks while waiting for the user to return (200ms).
    private static let focusWaitInterval: UInt64 = 200_000_000

    /// Waits until the target app is frontmost, without stealing focus.
    ///
    /// CGEvent keystrokes go to the frontmost app. If the user has switched away,
    /// typing into the wrong app could trigger unintended actions (closing tabs,
    /// pressing buttons, etc.). Instead of activating the target app, we pause
    /// and wait for the user to switch back voluntarily.
    ///
    /// Flow:
    /// 1. No target captured → return false (fail closed)
    /// 2. Target app is frontmost → return true (fast path)
    /// 3. Different app is frontmost → poll every 200ms until focus returns or timeout
    /// 4. Timeout expires (`focusWaitTimeout`) → return false (discard pending text)
    ///
    /// - Returns: `true` if the target app is frontmost, `false` if the timeout
    ///   expired, the task was cancelled, or the target app is no longer running.
    func ensureTargetFocused() async -> Bool {
        await ensureTargetFocused(generation: queueGeneration)
    }

    /// Same as `ensureTargetFocused()`, but gives up as soon as the operation
    /// that asked has been retired by cancellation or reset.
    private func ensureTargetFocused(generation: UInt64) async -> Bool {
        guard isCurrent(generation) else { return false }
        // No captured destination: refuse rather than type wherever focus is.
        guard targetElement != nil, targetPid != 0 else {
            observabilityEvent("insertion_refused_no_target", level: .warning)
            return false
        }

        guard recoverTargetPidIfNeeded() else { return false }

        // Fast path: target app is frontmost
        if isTargetAppFrontmost() { return true }

        // Verify the target app is still running before waiting
        guard isTargetProcessRunning(targetPid) || recoverTargetPidIfNeeded() else {
            return false
        }

        let timeout = focusWaitTimeoutProvider()
        let startTime = ContinuousClock.now

        Logger.audio.info("Target app lost focus — waiting up to \(timeout)s for user to return")
        observabilityEvent(
            "focus_lost_waiting",
            metadata: [
                "timeoutSeconds": String(timeout),
                "targetPid": String(targetPid),
                "reason": lastFocusMismatch
            ]
        )

        // Poll until focus returns, timeout expires, or the task is cancelled
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.focusWaitInterval)
            guard isCurrent(generation) else { return false }
            if isTargetAppFrontmost() {
                Logger.audio.info("Target app regained focus — resuming text insertion")
                observabilityEvent("focus_regained", metadata: ["targetPid": String(targetPid)])
                return true
            }

            // If the target app was terminated while waiting, stop
            if !isTargetProcessRunning(targetPid), !recoverTargetPidIfNeeded() {
                return false
            }

            let elapsed = ContinuousClock.now - startTime
            if elapsed > .seconds(timeout) {
                Logger.audio.warning("Focus wait timed out after \(timeout)s — discarding pending text")
                observabilityEvent(
                    "focus_wait_timeout",
                    level: .warning,
                    metadata: [
                        "timeoutSeconds": String(timeout),
                        "targetPid": String(targetPid)
                    ]
                )
                return false
            }
        }

        return false
    }

    /// Checks whether keyboard focus is in the target app.
    ///
    /// Queries the system-wide focused element's PID to determine where
    /// keystrokes will actually go. This catches system overlays like
    /// Spotlight, Notification Center, and password dialogs that steal
    /// keyboard focus without changing the frontmost application.
    /// Fails closed if Accessibility cannot prove the captured field owns focus.
    func isTargetAppFrontmost() -> Bool {
        guard targetPid != 0 else { return false }

        // Test hook: allows unit tests to inject a deterministic result without
        // depending on live NSWorkspace / AX state (which can be non-deterministic
        // in CI environments where the frontmost app may change between test steps).
        if let override = testIsTargetFrontmost { return override }
        // Ask Accessibility which process and field own keyboard focus. This is
        // more authoritative than NSWorkspace.frontmostApplication: overlays
        // (Spotlight, password dialogs) take keyboard focus without changing the
        // frontmost app, and some apps route UI through helper processes.
        let observation = focusObserver.map { $0(self) } ?? systemFocusObservation()
        guard let observation else {
            // App identity alone cannot distinguish fields or system overlays.
            lastFocusMismatch = "unknownField"
            return false
        }
        return focusMatchesTarget(observation)
    }

    /// Recovers `targetPid` when the target app relaunches with a new PID.
    ///
    /// Returns false only if the original PID is gone and no matching running app
    /// can be found for the captured target bundle identifier.
    private func recoverTargetPidIfNeeded() -> Bool {
        if targetPid != 0, isTargetProcessRunning(targetPid) {
            return true
        }

        guard let bundleId = targetBundleIdentifier else { return false }
        guard let runningTarget = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId && !$0.isTerminated
                && ApplicationOwnership.matches(target: targetApplicationURL, candidate: $0.bundleURL ?? $0.executableURL)
        }) else {
            return false
        }

        targetPid = runningTarget.processIdentifier
        return true
    }

    /// Number of characters to type before yielding to the run-loop.
    /// Smaller batches reduce the chance that the receiving app will move the
    /// caret or reflow the document while we are still flooding it with events.
    private static let typingBatchSize = 14

    /// Delay between typing batches (8.5ms).
    /// This extra yield gives the target app time to process the just-emitted
    /// keystrokes before the next burst arrives.
    private static let typingBatchYieldNanoseconds: UInt64 = 8_500_000

    /// Types the given text using CGEvent Unicode synthesis in small batches.
    ///
    /// This is the core text insertion mechanism:
    /// 1. Ensures the target element has focus (waiting for user to return if needed)
    /// 2. Before every character, re-checks focus so app switches cannot leak typing
    /// 3. Before every character, waits for modifiers (Cmd/Ctrl/Option/Shift) to release
    /// 4. Yields between batches so mouse/keyboard input and event taps stay responsive
    ///
    /// - Parameter text: The sanitized text to type. Should not contain control characters.
    private func typeTextAsync(
        _ text: String, operationId: UInt64, generation: UInt64,
        onCharacterPosted: ((Character) -> Void)? = nil
    ) async {
        observabilityEvent(
            "type_text_started",
            metadata: [
                "operationId": String(operationId)
            ]
            .merging(metadataForTextPayload(text), uniquingKeysWith: { _, new in new })
        )
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        // Ensure the target element has focus (waits for user to return if switched)
        guard await self.ensureTargetFocused(generation: generation) else { return }

        // Type in small batches, yielding between them so the WindowServer
        // event queue can drain (keeps mouse clicks responsive) and other
        // run-loop sources (CGEvent taps, SwiftUI) get processing time.
        let chars = Array(text)
        var index = 0
        var typedSinceYield = 0
        var batchIndex = 0
        var currentBatch = ""

        while index < chars.count {
            do { try Task.checkCancellation() } catch { return }

            // Re-check focus before each character. If user switched apps,
            // pause until they return or timeout.
            if !isTargetAppFrontmost() {
                guard await self.ensureTargetFocused(generation: generation) else { return }
            }

            // Convert character to UTF-16 code units for CGEvent's Unicode API
            var unichar = Array(String(chars[index]).utf16)

            // Create key events with virtualKey=0 to use Unicode string
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ),
                  let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
            ) else {
                index += 1
                continue
            }

            keyDown.keyboardSetUnicodeString(
                stringLength: unichar.count,
                unicodeString: &unichar
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: unichar.count,
                unicodeString: &unichar
            )

            guard await postGuardedKeyPair(keyDown, keyUp, generation: generation) else { return }
            onCharacterPosted?(chars[index])

            // Small delay to ensure the character is processed
            try? await Task.sleep(
                nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000
            )

            currentBatch.append(chars[index])
            index += 1
            typedSinceYield += 1

            // Yield between batches so the run-loop can process pending events
            if typedSinceYield >= Self.typingBatchSize {
                typedSinceYield = 0
                if !currentBatch.isEmpty {
                    emitTypingBatch(
                        operationId: operationId,
                        batchIndex: batchIndex,
                        text: currentBatch
                    )
                    batchIndex += 1
                    currentBatch.removeAll(keepingCapacity: true)
                }
                if index < chars.count {
                    try? await Task.sleep(nanoseconds: Self.typingBatchYieldNanoseconds)
                }
            }
        }

        if !currentBatch.isEmpty {
            emitTypingBatch(
                operationId: operationId,
                batchIndex: batchIndex,
                text: currentBatch
            )
        }
        observabilityEvent(
            "type_text_completed",
            metadata: [
                "operationId": String(operationId),
                "totalChars": String(text.count)
            ]
        )
    }

    private func emitTypingBatch(operationId: UInt64, batchIndex: Int, text: String) {
        observabilityEvent(
            "typing_batch_emitted",
            metadata: [
                "operationId": String(operationId),
                "batchIndex": String(batchIndex)
            ]
            .merging(metadataForTextPayload(text), uniquingKeysWith: { _, new in new })
        )
    }

    private static func currentHardwareModifierFlags() -> CGEventFlags {
        CGEventSource.flagsState(.hidSystemState)
    }

    private static func hasActiveModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl)
            || flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskShift)
    }

    /// Waits for all modifier keys (Cmd, Ctrl, Option, Shift) to be released.
    ///
    /// This prevents corruption when the user is holding modifier keys while
    /// text begins typing. For example, holding Cmd while typing could trigger
    /// shortcuts (Cmd+A = Select All, Cmd+Q = Quit, etc.).
    ///
    /// Polls the modifier key state every 10ms for up to 1 second (100 attempts).
    ///
    /// - Returns: `true` when all modifiers were released before timeout, `false`
    ///   when timeout/cancellation occurred and modifiers may still be active.
    private func waitForModifiersReleased(
        maxAttempts: Int? = nil,
        flagsProvider: (() -> CGEventFlags)? = nil,
        sleep: ((UInt64) async -> Void)? = nil
    ) async -> Bool {
        let maxAttempts = maxAttempts ?? Self.maxModifierReleaseAttempts
        let flagsProvider = flagsProvider ?? self.flagsProvider
        let sleep = sleep ?? { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        var attempts = 0

        while !Task.isCancelled, attempts < maxAttempts {
            if !Self.hasActiveModifiers(flagsProvider()) {
                return true
            }

            attempts += 1
            await sleep(Self.modifierCheckDelayNanoseconds)
        }

        return !Task.isCancelled && !Self.hasActiveModifiers(flagsProvider())
    }

    // MARK: - Synthetic Event Gate

    /// The single choke point through which every synthesized key action must
    /// pass. Validation happens before key-down only. After that point the
    /// matching key-up is mandatory cleanup and is posted exactly once, in
    /// order, regardless of cancellation, modifier changes, or focus changes.
    private func postGuardedKeyPair(
        _ keyDown: CGEvent,
        _ keyUp: CGEvent,
        generation: UInt64,
        releaseDelayNanoseconds: UInt64 = 0
    ) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            // Checked after every suspension: a retired operation must never
            // post a key-down, even if it was already running when cancelled.
            guard isCurrent(generation) else { return false }

            if Self.hasActiveModifiers(flagsProvider()) {
                let released = await waitForModifiersReleased()
                if Task.isCancelled { return false }
                if !released { continue }

                // Focus may have changed while modifiers were held. Re-enter
                // the loop because modifiers or cancellation can change while
                // focus validation suspends.
                guard await ensureTargetFocused(generation: generation) else { return false }
                continue
            }

            // Preserve live typing in editors whose accessibility value is absent or stale.
            // Focus, modifiers and generation still gate every posted key pair.
            eventPoster(keyDown)
            if releaseDelayNanoseconds > 0 {
                // Cancellation can end this delay early, but cannot suppress
                // the release for a key-down that has already been emitted.
                try? await Task.sleep(nanoseconds: releaseDelayNanoseconds)
            }
            eventPoster(keyUp)
            return true
        }
    }

}

// MARK: - Field Identity

extension TextInserter {
    /// Whether keyboard focus is still in the captured field.
    enum FieldIdentity: Equatable, Sendable {
        case same
        case different
        /// Accessibility gave no evidence either way.
        case unknown
    }

    /// What the captured element itself reports about its focus.
    enum CapturedFocusState: Equatable, Sendable {
        case focused
        case notFocused
        /// The element was destroyed (for example the conversation was switched).
        case elementGone
        /// The app does not answer, or does not expose the attribute.
        case unknown
    }

    /// Where keyboard focus is now, relative to the captured target.
    struct FocusObservation: Sendable {
        let focusedPid: pid_t?
        let field: FieldIdentity
    }

    /// Authorizes input only with positive evidence of the captured field.
    /// A shared window is not proof: it may contain multiple editable fields.
    nonisolated static func fieldIdentity(
        elementsEqual: Bool,
        capturedReportsFocused: CapturedFocusState?,
        windowsMatch: Bool?
    ) -> FieldIdentity {
        if elementsEqual { return .same }
        switch capturedReportsFocused {
        case .focused:
            return .same
        case .notFocused, .elementGone:
            return .different
        case .unknown, nil:
            return windowsMatch == false ? .different : .unknown
        }
    }

    /// Longest an Accessibility query against the target app may block typing.
    private static let fieldQueryTimeoutSeconds: Float = 0.25

    /// Live Accessibility view of keyboard focus relative to the captured field.
    private func systemFocusObservation() -> FocusObservation? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = Self.elementAttribute(kAXFocusedUIElementAttribute, of: systemWide) else { return nil }
        var focusedPid: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPid) == .success else { return nil }
        guard let targetElement else { return FocusObservation(focusedPid: focusedPid, field: .unknown) }
        if CFEqual(focused, targetElement) {
            return FocusObservation(focusedPid: focusedPid, field: .same)
        }
        let windowsMatch: Bool? = {
            guard let targetWindow,
                  let focusedWindow = Self.elementAttribute(kAXWindowAttribute, of: focused) else { return nil }
            return CFEqual(focusedWindow, targetWindow)
        }()
        let field = Self.fieldIdentity(
            elementsEqual: false,
            capturedReportsFocused: Self.focusState(of: targetElement),
            windowsMatch: windowsMatch
        )
        return FocusObservation(focusedPid: focusedPid, field: field)
    }

    private static func focusState(of element: AXUIElement) -> CapturedFocusState {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unknown }
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)) ? .focused : .notFocused
        case .invalidUIElement:
            return .elementGone
        default:
            return .unknown
        }
    }

    private static func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Focus must be in the target app (or one of its helpers) and positively
    /// identified as the captured field.
    private func focusMatchesTarget(_ observation: FocusObservation) -> Bool {
        guard let focusedPid = observation.focusedPid else { return false }
        if focusedPid != targetPid {
            let capturedApplication = targetApplicationURL ?? ApplicationOwnership.applicationURL(for: targetPid)
            let focusedApplication = ApplicationOwnership.applicationURL(for: focusedPid)
            guard ApplicationOwnership.matches(target: capturedApplication, candidate: focusedApplication) else {
                lastFocusMismatch = "otherApp"
                return false
            }
        }
        // Same app is insufficient when field identity is different or unknown.
        guard observation.field == .same else {
            lastFocusMismatch = observation.field == .unknown ? "unknownField" : "otherFieldInTargetApp"
            return false
        }
        return true
    }
}

#if DEBUG
extension TextInserter {
    // swiftlint:disable:next identifier_name
    static func _testMakeIsolatedInstance() -> TextInserter { TextInserter() }

    func setCaptureAccessibilityForTesting(_ accessibility: TargetCaptureAccessibility) {
        captureAccessibility = accessibility
    }

    // swiftlint:disable:next identifier_name
    var _testQueuedInsertionCount: Int { queuedInsertionCount }

    // swiftlint:disable:next identifier_name
    var _testQueueGeneration: UInt64 { queueGeneration }

    // swiftlint:disable:next identifier_name
    func _testSetQueuedInsertionCount(_ count: Int) {
        queuedInsertionCount = count
    }

    // swiftlint:disable:next identifier_name
    func _testDecrementQueuedInsertionCount() {
        decrementQueuedInsertionCount(for: queueGeneration)
    }

    // swiftlint:disable:next identifier_name
    func _testDecrementQueuedInsertionCount(generation: UInt64) {
        decrementQueuedInsertionCount(for: generation)
    }

    // swiftlint:disable:next identifier_name
    static var _testKeystrokeDelayMicroseconds: UInt32 { keystrokeDelayMicroseconds }

    // swiftlint:disable:next identifier_name
    static var _testTypingBatchSize: Int { typingBatchSize }

    // swiftlint:disable:next identifier_name
    static var _testTypingBatchYieldNanoseconds: UInt64 { typingBatchYieldNanoseconds }

    // swiftlint:disable:next identifier_name
    static func _testHasActiveModifiers(_ flags: CGEventFlags) -> Bool {
        hasActiveModifiers(flags)
    }

    // swiftlint:disable:next identifier_name
    func _testWaitForModifiersReleased(
        maxAttempts: Int,
        flagsProvider: @escaping () -> CGEventFlags
    ) async -> Bool {
        await waitForModifiersReleased(
            maxAttempts: maxAttempts,
            flagsProvider: flagsProvider,
            sleep: { _ in }
        )
    }

    // Installs a scripted modifier-flags source consulted by the real
    // `postGuardedKeyPair` gate (and therefore by `insertText`/
    // `deleteChars`/`pressEnterKey`), so tests can drive those real entry
    // points deterministically without depending on live hardware state.
    // swiftlint:disable:next identifier_name
    func _testSetFlagsProvider(_ provider: @escaping () -> CGEventFlags) {
        flagsProvider = provider
    }

    // Installs a recorder in place of the real `CGEvent.post(tap:)` sink, so
    // tests can capture what synthetic key events *would* be posted (and in
    // what order) without emitting real OS events.
    // swiftlint:disable:next identifier_name
    func _testSetEventPoster(_ poster: @escaping (CGEvent) -> Void) {
        eventPoster = poster
    }

    // swiftlint:disable:next identifier_name
    func _testSetFocusWaitTimeout(_ timeout: Double) {
        focusWaitTimeoutProvider = { timeout }
    }

    // swiftlint:disable:next identifier_name
    func _testSetFocusObserver(_ observer: @escaping () -> FocusObservation?) {
        focusObserver = { _ in observer() }
    }

    // swiftlint:disable:next identifier_name
    func _testSetTargetProcessLiveness(_ provider: @escaping (pid_t) -> Bool) {
        isTargetProcessRunning = provider
    }

    // swiftlint:disable:next identifier_name
    func _testEnqueueSimulatedOperation(
        label: String,
        delayNanoseconds: UInt64 = 0,
        recorder: @escaping @MainActor (String) -> Void
    ) {
        queuedInsertionCount += 1
        let generation = queueGeneration
        let previousTask = textInsertionTask
        textInsertionTask = Task { @MainActor [weak self] in
            defer {
                self?.decrementQueuedInsertionCount(for: generation)
            }
            await previousTask?.value
            recorder("start:\(label)")
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            recorder("end:\(label)")
        }
    }
}
#endif
