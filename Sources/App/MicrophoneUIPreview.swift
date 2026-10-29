import SpeakFlowCore
import Foundation
import AppKit
import SwiftUI

/// The UI harness uses synthetic inputs so screenshots never capture device identifiers.
@MainActor
enum MicrophoneUIPreview {
    static let selection: MicrophoneSelection = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1",
           ProcessInfo.processInfo.environment["SPEAKFLOW_MICROPHONE_FIXTURES"] == "1" {
            return MicrophoneSelection(catalog: PreviewCatalog(), monitor: false)
        }
        #endif
        return .shared
    }()

    #if DEBUG
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
            && ProcessInfo.processInfo.environment["SPEAKFLOW_MICROPHONE_FIXTURES"] == "1"
    }

    static func showMenu(appDelegate: AppDelegate) {
        guard enabled else { return }
        DispatchQueue.main.async {
            guard let view = NSApp.mainWindow?.contentView else { return }
            let menu = NSHostingMenu(rootView: MenuBarView(appDelegate: appDelegate)
                .environment(\.microphoneSelection, selection))
            menu.popUp(positioning: nil, at: NSPoint(x: 50, y: view.bounds.height - 180), in: view)
        }
    }

    private final class PreviewCatalog: MicrophoneCatalogProviding {
        func snapshot() throws -> MicrophoneSnapshot {
            MicrophoneSnapshot(devices: [
                MicrophoneDevice(id: 1, uid: "fixture-a", name: "Built-in Microphone"),
                MicrophoneDevice(id: 2, uid: "fixture-b", name: "USB Microphone"),
                MicrophoneDevice(id: 3, uid: "fixture-c", name: "Wireless Headset")
            ], defaultID: 1)
        }
    }
    #endif
}
