# SpeakFlow

A macOS menu bar app for voice dictation using OpenAI's Whisper API. Press a hotkey, speak, and your transcribed text is automatically typed into any application.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- 🎤 **Voice-to-text dictation** - Press hotkey to start, press again to stop
- ⌨️ **Universal text insertion** - Works in any app via accessibility
- 🔐 **ChatGPT OAuth login** - Secure authentication (same as Codex CLI)
- ⚡ **Configurable chunking** - 30s to 7min chunks, or full recording
- 🔇 **Smart silence detection** - Skips silent audio to save API calls
- 🚀 **Launch at login** - Optional auto-start
- 📊 **Usage statistics** - Track transcription duration, words, characters, and API calls

## Quick Start

### Prerequisites

- macOS 13.0 or later
- Swift 5.9+ (comes with Xcode 15+)
- **OpenAI Pro or Max subscription** (required for API access)

### Build & Install

```bash
# Clone the repository
git clone https://github.com/rezkam/SpeakFlow.git
cd SpeakFlow

# Build and create DMG (one command does everything)
./scripts/build-release.sh

# Install
open SpeakFlow.dmg
# Drag SpeakFlow.app to Applications
```

### First Run

1. **Launch SpeakFlow** from Applications
2. **Grant Microphone permission** when prompted
3. **Grant Accessibility permission** (required for text insertion)
4. **Login to ChatGPT** via the menu bar icon → "Login to ChatGPT..."
5. **Start dictating!** Double-tap Control (or your configured hotkey)

## Usage

| Action | Default Hotkey |
|--------|---------------|
| Start/Stop dictation | Double-tap Control |

Press the hotkey once to start recording, press it again to stop.

### Settings

Access via menu bar icon:
- **Activation Hotkey** - Choose between:
  - ⌃⌃ Double-tap Control (default)
  - ⌃⌥D (Control+Option+D)
  - ⌃⌥Space (Control+Option+Space)
  - ⇧⌘D (Command+Shift+D)
- **Chunk Duration** - How often to send audio for transcription (30s - 7min, or full recording)
- **Skip Silent Chunks** - Don't transcribe chunks with no speech
- **Launch at Login** - Start automatically when you log in

## Build Options

### Development Build

```bash
swift build
.build/debug/SpeakFlow
```

### Release Build with DMG

```bash
./scripts/build-release.sh [version]

# Examples:
./scripts/build-release.sh          # Creates v1.0.0
./scripts/build-release.sh 1.2.3    # Creates v1.2.3
```

The build script:
1. Compiles release binary with optimizations
2. Creates proper .app bundle with Info.plist
3. Generates app icon from source PNG
4. Signs the app (self-signed or with your certificate)
5. Creates distributable DMG

### Code Signing

The build script attempts to sign with a certificate named "SpeakFlow Developer". If not found, it falls back to ad-hoc signing.

**To create a self-signed certificate** (recommended for personal use):

1. Open **Keychain Access**
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate**
3. Name: `SpeakFlow Developer`
4. Identity Type: `Self Signed Root`
5. Certificate Type: `Code Signing`
6. Click **Create**

This allows the app to retain accessibility permissions across rebuilds.

### Running Tests

```bash
swift test
```

## Architecture

```
Sources/
├── App/
│   ├── main.swift              # Entry point
│   └── AppDelegate.swift       # UI, menus, hotkey handling
├── SpeakFlowCore/
│   ├── Audio/                  # Recording & audio processing
│   ├── Auth/                   # ChatGPT OAuth
│   ├── Hotkey/                 # Global hotkey detection
│   ├── Permissions/            # Accessibility permission handling
│   ├── Transcription/          # Whisper API integration
│   ├── Utilities/              # Auth credentials, logging
│   ├── Config.swift            # Settings & configuration
│   └── Statistics.swift        # Usage tracking
└── Resources/
    └── AppIcon.png             # App icon source
```

## Privacy & Security

- **No data stored remotely** - Audio is sent directly to OpenAI's API
- **Credentials stored locally** - In `~/.speakflow/auth.json` with restricted permissions (600)
- **Microphone access** - Only when actively recording
- **Accessibility access** - Only for inserting transcribed text

## Troubleshooting

### "Accessibility Permission Required"

1. Open **System Settings → Privacy & Security → Accessibility**
2. Find **SpeakFlow** in the list
3. Enable the checkbox
4. Restart the app if prompted

### App not appearing in Accessibility list

- Make sure the app is in `/Applications`
- Try running the app once, then check System Settings

### Text not being inserted

- Verify accessibility permission is granted
- Try restarting the app
- Check that the target app accepts keyboard input

### Login issues

- Ensure you have an active OpenAI account with Pro or Max subscription
- Try logging out and back in via the menu

## License

MIT License - See LICENSE file for details.

## Acknowledgments

- Uses OpenAI's Whisper API for transcription
- OAuth flow compatible with OpenAI Codex CLI
