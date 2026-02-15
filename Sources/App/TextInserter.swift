import AppKit
import ApplicationServices
import OSLog
import SpeakFlowCore

/// Queues and delivers text to the captured UI element via CGEvent keystroke synthesis.
///
/// This component handles all text insertion operations by:
/// - Capturing the currently focused accessibility element before recording starts
/// - Restoring focus to the captured element before each operation (activating its app if needed)
/// - Serializing all text operations (insertions, deletions, Enter key) into a task queue
/// - Synthesizing keystrokes character-by-character using CGEvent Unicode strings
/// - Waiting for modifier keys to be released to prevent corruption
///
/// **Focus Restoration:** If the user switches apps during transcription, each queued
/// operation will activate the target app and refocus the captured element before
/// sending keystrokes. This ensures text always appears in the original text field.
///
/// **Thread Safety:** All public methods are `@MainActor` and maintain a serial task queue.
/// Each operation awaits the previous task before executing, ensuring text appears in order.
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

    /// Delay in microseconds between individual keystrokes (5ms).
    /// This prevents overwhelming the receiving application and ensures
    /// keystrokes are processed in the correct order. Some apps (especially
    /// web views) drop characters if events arrive too quickly.
    private static let keystrokeDelayMicroseconds: UInt32 = 5000

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

    /// The current task chain for text operations.
    /// Each new operation creates a task that awaits this one, forming a serial queue.
    private var textInsertionTask: Task<Void, Never>?

    /// Number of operations currently queued.
    /// Bounded by `Config.maxQueuedTextInsertions` to prevent unbounded memory growth.
    private var queuedInsertionCount = 0

    private init() {}

    // MARK: - Target Capture

    /// Captures the currently focused UI element and its app PID.
    ///
    /// Call this immediately before starting recording to establish which
    /// app should receive transcribed text. Before each text operation,
    /// `ensureTargetFocused()` checks that the same app is still frontmost
    /// and pauses if the user has switched away.
    ///
    /// If no element has focus or accessibility permissions are denied, sets
    /// `targetElement` to `nil` (focus checks will be skipped).
    func captureTarget() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        // Query the system for the currently focused accessibility element
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
           let element = focusedElement,
           CFGetTypeID(element) == AXUIElementGetTypeID() {
            // Safe: CFGetTypeID check above guarantees element is AXUIElement;
            // Swift CF bridging always succeeds for this cast
            // swiftlint:disable:next force_cast
            let axElement = element as! AXUIElement
            targetElement = axElement

            // Store the PID for reliable app-level focus comparison
            var pid: pid_t = 0
            if AXUIElementGetPid(axElement, &pid) == .success {
                targetPid = pid
            } else {
                targetPid = 0
            }
        } else {
            // No focus or accessibility denied — focus checks will be skipped
            targetElement = nil
            targetPid = 0
        }
    }

    // MARK: - Text Operations

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
        // Sanitize: only allow safe printable characters and whitespace
        let sanitized = text.filter {
            $0.isLetter || $0.isNumber || $0.isPunctuation ||
            $0.isSymbol || $0.isWhitespace || $0 == "\n" || $0 == "\t"
        }

        // Truncate to safety limit if needed
        let textToInsert = sanitized.count > Self.maxTextInsertionLength
            ? String(sanitized.prefix(Self.maxTextInsertionLength))
            : sanitized

        // Ignore empty text or if queue is full
        guard !textToInsert.isEmpty, queuedInsertionCount < Config.maxQueuedTextInsertions else {
            return
        }

        queuedInsertionCount += 1
        let previousTask = textInsertionTask

        // Chain this insertion after the previous operation
        textInsertionTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.queuedInsertionCount -= 1
                }
            }
            await previousTask?.value
            await self?.typeTextAsync(textToInsert)
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

        let previousTask = textInsertionTask
        queuedInsertionCount += 1

        textInsertionTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.queuedInsertionCount -= 1
                }
            }
            await previousTask?.value

            // Ensure the target element has focus before deleting
            guard await self?.ensureTargetFocused() == true else { return }

            guard let source = CGEventSource(stateID: .combinedSessionState) else {
                return
            }

            // Send Delete key events one at a time
            for _ in 0..<count {
                // Check for cancellation between deletions
                try? Task.checkCancellation()

                // Re-check focus between deletions — if the user switched apps
                // mid-stream, pause until they return
                guard await self?.ensureTargetFocused() == true else { return }

                // Create key-down and key-up events for the Delete key
                if let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: Self.deleteKeyCode,
                    keyDown: true
                ),
                   let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: Self.deleteKeyCode,
                    keyDown: false
                ) {
                    keyDown.post(tap: .cghidEventTap)
                    keyUp.post(tap: .cghidEventTap)

                    // Small delay to ensure the app processes the deletion
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000
                    )
                }
            }
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
        let previousTask = textInsertionTask

        textInsertionTask = Task { [weak self] in
            await previousTask?.value

            // Ensure the target element has focus before pressing Enter
            guard await self?.ensureTargetFocused() == true else { return }

            // Create key-down event
            if let keyDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: Self.enterKeyCode,
                keyDown: true
            ) {
                keyDown.post(tap: .cghidEventTap)
            }

            // Brief delay between key-down and key-up for proper registration
            try? await Task.sleep(nanoseconds: Self.enterKeyDelayNanoseconds)

            if let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: Self.enterKeyCode,
                keyDown: false
            ) {
                keyUp.post(tap: .cghidEventTap)
            }
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

    /// Cancels any in-flight text operations and resets all state.
    ///
    /// Call this when the user manually stops recording or when an error occurs.
    /// This immediately stops all queued operations and clears the target element.
    func cancelAndReset() {
        textInsertionTask?.cancel()
        textInsertionTask = nil
        queuedInsertionCount = 0
        targetElement = nil
        targetPid = 0
    }

    /// Clears bookkeeping without cancelling tasks.
    ///
    /// Used when text insertions completed naturally (e.g., all transcriptions
    /// finished and were typed successfully). Unlike `cancelAndReset()`, this
    /// doesn't interrupt any tasks — it just resets state for the next session.
    func reset() {
        textInsertionTask = nil
        queuedInsertionCount = 0
        targetElement = nil
        targetPid = 0
    }

    // MARK: - Private Helpers

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
    /// 1. No target captured → return true (proceed without focus management)
    /// 2. Target app is frontmost → return true (fast path)
    /// 3. Different app is frontmost → poll every 200ms until it changes back
    ///
    /// - Returns: `true` if the target app is frontmost, `false` if the task was
    ///   cancelled or the target app is no longer running.
    func ensureTargetFocused() async -> Bool {
        guard targetElement != nil, targetPid != 0 else { return true }

        // Fast path: target app is frontmost
        if isTargetAppFrontmost() { return true }

        // Verify the target app is still running before waiting
        guard NSRunningApplication(processIdentifier: targetPid) != nil else { return false }

        Logger.audio.info("Target app lost focus — pausing text insertion until user returns")

        // Poll until focus returns or the task is cancelled
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.focusWaitInterval)
            if isTargetAppFrontmost() {
                Logger.audio.info("Target app regained focus — resuming text insertion")
                return true
            }

            // If the target app was terminated while waiting, stop
            if NSRunningApplication(processIdentifier: targetPid) == nil { return false }
        }

        return false
    }

    /// Checks whether the target app is currently frontmost.
    ///
    /// Compares the frontmost application's PID against the stored target PID.
    /// This is more reliable than CFEqual on AXUIElements, which can fail
    /// when the same element returns different refs across queries.
    func isTargetAppFrontmost() -> Bool {
        guard targetPid != 0 else { return true }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == targetPid
    }

    /// Types the given text character-by-character using CGEvent Unicode synthesis.
    ///
    /// This is the core text insertion mechanism:
    /// 1. Ensures the target element has focus (activating its app if needed)
    /// 2. Waits for modifier keys (Cmd/Ctrl/Option/Shift) to be released
    /// 3. Synthesizes key-down and key-up events for each character using Unicode strings
    /// 4. Adds a small delay between characters to prevent overwhelming the app
    ///
    /// Cancellation-aware: checks `Task.isCancelled` before each character and
    /// returns immediately if cancelled, leaving remaining text untyped.
    ///
    /// - Parameter text: The sanitized text to type. Should not contain control characters.
    private func typeTextAsync(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        // Ensure the target element has focus (activates app if user switched away)
        guard await self.ensureTargetFocused() else { return }

        // Wait for the user to release Cmd/Ctrl/Option/Shift before typing
        await waitForModifiersReleased()

        // Type each character individually
        for char in text {
            // Check if the task was cancelled
            do {
                try Task.checkCancellation()
            } catch {
                return
            }

            // Re-check focus between characters — if the user switched apps
            // mid-stream, pause until they return rather than typing into the wrong app
            guard await self.ensureTargetFocused() else { return }

            // Re-check modifier keys before each character
            await waitForModifiersReleased()

            // Convert character to UTF-16 code units for CGEvent's Unicode API
            var unichar = Array(String(char).utf16)

            // Create key events with virtualKey=0 to use Unicode string instead of key code
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
                continue
            }

            // Attach the Unicode character to the key-down event
            keyDown.keyboardSetUnicodeString(
                stringLength: unichar.count,
                unicodeString: &unichar
            )

            // Post both events to simulate a keystroke
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Small delay to ensure the character is processed before the next one
            try? await Task.sleep(
                nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000
            )
        }
    }

    /// Waits for all modifier keys (Cmd, Ctrl, Option, Shift) to be released.
    ///
    /// This prevents corruption when the user is holding modifier keys while
    /// text begins typing. For example, holding Cmd while typing could trigger
    /// shortcuts (Cmd+A = Select All, Cmd+Q = Quit, etc.).
    ///
    /// Polls the modifier key state every 10ms for up to 1 second (100 attempts).
    /// If modifiers are still held after the timeout, proceeds anyway to avoid
    /// blocking indefinitely (e.g., if a modifier key is physically stuck).
    private func waitForModifiersReleased() async {
        var attempts = 0

        while attempts < Self.maxModifierReleaseAttempts {
            let flags = CGEventSource.flagsState(.combinedSessionState)

            // Check if any modifier keys are currently pressed
            if !flags.contains(.maskControl)
                && !flags.contains(.maskCommand)
                && !flags.contains(.maskAlternate)
                && !flags.contains(.maskShift) {
                // All modifiers released — safe to proceed
                return
            }

            attempts += 1

            // Wait before rechecking
            try? await Task.sleep(nanoseconds: Self.modifierCheckDelayNanoseconds)
        }

        // Timeout: proceed despite modifiers still being held
    }
}
