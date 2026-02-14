import AppKit
import ApplicationServices
import SpeakFlowCore

/// Queues and delivers text to the focused UI element via CGEvent keystroke synthesis.
///
/// Extracted from RecordingController to isolate the text-insertion pipeline
/// (target capture, character typing, deletion, Enter key) into a single-
/// responsibility component.
@MainActor
final class TextInserter: TextInserting {
    static let shared = TextInserter()

    private(set) var targetElement: AXUIElement?
    private var textInsertionTask: Task<Void, Never>?
    private var queuedInsertionCount = 0

    private static let maxTextInsertionLength = 100_000
    private static let keystrokeDelayMicroseconds: UInt32 = 5000

    private init() {}

    // MARK: - Target

    /// Capture the currently focused AXUIElement so we can verify
    /// that focus hasn't shifted before inserting text later.
    func captureTarget() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let element = focusedElement, CFGetTypeID(element) == AXUIElementGetTypeID() {
            // Safe: CFGetTypeID check above guarantees element is AXUIElement;
            // Swift CF bridging always succeeds for this cast
            // swiftlint:disable:next force_cast
            targetElement = (element as! AXUIElement)
        } else {
            targetElement = nil
        }
    }

    // MARK: - Insert / Delete

    func insertText(_ text: String) {
        let sanitized = text.filter { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0.isWhitespace || $0 == "\n" || $0 == "\t" }
        let textToInsert = sanitized.count > Self.maxTextInsertionLength ? String(sanitized.prefix(Self.maxTextInsertionLength)) : sanitized
        guard !textToInsert.isEmpty, queuedInsertionCount < Config.maxQueuedTextInsertions else { return }
        queuedInsertionCount += 1
        let previousTask = textInsertionTask
        textInsertionTask = Task { [weak self] in
            defer { Task { @MainActor in self?.queuedInsertionCount -= 1 } }
            await previousTask?.value
            await self?.typeTextAsync(textToInsert)
        }
    }

    func deleteChars(_ count: Int) {
        guard count > 0 else { return }
        let previousTask = textInsertionTask
        queuedInsertionCount += 1
        textInsertionTask = Task { [weak self] in
            defer { Task { @MainActor in self?.queuedInsertionCount -= 1 } }
            await previousTask?.value
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            for _ in 0..<count {
                try? Task.checkCancellation()
                if let kd = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                   let ku = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                    kd.post(tap: .cghidEventTap); ku.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000)
                }
            }
        }
    }

    // MARK: - Enter Key

    func pressEnterKey() {
        guard verifyInsertionTarget() else { return }
        let keyCode: CGKeyCode = 36
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000)
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Waiting / Lifecycle

    /// The currently pending insertion task, exposed so callers can await it.
    var pendingTask: Task<Void, Never>? { textInsertionTask }

    func waitForPendingInsertions() async { await textInsertionTask?.value }

    /// Cancel any in-flight insertions and reset all state.
    func cancelAndReset() {
        textInsertionTask?.cancel()
        textInsertionTask = nil
        queuedInsertionCount = 0
        targetElement = nil
    }

    /// Clear bookkeeping without cancelling (used when insertions completed naturally).
    func reset() {
        textInsertionTask = nil
        queuedInsertionCount = 0
        targetElement = nil
    }

    // MARK: - Private

    func verifyInsertionTarget() -> Bool {
        guard let target = targetElement else { return true }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        // Safe: CFGetTypeID check above guarantees focused is AXUIElement;
        // Swift CF bridging always succeeds for this cast
        // swiftlint:disable:next force_cast
        return CFEqual(target, focused as! AXUIElement)
    }

    private func typeTextAsync(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        guard await MainActor.run(body: { self.verifyInsertionTarget() }) else { return }
        await waitForModifiersReleased()
        for char in text {
            do { try Task.checkCancellation() } catch { return }
            await waitForModifiersReleased()
            var unichar = Array(String(char).utf16)
            guard let kd = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let ku = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            kd.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
            kd.post(tap: .cghidEventTap); ku.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000)
        }
    }

    private func waitForModifiersReleased() async {
        var attempts = 0
        while attempts < 100 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskControl) && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && !flags.contains(.maskShift) { return }
            attempts += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
