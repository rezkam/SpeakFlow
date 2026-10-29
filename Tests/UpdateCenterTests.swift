import AppKit
import Sparkle
import Testing
@testable import SpeakFlow

@Suite("Update center")
struct UpdateCenterTests {
    @Test func productionFeedRequiresHTTPSAndNoCredentials() {
        #expect(UpdateVerification.acceptsFeed("https://example.com/appcast.xml"))
        #expect(!UpdateVerification.acceptsFeed("http://example.com/appcast.xml"))
        #expect(!UpdateVerification.acceptsFeed("https:///appcast.xml"))
        #expect(!UpdateVerification.acceptsFeed("https://user:secret@example.com/appcast.xml"))
        #expect(!UpdateVerification.acceptsFeed("https://example.com/appcast.xml#fragment"))
        #expect(!UpdateVerification.acceptsFeed("file:///appcast.xml"))
    }

    @MainActor @Test func downloadRequiresExplicitApprovalAndIsOneShot() {
        let model = UpdateModel()
        var downloads = 0
        model.offer(version: "2.0", notes: "Improvements", download: { downloads += 1 })
        #expect(downloads == 0)
        #expect(model.phase == .available)
        model.download()
        model.download()
        #expect(downloads == 1)
    }

    @MainActor @Test func busyRestartKeepsApprovalPendingUntilAnotherClick() {
        var busy = true
        var installs = 0
        let model = UpdateModel(isBusy: { busy })
        model.ready { installs += 1 }
        model.install()
        #expect(installs == 0)
        #expect(model.phase == .ready)
        #expect(model.restartBlocked)
        busy = false
        #expect(installs == 0)
        model.install()
        model.install()
        #expect(installs == 1)
        #expect(model.installationAuthorized)
    }

    @MainActor @Test func failureRevokesTerminationAndCanBeRetried() {
        let model = UpdateModel()
        model.ready {}
        model.install()
        #expect(model.installationAuthorized)
        model.fail("Could not install the update.")
        #expect(!model.installationAuthorized)
        #expect(model.phase == .failed)
        #expect(model.message == "Could not install the update.")
    }

    @MainActor @Test func cancellationIsOneShotAndClearsDownloadProgress() {
        let model = UpdateModel()
        var cancellations = 0
        model.downloading(cancel: { cancellations += 1 })
        model.expectedBytes = 100
        model.receivedBytes = 40
        #expect(model.downloadProgress == 0.4)
        model.cancel()
        model.cancel()
        #expect(cancellations == 1)
        #expect(model.phase == .idle)
        #expect(model.downloadProgress == nil)
    }

    @MainActor @Test func unknownOrInvalidProgressDoesNotInventAPercentage() {
        let model = UpdateModel()
        model.receivedBytes = 100
        #expect(model.downloadProgress == nil)
        model.expectedBytes = 20
        #expect(model.downloadProgress == 1)
    }

    @MainActor @Test func cleanupPreservesUsefulTerminalResults() {
        let model = UpdateModel()
        model.fail("Try again.")
        model.finishSession()
        #expect(model.phase == .failed)
        model.upToDate()
        model.finishSession()
        #expect(model.phase == .current)
    }
}

@Suite("Update integration")
struct UpdateIntegrationTests {
    @MainActor @Test func approvedUpdateTerminationBypassesClosePanel() {
        let model = UpdateModel()
        let delegate = AppDelegate()
        delegate.updateModel = model
        var closes = 0
        delegate.registerMainWindowCloser { closes += 1 }
        model.ready {}
        model.install()
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(closes == 0)
    }

    @MainActor @Test func busyUpdateTerminationIsDeniedAndCanRetry() {
        var busy = false
        let model = UpdateModel(isBusy: { busy })
        let delegate = AppDelegate()
        delegate.updateModel = model
        var retries = 0
        model.ready {}
        model.install()
        model.installing(retry: { retries += 1 })
        busy = true
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!model.installationAuthorized)
        busy = false
        model.install()
        #expect(retries == 1)
    }

    @MainActor @Test func approvedInstallationRejectsNewDictation() {
        let (recording, _, _, _) = makeTestRecordingController()
        recording.testMode = .mock
        recording.updateInstallationInProgress = { true }
        recording.startRecording()
        #expect(!recording.isRecording)
    }

    @MainActor @Test func driverReadyWaitsForApprovalAndCancelDoesNotInstall() {
        let model = UpdateModel()
        let driver = UpdateUserDriver(model: model, present: {})
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices.isEmpty)
        model.cancel()
        #expect(choices == [.skip])
        model.install()
        #expect(choices.count == 1)
    }

    @MainActor @Test func driverTransferHandlesUnknownLengthOverflowAndExtraction() {
        let model = UpdateModel()
        let driver = UpdateUserDriver(model: model, present: {})
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveData(ofLength: UInt64.max)
        driver.showDownloadDidReceiveData(ofLength: 1)
        #expect(model.receivedBytes == UInt64.max)
        #expect(model.downloadProgress == nil)
        driver.showDownloadDidReceiveExpectedContentLength(200)
        #expect(model.downloadProgress == 1)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(.nan)
        #expect(model.phase == .extracting)
        #expect(model.extractionProgress == 0)
    }

    @Test func releaseNotesAreTextWithoutScriptsOrRemoteImages() {
        let html = "<h2>Changes</h2><script>alert(1)</script><p>Fast &amp; reliable</p><img src='https://example.com/a.png'>"
        #expect(ReleaseNotesText.decode(html, format: "html") == "Changes\nFast & reliable")
        #expect(ReleaseNotesText.decode("Use <Escape>", format: "plain-text") == "Use <Escape>")
    }
}
