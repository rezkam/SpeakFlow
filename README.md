# SpeakFlow

A macOS menu bar app for voice dictation using OpenAI's Whisper API. Press a hotkey, speak, and your transcribed text is automatically typed into any application.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- 🎤 **Voice-to-text dictation** - Press hotkey to start, press again to stop
- ⌨️ **Universal text insertion** - Works in any app via accessibility
- 🔐 **ChatGPT OAuth login** - Secure authentication (same as Codex CLI)
- ⚡ **Configurable chunking** - 30s to 7min chunks, or full recording (up to 1 hour)
- 🔇 **Smart silence detection** - Skips silent audio to save API calls
- 🚀 **Launch at login** - Optional auto-start
- 📊 **Usage statistics** - Track transcription duration, words, characters, and API calls

## Quick Start

### Prerequisites

- macOS 13.0 or later
- Xcode Command Line Tools (`xcode-select --install`)
- **OpenAI Pro or Max subscription** (required for API access)

### Build & Install

```bash
# Clone the repository
git clone https://github.com/rezkam/SpeakFlow.git
cd SpeakFlow

# Build the app
./scripts/build-release.sh

# Install to Applications
cp -r SpeakFlow.app /Applications/

# Launch
open /Applications/SpeakFlow.app
```

That's it! The script handles everything - no certificates or additional setup required.

## Required Permissions

SpeakFlow needs two permissions to work. You'll be prompted to grant these on first launch.

### 🎤 Microphone Access

**Why:** To record your voice for transcription.

**How to grant:**
- You'll see a system prompt on first use
- Click "Allow" when asked for microphone access
- If denied, go to **System Settings → Privacy & Security → Microphone** and enable SpeakFlow

### ⌨️ Accessibility Access

**Why:** To type the transcribed text into any application. This is how SpeakFlow inserts text wherever your cursor is - it simulates keyboard input, which requires accessibility permission.

**How to grant:**
1. On first launch, you'll see a prompt to enable Accessibility
2. Click "Open System Settings" (or go manually to **System Settings → Privacy & Security → Accessibility**)
3. Find **SpeakFlow** in the list and enable the toggle
4. You may need to restart the app after granting permission

> **Note:** If you rebuild the app, macOS may ask for Accessibility permission again because the app signature changes. This is normal - just re-enable it in System Settings.

### 🔑 ChatGPT Login

**Why:** To access OpenAI's Whisper API for transcription.

**How to login:**
1. Click the SpeakFlow icon in the menu bar
2. Click "Login to ChatGPT..."
3. A browser window opens - log in with your OpenAI account
4. You'll be redirected back automatically

## Usage

| Action | Default Hotkey |
|--------|---------------|
| Start/Stop dictation | Double-tap Control |

Press the hotkey once to start recording, press it again to stop. Your transcribed text will be typed wherever your cursor is.

### Settings

Access via menu bar icon:
- **Activation Hotkey** - Choose between:
  - ⌃⌃ Double-tap Control (default)
  - ⌃⌥D (Control+Option+D)
  - ⌃⌥Space (Control+Option+Space)
  - ⇧⌘D (Command+Shift+D)
- **Chunk Duration** - How often to send audio for transcription (30s - 7min, or full recording up to 1 hour)
- **Skip Silent Chunks** - Don't transcribe chunks with no speech
- **Launch at Login** - Start automatically when you log in

## Development

### Build from Source

```bash
# Debug build
swift build
.build/debug/SpeakFlow

# Release build
./scripts/build-release.sh
```

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
3. Enable the toggle
4. Restart the app

### App not appearing in Accessibility list

- Make sure the app is in `/Applications` (or run it once from its current location)
- The app should automatically appear after you launch it

### Text not being inserted

- Verify accessibility permission is granted
- Make sure the target app has focus and accepts keyboard input
- Try restarting SpeakFlow

### Microphone not working

1. Open **System Settings → Privacy & Security → Microphone**
2. Find **SpeakFlow** and enable it
3. Restart the app

### Login issues

- Ensure you have an active OpenAI account with Pro or Max subscription
- Try logging out (menu → Logout) and logging back in

### Permission resets after rebuild

This is normal - when you rebuild the app, its code signature changes, and macOS treats it as a new app. Just re-grant the permissions in System Settings.

## License

MIT License - See LICENSE file for details.

## Acknowledgments

- Uses OpenAI's Whisper API for transcription
- OAuth flow compatible with OpenAI Codex CLI
