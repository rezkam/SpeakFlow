import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Microphone selection")
@MainActor
struct MicrophoneSelectionTests {
    let builtIn = MicrophoneDevice(id: 1, uid: "input-a", name: "Input A")
    let external = MicrophoneDevice(id: 2, uid: "input-b", name: "Input B")

    @Test func explicitSelectionOverridesDefault() {
        #expect(MicrophoneDevice.resolve(preferredUID: "input-b", devices: [builtIn, external], defaultID: 1) == external)
    }

    @Test func unavailablePreferenceFallsBackToDefault() {
        #expect(MicrophoneDevice.resolve(preferredUID: "missing", devices: [builtIn], defaultID: 1) == builtIn)
    }

    @Test func systemDefaultFollowsDefaultInput() {
        #expect(MicrophoneDevice.resolve(preferredUID: nil, devices: [builtIn, external], defaultID: 2) == external)
    }

    @Test func noUsableDefaultReturnsNil() {
        #expect(MicrophoneDevice.resolve(preferredUID: "missing", devices: [builtIn], defaultID: 99) == nil)
        #expect(MicrophoneDevice.resolve(preferredUID: nil, devices: [], defaultID: 1) == nil)
    }

    @Test func identicalNamesDoNotConfuseIdentity() {
        let duplicate = MicrophoneDevice(id: 3, uid: "input-c", name: "Input A")
        #expect(MicrophoneDevice.resolve(preferredUID: "input-c", devices: [builtIn, duplicate], defaultID: 1) == duplicate)
    }
    @Test func sessionKeepsFallbackUntilNextRecording() {
        var route = MicrophoneRoute(preferredUID: "input-b")
        #expect(route.resolve(.init(devices: [builtIn, external], defaultID: 1)) == external)
        #expect(route.resolve(.init(devices: [builtIn], defaultID: 1)) == builtIn)
        #expect(route.resolve(.init(devices: [builtIn, external], defaultID: 1)) == builtIn)
        var next = MicrophoneRoute(preferredUID: "input-b")
        #expect(next.resolve(.init(devices: [builtIn, external], defaultID: 1)) == external)
    }

    @Test func defaultModeTracksSystemChangesDuringCapture() {
        var route = MicrophoneRoute(preferredUID: nil)
        #expect(route.resolve(.init(devices: [builtIn, external], defaultID: 1)) == builtIn)
        #expect(route.resolve(.init(devices: [builtIn, external], defaultID: 2)) == external)
    }
    @Test func preferenceSurvivesRelaunchAndSystemDefaultClearsIt() throws {
        let defaults = try #require(UserDefaults(suiteName: "microphone.tests." + UUID().uuidString))
        let catalog = StubMicrophoneCatalog(.init(devices: [builtIn, external], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, defaults: defaults, monitor: false)
        selection.select("input-b")
        let relaunched = MicrophoneSelection(catalog: catalog, defaults: defaults, monitor: false)
        #expect(relaunched.preferredUID == "input-b")
        relaunched.select(nil)
        let reset = MicrophoneSelection(catalog: catalog, defaults: defaults, monitor: false)
        #expect(reset.preferredUID == nil)
        #expect(reset.resolvedDevice == builtIn)
    }

    @Test func manualChangesDoNotAlterRunningRoute() {
        let catalog = StubMicrophoneCatalog(.init(devices: [builtIn, external], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, preferredUID: "input-b", monitor: false)
        var route = MicrophoneRoute(preferredUID: selection.preferredUID)
        #expect(route.resolve(selection.snapshot) == external)
        selection.select(nil)
        #expect(route.resolve(selection.snapshot) == external)
        #expect(selection.resolvedDevice == builtIn)
    }

    @Test func unavailablePreferenceIsRetainedWhileCatalogChanges() {
        let catalog = StubMicrophoneCatalog(.init(devices: [builtIn], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, preferredUID: "input-b", monitor: false)
        #expect(selection.preferenceUnavailable)
        #expect(selection.resolvedDevice == builtIn)
        catalog.value = .init(devices: [builtIn, external], defaultID: 1)
        selection.refresh()
        #expect(!selection.preferenceUnavailable)
        #expect(selection.preferredUID == "input-b")
        #expect(selection.resolvedDevice == external)
    }

    @Test func captureStatusDistinguishesActualInputFromPreference() {
        let catalog = StubMicrophoneCatalog(.init(devices: [builtIn, external], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, preferredUID: "input-b", monitor: false)
        selection.captured(builtIn, fallback: true)
        #expect(selection.statusText(isRecording: true).contains("Recording with Input A"))
        #expect(selection.statusText(isRecording: true).contains("Switched to the system input"))
        selection.select("input-b")
        #expect(selection.activeDevice == builtIn)
    }

    @Test func catalogFailureDoesNotAdvertiseStaleDevices() {
        let catalog = StubMicrophoneCatalog(.init(devices: [builtIn], defaultID: 1))
        let selection = MicrophoneSelection(catalog: catalog, monitor: false)
        catalog.failure = true
        selection.refresh()
        #expect(selection.catalogFailed)
        #expect(selection.snapshot.devices.isEmpty)
        #expect(selection.resolvedDevice == nil)
    }
}

@MainActor
final class StubMicrophoneCatalog: MicrophoneCatalogProviding {
    var value: MicrophoneSnapshot
    var failure = false
    init(_ value: MicrophoneSnapshot) { self.value = value }
    func snapshot() throws -> MicrophoneSnapshot {
        if failure { throw MicrophoneError.unavailable }
        return value
    }
}
