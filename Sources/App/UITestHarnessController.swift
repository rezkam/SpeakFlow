import AppKit
import SpeakFlowCore

@MainActor
final class UITestHarnessController: NSWindowController, NSWindowDelegate {
    var onStartClicked: (() -> Void)?
    var onStopClicked: (() -> Void)?
    var onHotkeyTriggered: ((HotkeyType?) -> Void)?
    var onNextHotkeyClicked: (() -> Void)?
    var onSeedStatsClicked: (() -> Void)?
    var onResetStatsClicked: (() -> Void)?

    private let statusValueLabel = NSTextField(labelWithString: String(localized: "idle"))
    private let toggleCountValueLabel = NSTextField(labelWithString: "0")
    private let modeValueLabel = NSTextField(labelWithString: String(localized: "mock"))
    private let hotkeyValueLabel = NSTextField(labelWithString: String(localized: "⌃⌃ (double-tap)"))
    private let statsApiCallsValueLabel = NSTextField(labelWithString: "0")
    private let statsWordsValueLabel = NSTextField(labelWithString: "0")
    private var localKeyMonitor: Any?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "SpeakFlow UI Test Harness")
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()
        setupLocalHotkeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    func updateState(
        isRecording: Bool,
        toggleCount: Int,
        mode: String,
        hotkeyDisplay: String,
        statsApiCalls: Int,
        statsWords: Int
    ) {
        statusValueLabel.stringValue = isRecording ? String(localized: "recording") : String(localized: "idle")
        toggleCountValueLabel.stringValue = String(toggleCount)
        modeValueLabel.stringValue = mode
        hotkeyValueLabel.stringValue = hotkeyDisplay
        statsApiCallsValueLabel.stringValue = String(statsApiCalls)
        statsWordsValueLabel.stringValue = String(statsWords)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: String(localized: "UI Harness"))
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let hintLabel = NSTextField(labelWithString: String(localized: "Hotkey in harness: ⌃⌥D / ⌘⇧D / ⌃⌥Space"))
        hintLabel.textColor = .secondaryLabelColor

        let statusLabel = NSTextField(labelWithString: String(localized: "Status:"))
        let toggleCountLabel = NSTextField(labelWithString: String(localized: "Toggle Count:"))
        let modeLabel = NSTextField(labelWithString: String(localized: "Recording Mode:"))
        let hotkeyLabel = NSTextField(labelWithString: String(localized: "Current Hotkey:"))
        let statsApiCallsLabel = NSTextField(labelWithString: String(localized: "Stats API Calls:"))
        let statsWordsLabel = NSTextField(labelWithString: String(localized: "Stats Words:"))

        statusValueLabel.setAccessibilityIdentifier("ui_test.status_value")
        statusValueLabel.setAccessibilityLabel("Current recording status value")
        toggleCountValueLabel.setAccessibilityIdentifier("ui_test.toggle_count_value")
        toggleCountValueLabel.setAccessibilityLabel("Number of hotkey toggles")
        modeValueLabel.setAccessibilityIdentifier("ui_test.mode_value")
        modeValueLabel.setAccessibilityLabel("Current recording mode value")
        hotkeyValueLabel.setAccessibilityIdentifier("ui_test.hotkey_value")
        hotkeyValueLabel.setAccessibilityLabel("Current hotkey value")
        statsApiCallsValueLabel.setAccessibilityIdentifier("ui_test.stats_api_calls_value")
        statsApiCallsValueLabel.setAccessibilityLabel("Current API call count value")
        statsWordsValueLabel.setAccessibilityIdentifier("ui_test.stats_words_value")
        statsWordsValueLabel.setAccessibilityLabel("Current transcribed word count value")

        let startButton = NSButton(title: String(localized: "Start Dictation"), target: self, action: #selector(startClicked))
        startButton.setAccessibilityIdentifier("ui_test.start_button")
        startButton.setAccessibilityLabel(String(localized: "Start dictation"))
        let stopButton = NSButton(title: String(localized: "Stop Dictation"), target: self, action: #selector(stopClicked))
        stopButton.setAccessibilityIdentifier("ui_test.stop_button")
        stopButton.setAccessibilityLabel(String(localized: "Stop dictation"))
        let hotkeyButton = NSButton(title: String(localized: "Trigger Hotkey"), target: self, action: #selector(hotkeyClicked))
        hotkeyButton.setAccessibilityIdentifier("ui_test.hotkey_button")
        hotkeyButton.setAccessibilityLabel(String(localized: "Trigger configured hotkey"))
        let nextHotkeyButton = NSButton(title: String(localized: "Next Hotkey"), target: self, action: #selector(nextHotkeyClicked))
        nextHotkeyButton.setAccessibilityIdentifier("ui_test.next_hotkey_button")
        nextHotkeyButton.setAccessibilityLabel(String(localized: "Cycle to next hotkey option"))
        let seedStatsButton = NSButton(title: String(localized: "Seed Stats"), target: self, action: #selector(seedStatsClicked))
        seedStatsButton.setAccessibilityIdentifier("ui_test.seed_stats_button")
        seedStatsButton.setAccessibilityLabel(String(localized: "Seed sample statistics"))
        let resetStatsButton = NSButton(title: String(localized: "Reset Stats"), target: self, action: #selector(resetStatsClicked))
        resetStatsButton.setAccessibilityIdentifier("ui_test.reset_stats_button")
        resetStatsButton.setAccessibilityLabel(String(localized: "Reset statistics"))

        let headerStack = NSStackView(views: [titleLabel, hintLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        let statusRow = NSStackView(views: [statusLabel, statusValueLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .firstBaseline

        let countRow = NSStackView(views: [toggleCountLabel, toggleCountValueLabel])
        countRow.orientation = .horizontal
        countRow.spacing = 8
        countRow.alignment = .firstBaseline

        let modeRow = NSStackView(views: [modeLabel, modeValueLabel])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        modeRow.alignment = .firstBaseline

        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyValueLabel])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        hotkeyRow.alignment = .firstBaseline

        let statsApiCallsRow = NSStackView(views: [statsApiCallsLabel, statsApiCallsValueLabel])
        statsApiCallsRow.orientation = .horizontal
        statsApiCallsRow.spacing = 8
        statsApiCallsRow.alignment = .firstBaseline

        let statsWordsRow = NSStackView(views: [statsWordsLabel, statsWordsValueLabel])
        statsWordsRow.orientation = .horizontal
        statsWordsRow.spacing = 8
        statsWordsRow.alignment = .firstBaseline

        let controlRow = NSStackView(views: [startButton, stopButton, hotkeyButton])
        controlRow.orientation = .horizontal
        controlRow.spacing = 10
        controlRow.distribution = .fillEqually

        let settingsRow = NSStackView(views: [nextHotkeyButton, seedStatsButton, resetStatsButton])
        settingsRow.orientation = .horizontal
        settingsRow.spacing = 10
        settingsRow.distribution = .fillEqually

        let rootStack = NSStackView(
            views: [
                headerStack,
                statusRow,
                countRow,
                modeRow,
                hotkeyRow,
                statsApiCallsRow,
                statsWordsRow,
                controlRow,
                settingsRow
            ]
        )
        rootStack.orientation = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        contentView.addSubview(rootStack)
        contentView.setAccessibilityIdentifier("ui_test.window")
        contentView.setAccessibilityLabel("SpeakFlow UI test harness window")

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            controlRow.heightAnchor.constraint(equalToConstant: 32),
            settingsRow.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setupLocalHotkeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let hotkey = self.mappedHarnessHotkey(event) {
                self.onHotkeyTriggered?(hotkey)
                return nil
            }
            return event
        }
    }

    private func mappedHarnessHotkey(_ event: NSEvent) -> HotkeyType? {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let keyCode = event.keyCode

        if flags == [.control, .option] && keyCode == 2 {
            return .controlOptionD
        }
        if flags == [.control, .option] && keyCode == 49 {
            return .controlOptionSpace
        }
        if flags == [.command, .shift] && keyCode == 2 {
            return .commandShiftD
        }
        return nil
    }

    @objc private func startClicked() {
        onStartClicked?()
    }

    @objc private func stopClicked() {
        onStopClicked?()
    }

    @objc private func hotkeyClicked() {
        onHotkeyTriggered?(nil)
    }

    @objc private func nextHotkeyClicked() {
        onNextHotkeyClicked?()
    }

    @objc private func seedStatsClicked() {
        onSeedStatsClicked?()
    }

    @objc private func resetStatsClicked() {
        onResetStatsClicked?()
    }
}
