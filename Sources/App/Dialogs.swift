import SwiftUI
import AppKit
import SpeakFlowCore

// MARK: - Accessibility Permission Dialog

struct AccessibilityPermissionView: View {
    let onResponse: (PermissionAlertResponse) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text("Enable Accessibility Access")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("This app needs Accessibility permission to type dictated text into other applications.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Label("Click **Open System Settings** below", systemImage: "1.circle.fill")
                    .font(.subheadline)
                Label("Find this app in the Accessibility list", systemImage: "2.circle.fill")
                    .font(.subheadline)
                Label("Click the toggle to turn it **on**", systemImage: "3.circle.fill")
                    .font(.subheadline)

                Divider()

                Text("You may need to unlock settings with your password first.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Button("Quit App", role: .destructive) {
                    onResponse(.quitApp)
                }

                Spacer()

                Button("Remind Me Later") {
                    onResponse(.remindLater)
                }
                .keyboardShortcut(.cancelAction)

                Button("Open System Settings") {
                    onResponse(.openSettings)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Deepgram API Key Dialog

struct DeepgramApiKeyView: View {
    let isUpdate: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var isSuccess = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text(isUpdate ? "Update Deepgram API Key" : "Enter Deepgram API Key")
                .font(.headline)

            Text("Get your API key from [console.deepgram.com](https://console.deepgram.com)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Paste your Deepgram API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { save() }
                .disabled(isValidating)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if isSuccess {
                Label("API key validated and saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isValidating)

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
            }

            if isValidating {
                ProgressView("Validating with Deepgram...")
                    .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isValidating = true
        errorMessage = nil
        isSuccess = false

        Task {
            let error = await ProviderSettings.shared.validateDeepgramKey(key)
            await MainActor.run {
                isValidating = false
                if let error {
                    errorMessage = error
                } else {
                    isSuccess = true
                    onSave(key)
                }
            }
        }
    }
}

// MARK: - Confirmation Dialog

struct ConfirmationView: View {
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(isDestructive ? .red : .blue)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(confirmTitle) { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .tint(isDestructive ? .red : .blue)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Text Input Dialog (for auth code paste)

struct TextInputView: View {
    let title: String
    let message: String
    let placeholder: String
    let submitTitle: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { submit() }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(submitTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSubmit(value)
    }
}

// MARK: - Simple Alert

struct AlertView: View {
    let title: String
    let message: String
    let style: AlertStyle
    let onDismiss: () -> Void

    enum AlertStyle {
        case info, success, error
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("OK") { onDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 320)
    }

    private var iconName: String {
        switch style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch style {
        case .info: .blue
        case .success: .green
        case .error: .red
        }
    }
}

// MARK: - Statistics View

struct StatisticsView: View {
    let summary: String
    let onReset: () -> Void
    let onDismiss: () -> Void

    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            Text("Transcription Statistics")
                .font(.headline)

            Text(summary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button("Reset...", role: .destructive) {
                    showResetConfirm = true
                }

                Spacer()

                Button("OK") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .confirmationDialog("Reset Statistics?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { onReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently reset all transcription statistics to zero.")
        }
    }
}

// MARK: - Window Presenter

/// Presents SwiftUI views as floating panel windows.
@MainActor
enum DialogPresenter {
    private static var currentWindow: NSWindow?
    private static var previousMainMenu: NSMenu?

    /// Install a temporary main menu with Edit items so ⌘V/⌘C/⌘X/⌘A work.
    /// Menu bar apps (LSUIElement) have no main menu, so keyboard shortcuts
    /// for text editing have no responder target without this.
    private static func installEditMenu() {
        previousMainMenu = NSApp.mainMenu

        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private static func removeEditMenu() {
        NSApp.mainMenu = previousMainMenu
        previousMainMenu = nil
    }

    static func showDeepgramApiKey(isUpdate: Bool, completion: @escaping (String?) -> Void) {
        let view = DeepgramApiKeyView(
            isUpdate: isUpdate,
            onSave: { key in
                completion(key)
                dismiss()
            },
            onCancel: {
                completion(nil)
                dismiss()
            }
        )
        present(view)
    }

    static func showConfirmation(
        title: String, message: String,
        confirmTitle: String = "Confirm",
        isDestructive: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        let view = ConfirmationView(
            title: title, message: message,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            onConfirm: { completion(true); dismiss() },
            onCancel: { completion(false); dismiss() }
        )
        present(view)
    }

    static func showTextInput(
        title: String, message: String,
        placeholder: String, submitTitle: String = "Submit",
        completion: @escaping (String?) -> Void
    ) {
        let view = TextInputView(
            title: title, message: message,
            placeholder: placeholder,
            submitTitle: submitTitle,
            onSubmit: { text in completion(text); dismiss() },
            onCancel: { completion(nil); dismiss() }
        )
        present(view)
    }

    static func showAlert(
        title: String, message: String,
        style: AlertView.AlertStyle = .info,
        completion: (() -> Void)? = nil
    ) {
        let view = AlertView(
            title: title, message: message, style: style,
            onDismiss: { completion?(); dismiss() }
        )
        present(view)
    }

    static func showAccessibilityPermission(completion: @escaping (PermissionAlertResponse) -> Void) {
        let view = AccessibilityPermissionView { response in
            completion(response)
            dismiss()
        }
        present(view)
    }

    static func showStatistics(summary: String, onReset: @escaping () -> Void) {
        let view = StatisticsView(
            summary: summary,
            onReset: { onReset(); dismiss() },
            onDismiss: { dismiss() }
        )
        present(view)
    }

    private static func present<V: View>(_ view: V) {
        dismiss()
        installEditMenu()

        let hosting = NSHostingController(rootView: view)
        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.isFloatingPanel = true
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()

        // Activate the app so the window can receive keyboard focus
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        currentWindow = window
    }

    static func dismiss() {
        currentWindow?.close()
        currentWindow = nil
        removeEditMenu()
    }
}
