import AppKit
import ApplicationServices
import Testing
import os
@testable import SpeakFlow

@Suite("Application accessibility preparation", .serialized)
struct ApplicationAccessibilityPreparationTests {
    @Test func requestsDocumentedManualAccessibilityEvenWithoutAnEnhancedAttribute() {
        var requests: [String] = []
        _ = TargetCaptureAccessibility.prepareApplication(100_001) { _, attribute, value in
            requests.append(attribute as String)
            #expect(CFGetTypeID(value) == CFBooleanGetTypeID())
            #expect((value as? NSNumber)?.boolValue == true)
            return .success
        }
        #expect(requests == ["AXManualAccessibility"])
    }

    @MainActor @Test func preparationRunsBeforeTheHotkeyWithoutBlockingTheMainActor() async {
        let started = OSAllocatedUnfairLock(initialState: false)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let warmer = ApplicationAccessibilityPrewarmer(
            center: NotificationCenter(), frontmostPid: { 100_001 }, isAllowed: { true },
            prepare: { _ in
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                finished.withLock { $0 = true }
            }
        )
        defer { release.signal(); warmer.stop() }
        warmer.start()
        #expect(await eventually { started.withLock { $0 } })
        #expect(!finished.withLock { $0 }, "App preparation must not block the main actor waiting for AX")
        release.signal()
        #expect(await eventually { finished.withLock { $0 } })
    }

    @MainActor @Test func appActivationPreparesOnlyTheCurrentAppAndStopRetiresNotifications() async {
        let center = NotificationCenter()
        let requests = OSAllocatedUnfairLock(initialState: [pid_t]())
        var currentPid: pid_t = 100_001
        let warmer = ApplicationAccessibilityPrewarmer(
            center: center, frontmostPid: { currentPid }, isAllowed: { true },
            prepare: { pid in requests.withLock { $0.append(pid) } }
        )
        warmer.start()
        #expect(await eventually { requests.withLock { $0 == [100_001] } })
        currentPid = 100_002
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(await eventually { requests.withLock { $0 == [100_001, 100_002] } })
        warmer.stop()
        currentPid = 100_003
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await Task.yield()
        #expect(requests.withLock { $0 == [100_001, 100_002] })
    }

    @MainActor @Test func defaultPolicyDoesNotPrepareLiveAppsInTestProcesses() async {
        let requests = OSAllocatedUnfairLock(initialState: [pid_t]())
        let warmer = ApplicationAccessibilityPrewarmer(
            center: NotificationCenter(), frontmostPid: { 100_001 },
            prepare: { pid in requests.withLock { $0.append(pid) } }
        )
        warmer.start()
        await Task.yield()
        warmer.stop()
        #expect(requests.withLock { $0.isEmpty })
    }

    @MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
