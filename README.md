# SpeakFlow

A macOS menu bar app that turns your voice into text — anywhere. Press a hotkey, speak naturally, and your words are transcribed and typed into whatever app you're using. Speech detection runs entirely on-device using a lightweight ML model, so only real speech is sent to the cloud for transcription.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## Features

- **Voice-to-text dictation** — press a hotkey, speak, text appears in any app
- **On-device voice activity detection** — a ~2M parameter model runs locally on Apple Silicon to distinguish speech from silence in real-time, with no audio leaving your machine until speech is confirmed
- **Smart chunking** — audio is split at natural sentence boundaries using silence detection, not arbitrary time cuts, so the transcriber always gets complete thoughts
- **Automatic turn detection** — when you stop speaking, SpeakFlow detects the silence and ends the session automatically — no need to press the hotkey again
- **Noise reduction** — silent and noise-only chunks are filtered out before transcription, saving API calls and improving accuracy
- **Universal text insertion** — transcribed text is typed into whatever app has focus via macOS Accessibility
- **ChatGPT OAuth login** — authenticate with your OpenAI account for Whisper API access
- **Configurable chunk duration** — 15 seconds to unlimited (full recording)
- **Launch at login** — runs quietly in the menu bar
- **Usage statistics** — track API calls, words transcribed, and audio processed

## Quick Start

### Prerequisites

- macOS 15.0+ on Apple Silicon
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
| Cancel recording | Escape |
| Stop and submit (press Enter) | Enter |

### Settings

- **Activation Hotkey** — Double-tap Control, Control+Option+D, Control+Option+Space, or Command+Shift+D
- **Chunk Duration** — 15s, 30s, 45s, 1m, 2m, 5m, 10m, 15m, or Unlimited
- **Skip Silent Chunks** — filter out silence-only audio before sending to API
- **Launch at Login**

## How It Works

1. **Recording** — audio is captured from your microphone at 16kHz
2. **On-device VAD** — a small (~2M parameter) voice activity detection model runs on Apple Silicon's Neural Engine to classify each audio frame as speech or silence
3. **Smart chunking** — when the configured chunk duration is reached, SpeakFlow waits for a natural pause in speech before splitting, so sentences aren't cut mid-word
4. **Auto-end** — if no speech is detected for 5 seconds after you stop talking, the session ends automatically
5. **Transcription** — speech chunks are sent to OpenAI's Whisper API; results are reassembled in order and typed into the focused app in real-time

## Development

```bash
# Debug
swift build
.build/debug/SpeakFlow

# Release
./scripts/build-release.sh

# Run all tests
make test

# Build + full test gate
make check

# UI test harness
./scripts/run-ui-tests.sh

# Live E2E (real microphone + real transcription API)
make test-live-e2e

# Live E2E auto-end timing suite
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
