import Foundation
import Observation
import SpeakFlowCore

@MainActor
@Observable
final class VADInstallController {
    private(set) var isInstalled = false
    private(set) var isBusy = false
    private(set) var message = "Checking local files..."
    private(set) var hasError = false
    var canDownload: Bool { !isInstalled && !isBusy }
    var confirmation: LocalModelManifest?
    private let root: URL
    private let verify: @Sendable (URL) async -> Result<URL, Error>
    private let installer: ExplicitModelInstaller
    private var download: Task<Void, Never>?
    private var verificationGeneration = UUID()

    init(root: URL = VADModelCache.modelCacheRoot(), installer: ExplicitModelInstaller? = nil,
         verify: @escaping @Sendable (URL) async -> Result<URL, Error> = { root in
             await Task.detached { Result { try LocalVADAssets.verifiedDirectory(root: root) } }.value
         }) {
        self.root = root
        self.verify = verify
        self.installer = installer ?? ExplicitModelInstaller(root: root)
    }

    func refresh() async {
        guard !isBusy else { return }
        let generation = UUID()
        verificationGeneration = generation
        let result = await verify(root)
        guard !isBusy, verificationGeneration == generation else { return }
        switch result {
        case .success:
            isInstalled = true
            hasError = false
            message = "Verified local files. No download is needed for recording."
        case .failure(let error):
            isInstalled = false
            hasError = (error as? LocalModelError) != .missingVAD
            message = (error as? LocalModelError)?.localizedDescription ?? LocalModelError.invalidAssets.localizedDescription
        }
    }

    func reviewDownload() {
        guard !isBusy, !isInstalled else { return }
        confirmation = LocalVADAssets.manifest
    }

    func confirmDownload() {
        guard let approved = confirmation, !isBusy, approved == LocalVADAssets.manifest else { return }
        confirmation = nil
        verificationGeneration = UUID()
        isBusy = true
        hasError = false
        message = "Downloading approved voice activity files..."
        download = Task {
            do {
                try await installer.install(approved, consent: approved) { [weak self] completed, total in
                    await MainActor.run { self?.message = "Downloaded \(completed) of \(total) bytes. Verifying files..." }
                }
                isInstalled = true
                message = "Downloaded and verified. Voice activity detection is available."
            } catch is CancellationError {
                message = "Download cancelled. Partial files are kept; nothing was installed."
            } catch {
                hasError = true
                message = (error as? LocalModelError)?.localizedDescription ?? LocalModelError.transferFailed.localizedDescription
            }
            isBusy = false
            download = nil
            AppState.shared.refresh()
        }
    }

    func cancelDownload() {
        download?.cancel()
        message = "Cancelling download..."
    }
}
