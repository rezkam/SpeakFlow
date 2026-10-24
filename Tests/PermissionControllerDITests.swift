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
    func grantedAlertShowsSuccessBanner() {
        let spyBanner = SpyBannerPresenter()

        let controller = PermissionController(
            appState: spyBanner,
            hotkeySettings: SpyHotkeySettings(),
            setupHotkeyAction: {}
        )

        controller.showAccessibilityGrantedAlert()

        let lastMessage = spyBanner.bannerMessages.last
        #expect(lastMessage != nil)
        #expect(lastMessage?.0.contains("Accessibility") == true)
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

/// A grant that arrives after the bounded permission poll gave up must still
/// re-register the hotkey once SpeakFlow observes it.
@Suite("PermissionController — Late Accessibility Grant")
struct PermissionControllerLateGrantTests {
    @MainActor
    private func make(trusted: @escaping () -> Bool, setups: @escaping () -> Void) -> PermissionController {
        PermissionController(
            appState: SpyBannerPresenter(),
            hotkeySettings: SpyHotkeySettings(),
            setupHotkeyAction: setups,
            isAccessibilityTrusted: trusted
        )
    }

    @Test @MainActor
    func explicitCheckAfterALateGrantReRegistersTheHotkey() {
        var trusted = false
        var setups = 0
        let controller = make(trusted: { trusted }, setups: { setups += 1 })

        trusted = true
        controller.checkAccessibility()
        controller.checkAccessibility()

        #expect(setups == 1, "The first check that sees the grant re-registers the hotkey, once")
    }

    @Test @MainActor
    func recordingReadinessCheckAfterALateGrantReRegistersTheHotkey() {
        var trusted = false
        var setups = 0
        let controller = make(trusted: { trusted }, setups: { setups += 1 })

        trusted = true
        #expect(controller.isAccessibilityReady())
        #expect(setups == 1)
    }

    @Test @MainActor
    func appActivationAfterALateGrantReRegistersTheHotkey() {
        var trusted = false
        var setups = 0
        let controller = make(trusted: { trusted }, setups: { setups += 1 })

        trusted = true
        controller.reconcileAccessibility()

        #expect(setups == 1)
    }

    @Test @MainActor
    func alreadyTrustedAtLaunchDoesNotReRegisterAgain() {
        var setups = 0
        let controller = make(trusted: { true }, setups: { setups += 1 })

        controller.checkAccessibility()
        controller.reconcileAccessibility()

        #expect(setups == 0, "Launch registers the hotkey already; no transition, no extra setup")
    }
}
