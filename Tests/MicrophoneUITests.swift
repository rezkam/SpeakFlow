import AppKit
import SwiftUI
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Microphone native controls", .serialized)
struct MicrophoneUITests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func settingsAndMenuShareSelectionAndRenderStates() async throws {
        guard NativeUIProbeSupport.isChild(for: "MicrophoneUITests") else {
            try NativeUIProbeSupport.runChild(suite: "MicrophoneUITests")
            return
        }
        RuntimeIsolation.isolateThisProcess()
        let first = MicrophoneDevice(id: 1, uid: "fixture-a", name: "Built-in Microphone")
        let second = MicrophoneDevice(id: 2, uid: "fixture-b", name: "USB Microphone")
        let third = MicrophoneDevice(id: 3, uid: "fixture-c", name: "Wireless Headset")
        let devices = [first, second, third]
        let catalog = StubMicrophoneCatalog(.init(devices: devices, defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        let state = AppState()
        state.microphoneGranted = true
        state.accessibilityGranted = true
        let host = NSHostingView(rootView: MainSettingsView()
            .environment(\.appState, state).environment(\.microphoneSelection, selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.title = "Microphone interface verification"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func pickers(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { pickers($0) }
        }
        func microphonePicker() -> NSPopUpButton? {
            pickers(host).first { $0.item(withTitle: "System Default") != nil }
        }
        func choose(_ title: String, in menu: NSMenu) throws {
            let item = try #require(menu.items.first { $0.title == title })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        func snapshot(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_SNAPSHOT_DIR"] else { return }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        try await waitUntil { microphonePicker() != nil }
        let picker = try #require(microphonePicker())
        #expect(picker.isEnabled)
        try snapshot("microphone-light")
        for device in devices {
            try choose(device.name, in: #require(picker.menu))
            try await waitUntil { selection.preferredUID == device.uid }
        }
        try choose("System Default", in: #require(picker.menu))
        try await waitUntil { selection.preferredUID == nil }
        let menu = NSHostingMenu(rootView: MenuBarView(appDelegate: AppDelegate())
            .environment(\.appState, state).environment(\.microphoneSelection, selection))
        menu.update()
        try await waitUntil { menu.items.contains { $0.title == "Microphone" } }
        let submenu = try #require(menu.items.first { $0.title == "Microphone" }?.submenu)
        submenu.update()
        for device in devices {
            try choose(device.name, in: submenu)
            try await waitUntil { selection.preferredUID == device.uid }
        }
        try choose("System Default", in: submenu)
        try await waitUntil { selection.preferredUID == nil }
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(150))
        try snapshot("microphone-dark")
        window.appearance = NSAppearance(named: .aqua)
        selection.select(second.uid)
        catalog.value = .init(devices: [first, third], defaultID: 1)
        selection.refresh()
        try await Task.sleep(for: .milliseconds(150))
        #expect(selection.preferenceUnavailable)
        #expect(picker.item(withTitle: "Unavailable microphone") != nil)
        try snapshot("microphone-disconnected")
        state.isRecording = true
        selection.captured(first, fallback: true)
        try await Task.sleep(for: .milliseconds(150))
        try snapshot("microphone-recording")
        try choose(third.name, in: #require(picker.menu))
        try await waitUntil { selection.preferredUID == third.uid }
        #expect(selection.activeDevice == first)
        state.isRecording = false
        selection.captureStopped()
        state.microphoneGranted = false
        try await Task.sleep(for: .milliseconds(150))
        try snapshot("microphone-permission")
        state.microphoneGranted = true
        catalog.value = .init(devices: [], defaultID: 0)
        selection.refresh()
        try await waitUntil { !picker.isEnabled }
        try snapshot("microphone-empty")
        let longName = MicrophoneDevice(id: 4, uid: "fixture-long",
            name: "External Microphone With A Very Long Descriptive Device Name")
        catalog.value = .init(devices: [first, longName], defaultID: 1)
        selection.refresh()
        selection.select(longName.uid)
        window.setContentSize(NSSize(width: 760, height: 720))
        try await waitUntil { picker.isEnabled }
        try snapshot("microphone-long-name")
    }
}
