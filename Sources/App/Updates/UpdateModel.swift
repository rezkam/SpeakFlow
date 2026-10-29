import Foundation
import Observation

/// App-owned presentation and approval state. Sparkle owns transfer and installation.
@MainActor @Observable
final class UpdateModel {
    enum Phase: String, CaseIterable {
        case idle, checking, available, downloading, extracting, ready, installing, current, failed, unavailable
    }

    private(set) var phase: Phase = .idle
    var version = ""
    var releaseNotes = ""
    var informationURL: URL?
    var expectedBytes: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var extractionProgress: Double = 0
    private(set) var message = ""
    private(set) var restartBlocked = false
    private(set) var installationAuthorized = false
    var lastChecked: Date?
    var navigationRequest = 0
    @ObservationIgnored private var downloadAction: (() -> Void)?
    @ObservationIgnored private var installAction: (() -> Void)?
    @ObservationIgnored private var cancelAction: (() -> Void)?
    @ObservationIgnored private var retryAction: (() -> Void)?
    @ObservationIgnored private var skipAction: (() -> Void)?
    @ObservationIgnored private let isBusy: () -> Bool

    init(isBusy: @escaping () -> Bool = { false }) { self.isBusy = isBusy }

    var downloadProgress: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    var hasUpdate: Bool { [.available, .downloading, .extracting, .ready, .installing].contains(phase) }
    var canCancel: Bool { cancelAction != nil }
    var canSkip: Bool { skipAction != nil }
    var canRestart: Bool { phase == .ready && !isBusy() }
    var isSessionActive: Bool { [.checking, .available, .downloading, .extracting, .ready, .installing].contains(phase) }
    var permitsUpdateTermination: Bool { installationAuthorized && !isBusy() }

    func checking(cancel: @escaping () -> Void) {
        clearActions()
        resetProgress()
        phase = .checking
        message = ""
        cancelAction = cancel
    }

    func offer(version: String, notes: String, download: @escaping () -> Void,
               cancel: (() -> Void)? = nil, skip: (() -> Void)? = nil) {
        clearActions()
        resetProgress()
        self.version = version
        releaseNotes = notes
        informationURL = nil
        message = ""
        phase = .available
        lastChecked = Date()
        downloadAction = download
        cancelAction = cancel
        skipAction = skip
    }

    func download() {
        guard phase == .available, informationURL == nil, let action = downloadAction else { return }
        clearActions()
        phase = .downloading
        action()
    }

    func downloading(cancel: @escaping () -> Void) {
        clearActions()
        resetProgress()
        phase = .downloading
        cancelAction = cancel
    }

    func extracting() {
        clearActions()
        phase = .extracting
        extractionProgress = 0
    }

    func ready(cancel: (() -> Void)? = nil, install: @escaping () -> Void) {
        clearActions()
        phase = .ready
        installAction = install
        cancelAction = cancel
    }

    func install() {
        guard phase == .ready, let action = installAction else { return }
        guard !isBusy() else { restartBlocked = true; return }
        clearActions()
        installationAuthorized = true
        phase = .installing
        action()
    }

    func installing(retry: @escaping () -> Void) {
        retryAction = retry
    }

    func terminationDenied() {
        guard let retry = retryAction else {
            fail("Finish dictation, then try updating again.")
            return
        }
        ready(install: retry)
        restartBlocked = true
    }

    func cancel() {
        guard let action = cancelAction else { return }
        clearActions()
        resetProgress()
        phase = .idle
        action()
    }

    func skip() {
        guard let action = skipAction else { return }
        clearActions()
        resetProgress()
        phase = .idle
        action()
    }

    func upToDate() {
        clearActions()
        phase = .current
        lastChecked = Date()
        message = ""
    }

    func fail(_ message: String) {
        clearActions()
        phase = .failed
        self.message = message
    }

    func unavailable(_ message: String) {
        clearActions()
        phase = .unavailable
        self.message = message
    }

    func finishSession() {
        clearActions()
        resetProgress()
        if isSessionActive { phase = .idle }
    }

    private func clearActions() {
        downloadAction = nil
        installAction = nil
        cancelAction = nil
        skipAction = nil
        retryAction = nil
        restartBlocked = false
        installationAuthorized = false
    }

    private func resetProgress() {
        expectedBytes = 0
        receivedBytes = 0
        extractionProgress = 0
    }
}
