import Testing
@testable import SpeakFlow

@MainActor
final class SpyBannerPresenter: BannerPresenting {
    var isRecording = false
    var isProcessingFinal = false
    var bannerMessages: [(String, AppState.BannerStyle)] = []
    var refreshCount = 0
    var dismissCount = 0

    func showBanner(_ message: String, style: AppState.BannerStyle, duration: Double) {
        bannerMessages.append((message, style))
    }

    func dismissBanner() { dismissCount += 1 }

    func refresh() { refreshCount += 1 }
}
