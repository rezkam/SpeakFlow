import AppKit
import Observation
import Sparkle

@MainActor @Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()
    let model: UpdateModel
    private(set) var canCheck = false
    private(set) var automaticChecks = true
    @ObservationIgnored var presentWindow: (() -> Void)?
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: UpdateUserDriver?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastCheckObservation: NSKeyValueObservation?

    override init() {
        model = UpdateModel(isBusy: {
            let recording = RecordingController.shared
            return recording.isRecording || recording.isProcessingFinal || recording.textInserter.pendingTask != nil
        })
        super.init()
    }

    func start(bundle: Bundle = .main) {
        guard updater == nil else { return }
        guard bundle.object(forInfoDictionaryKey: "SpeakFlowUpdatesEnabled") as? Bool == true,
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              UpdateVerification.acceptsFeed(feed),
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            model.unavailable("Updates are available in the signed distribution of SpeakFlow.")
            return
        }
        let driver = UpdateUserDriver(model: model, present: { [weak self] in self?.showUpdates() })
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        self.driver = driver
        self.updater = updater
        do {
            try updater.start()
            automaticChecks = updater.automaticallyChecksForUpdates
            canCheck = updater.canCheckForUpdates
            checkObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor in self?.canCheck = enabled }
            }
            automaticObservation = updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor in self?.automaticChecks = enabled }
            }
            lastCheckObservation = updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                let date = change.newValue ?? nil
                Task { @MainActor in self?.model.lastChecked = date }
            }
        } catch {
            model.fail("The updater could not start. Reinstall the latest signed version and try again.")
        }
    }

    func showUpdates() {
        model.navigationRequest += 1
        presentWindow?()
    }

    func check() {
        showUpdates()
        guard canCheck, !model.isSessionActive else { return }
        updater?.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticChecks = updater.automaticallyChecksForUpdates
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        model.permitsUpdateTermination
    }
}
