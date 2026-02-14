/// Abstraction over UI state synchronization and banner display.
///
/// Allows RecordingController to be tested without the real AppState singleton.
@MainActor
protocol BannerPresenting: AnyObject {
    func showBanner(_ message: String, style: AppState.BannerStyle, duration: Double)
    func refresh()
    var isRecording: Bool { get set }
    var isProcessingFinal: Bool { get set }
}

extension BannerPresenting {
    func showBanner(_ message: String, style: AppState.BannerStyle = .info) {
        showBanner(message, style: style, duration: 4)
    }
}
