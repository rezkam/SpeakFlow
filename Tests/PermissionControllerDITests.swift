import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - PermissionController DI Behavioral Tests

@Suite("PermissionController — DI Behavioral Contracts")
struct PermissionControllerDITests {

    @Test @MainActor
    func checkAccessibilityRefreshesState() {
        let spyBanner = SpyBannerPresenter()
        let spyHK = SpyHotkeySettings()

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: spyHK,
            setupHotkeyAction: {}
        )

        controller.checkAccessibility()

        // checkAccessibility always calls refresh regardless of trust status
        #expect(spyBanner.refreshCount > 0)
    }

    @Test @MainActor
    func setupHotkeyDelegatesToInjectedAction() {
        let spyBanner = SpyBannerPresenter()
        let spyHK = SpyHotkeySettings()
        var setupCalled = false

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: spyHK,
            setupHotkeyAction: { setupCalled = true }
        )

        // The delegate method setupHotkey() calls the injected action
        controller.setupHotkey()

        #expect(setupCalled)
    }

    @Test @MainActor
    func grantedAlertUsesInjectedHotkeyDisplayName() {
        let spyBanner = SpyBannerPresenter()
        let spyHK = SpyHotkeySettings()
        spyHK.currentHotkey = .doubleTapControl

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: spyHK,
            setupHotkeyAction: {}
        )

        controller.showAccessibilityGrantedAlert()

        let lastMessage = spyBanner.bannerMessages.last
        #expect(lastMessage != nil)
        // displayName for .doubleTapControl is "⌃⌃ (double-tap)"
        #expect(lastMessage?.0.contains("double-tap") == true)
        #expect(lastMessage?.1 == .success)
    }

    @Test @MainActor
    func grantedAlertRefreshesState() {
        let spyBanner = SpyBannerPresenter()

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: SpyHotkeySettings(),
            setupHotkeyAction: {}
        )

        controller.showAccessibilityGrantedAlert()

        #expect(spyBanner.refreshCount > 0)
    }

    @Test @MainActor
    func checkInitialPermissionsRefreshesState() {
        let spyBanner = SpyBannerPresenter()

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: SpyHotkeySettings(),
            setupHotkeyAction: {}
        )

        controller.checkInitialPermissions()

        #expect(spyBanner.refreshCount > 0)
    }

    @Test @MainActor
    func updateStatusIconRefreshesState() {
        let spyBanner = SpyBannerPresenter()

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: SpyHotkeySettings(),
            setupHotkeyAction: {}
        )

        // AccessibilityPermissionDelegate callback
        controller.updateStatusIcon()

        #expect(spyBanner.refreshCount > 0)
    }

    @Test @MainActor
    func permissionAlertShowsBannerAndReturnsOpenSettings() async {
        let spyBanner = SpyBannerPresenter()

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: SpyHotkeySettings(),
            setupHotkeyAction: {}
        )

        let response = await controller.showAccessibilityPermissionAlert()

        #expect(response == .openSettings)
        #expect(spyBanner.bannerMessages.contains(where: { $0.1 == .info }))
    }
}
