import AppKit
import CoreServices
import Testing
@testable import SpeakFlow

@Suite("App lifecycle")
struct AppLifecycleTests {
    @MainActor @Test
    func closeControlPanelCommandClosesWindowWithoutTerminatingApp() {
        let delegate = AppDelegate()
        var closeRequests = 0
        delegate.registerMainWindowCloser {
            closeRequests += 1
        }

        delegate.closeControlPanel()

        #expect(closeRequests == 1)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @MainActor @Test
    func dockQuitClosesControlPanelAndKeepsMenuBarAppRunning() {
        let delegate = AppDelegate()
        var closeRequests = 0
        delegate.registerMainWindowCloser {
            closeRequests += 1
        }

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(reply == .terminateCancel)
        #expect(closeRequests == 1)
    }

    @MainActor @Test
    func explicitMenuQuitTerminatesApp() {
        var terminationRequests = 0
        let delegate = AppDelegate(
            terminationReasonProvider: { nil },
            terminationRequester: { terminationRequests += 1 }
        )
        var closeRequests = 0
        delegate.registerMainWindowCloser {
            closeRequests += 1
        }

        delegate.quitSpeakFlow()

        #expect(terminationRequests == 1)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(closeRequests == 0)
    }

    @MainActor @Test(arguments: [
        OSType(kAEQuitAll),
        OSType(kAEShutDown),
        OSType(kAERestart),
        OSType(kAEReallyLogOut)
    ])
    func systemTerminationStillTerminatesNormally(reason: OSType) {
        let delegate = AppDelegate(terminationReasonProvider: { reason })
        var closeRequests = 0
        delegate.registerMainWindowCloser {
            closeRequests += 1
        }

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(reply == .terminateNow)
        #expect(closeRequests == 0)
    }
}
