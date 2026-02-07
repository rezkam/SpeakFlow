# SpeakFlow

A macOS menu bar app for voice dictation using OpenAI's Whisper API. Press a hotkey, speak, and your transcribed text is automatically typed into any application.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- Voice-to-text dictation with hotkey
- Universal text insertion via accessibility
- ChatGPT OAuth login
- Configurable chunking (30s - 1 hour)
- Smart silence detection
- Launch at login
- Usage statistics

## Quick Start

### Prerequisites

- macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`)
- OpenAI Pro or Max subscription

### Build & Install

```bash
git clone https://github.com/rezkam/SpeakFlow.git
cd SpeakFlow
./scripts/build-release.sh
cp -r SpeakFlow.app /Applications/
open /Applications/SpeakFlow.app
```

## Required Permissions

### Microphone Access

Required to record your voice. Grant when prompted, or enable in **System Settings → Privacy & Security → Microphone**.

### Accessibility Access

Required to insert text into applications.

1. Open **System Settings → Privacy & Security → Accessibility**
2. Enable **SpeakFlow**
3. Restart the app

> **Note:** Rebuilding the app resets this permission.

### ChatGPT Login

1. Click menu bar icon → "Login to ChatGPT..."
2. Log in via browser
3. Redirects back automatically

## Usage

| Action | Hotkey |
|--------|--------|
| Start/Stop dictation | Double-tap Control |

### Settings

- **Activation Hotkey** - Double-tap Control, Control+Option+D, Control+Option+Space, or Command+Shift+D
- **Chunk Duration** - 30s to 1 hour
- **Skip Silent Chunks** - Save API calls
- **Launch at Login**

## Development

```bash
# Debug
swift build
.build/debug/SpeakFlow

# Release
./scripts/build-release.sh

# Run all tests (core + swift + UI E2E)
make test

# Build + full test gate
make check

# UI test harness (requires full Xcode + UI test target setup)
./scripts/run-ui-tests.sh

# Live E2E (real microphone + real transcription API)
make test-live-e2e

# Live E2E auto-end timing suite (short/long/pause/very-long speech)
make test-live-e2e-autoend
```

`make test` and `make check` print concise status lines and always write full logs to a temp file (path printed as `Log: ...`).

See `UITests/README.md` for one-time Xcode UI Testing Bundle setup required by UI E2E tests.

## Troubleshooting

### Accessibility Permission Required

Open **System Settings → Privacy & Security → Accessibility**, enable SpeakFlow, restart app.

### Text not inserting

Check accessibility permission, ensure target app has focus.

### Microphone not working

Enable in **System Settings → Privacy & Security → Microphone**, restart app.

### Login issues

Ensure active OpenAI Pro/Max subscription. Try logout and login again.

## License

MIT License
