import AppKit
import Sparkle

/// Bridges every updater interaction into the settings page without a second installer UI.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    let model: UpdateModel
    private let present: () -> Void

    init(model: UpdateModel, present: @escaping () -> Void) {
        self.model = model
        self.present = present
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Distribution metadata enables checks, disables automatic installs and profiling.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.checking(cancel: cancellation)
        present()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.offer(
            version: appcastItem.displayVersionString,
            notes: ReleaseNotesText.decode(appcastItem.itemDescription ?? "", format: appcastItem.itemDescriptionFormat),
            download: { reply(.install) }, cancel: { reply(.dismiss) }, skip: { reply(.skip) }
        )
        if appcastItem.isInformationOnlyUpdate {
            model.informationURL = appcastItem.infoURL.flatMap { $0.scheme == "https" ? $0 : nil }
            if model.informationURL == nil {
                reply(.dismiss)
                model.fail("This release cannot be installed in the app. Check the release website for details.")
            }
        } else if state.stage == .installing {
            model.ready(cancel: { reply(.skip) }, install: { reply(.install) })
        }
        if state.userInitiated { present() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let text = String(data: downloadData.data, encoding: .utf8) ?? ""
        model.releaseNotes = ReleaseNotesText.decode(text, format: downloadData.mimeType)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        model.releaseNotes = "Release notes could not be loaded. You can still download the verified update."
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        model.upToDate()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // Do not surface arbitrary server paths or error payloads in the product.
        model.fail("Couldn’t complete the update. Check your connection and available disk space, then try again.")
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { model.downloading(cancel: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { model.expectedBytes = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = model.receivedBytes.addingReportingOverflow(length)
        model.receivedBytes = overflow ? UInt64.max : total
    }
    func showDownloadDidStartExtractingUpdate() { model.extracting() }
    func showExtractionReceivedProgress(_ progress: Double) {
        model.extractionProgress = progress.isFinite ? min(1, max(0, progress)) : 0
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.ready(cancel: { reply(.skip) }, install: { reply(.install) })
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !applicationTerminated { model.installing(retry: retryTerminatingApplication) }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        model.upToDate()
        acknowledgement()
    }
    func dismissUpdateInstallation() { model.finishSession() }
    func showUpdateInFocus() { present() }
}

/// Release content is rendered as text, never as executable HTML or remote web content.
enum ReleaseNotesText {
    static func decode(_ text: String, format: String?) -> String {
        guard format == nil || format?.contains("html") == true else { return String(text.prefix(50_000)) }
        return String(text.prefix(50_000))
            .replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
