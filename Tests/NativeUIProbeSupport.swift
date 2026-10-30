import AppKit
import Foundation
import Testing

/// AppKit button activation can stop the Swift async-main queue drain on this
/// runtime. Keep those native interactions in their own test process, and require
/// a completed test summary, not merely a successful process exit.
enum NativeUIProbeSupport {
    private static let childKey = "SPEAKFLOW_NATIVE_UI_CHILD"

    static func isChild(for suite: String) -> Bool {
        ProcessInfo.processInfo.environment[childKey] == suite
    }

    static func runChild(suite: String, expectedTests: Int, environmentOverrides: [String: String] = [:]) throws {
        let arguments = CommandLine.arguments
        let bundleOption = try #require(arguments.firstIndex(of: "--test-bundle-path"))
        try #require(arguments.indices.contains(bundleOption + 1))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = [
            "--test-bundle-path", arguments[bundleOption + 1],
            "--testing-library", "swift-testing", "--no-parallel", "--filter", suite
        ]
        var environment = try TestProcessEnvironment.inherited()
        environment.merge(environmentOverrides) { _, override in override }
        environment[childKey] = suite
        environment["SPEAKFLOW_RUN_UI_PROBES"] = "1"
        environment["SPEAKFLOW_ISOLATED_STORAGE"] = "1"
        environment["SPEAKFLOW_ISOLATE_TEST_AUDIO"] = "1"
        environment["SPEAKFLOW_MUTE_SOUNDS"] = "1"
        environment["SPEAKFLOW_OBSERVABILITY_DIR"] = "/dev/null/speakflow-observability"
        environment["SPEAKFLOW_RUN_LIVE_MISTRAL"] = nil
        environment["SPEAKFLOW_RUN_VAD_MODEL_TESTS"] = nil
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Native UI child failed: \(output)")
        let summary = "Test run with \(expectedTests) \(expectedTests == 1 ? "test" : "tests") in 1 suite passed"
        #expect(output.contains(summary),
                "Native UI child did not complete its assertions: \(output)")
    }
}

extension NativeUIProbeSupport {
    @MainActor static func captureView(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/screenshots")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }

    /// Dispatch inside this fixture window only. SwiftUI's drawn buttons need not
    /// have NSButton descendants, so exercise their native mouse event path.
    @MainActor static func clickBottomTrailingAction(in view: NSView, bottomInset: CGFloat = 24) throws {
        view.layoutSubtreeIfNeeded()
        let window = try #require(view.window)
        let local = NSPoint(x: view.bounds.maxX - 65,
            y: view.isFlipped ? view.bounds.maxY - bottomInset : view.bounds.minY + bottomInset)
        let point = view.convert(local, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }
}
