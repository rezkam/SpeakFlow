<p align="center">
  <img src="Sources/Resources/logo.png" width="128" height="128" alt="SpeakFlow">
</p>

<h1 align="center">SpeakFlow</h1>

<p align="center">
  <strong>You speak 3x faster than you type. SpeakFlow is a keyboard you talk to.</strong>
</p>

<p align="center">
  A macOS menu bar app that turns your voice into text — anywhere.<br>
  Press a hotkey, speak naturally, and your words appear in whatever app you're using.<br><br>
  <b>Real-time interim results</b> that refine as you speak &nbsp;·&nbsp; <b>On-device voice activity detection</b> powered by Apple Neural Engine
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/Homebrew-install-orange?logo=homebrew" alt="Install with Homebrew">
</p>

<p align="center">
  <strong>Install with Homebrew</strong>
</p>

```sh
brew tap rezkam/speakflow
brew install --cask speakflow
```

## Transcription Providers

SpeakFlow supports four transcription modes across three providers. Switch between them from the **Transcription** tab in settings.

| | **Deepgram Nova-3** | **Mistral Voxtral Realtime** | **Mistral Voxtral Mini** | **ChatGPT (GPT-4o)** |
|---|---|---|---|---|
| **Mode** | Streaming | Streaming | Batch | Batch |
| **How it works** | Audio streams over WebSocket; text appears as you speak | Audio streams over WebSocket with sub-500ms latency | Full recording sent after each chunk | Full recording sent after each chunk |
| **Latency** | ~300ms | <500ms | After chunk completes | After chunk completes |
| **Best for** | Live dictation, long-form writing | Low-latency multilingual dictation | Batch transcription with speaker diarization | Short notes, high-accuracy single takes |
| **Extras** | Smart formatting, interim results | 13 languages, auto-detection | Speaker diarization, temperature control | — |
| **Requires** | Deepgram API key | Mistral API key | Mistral API key (shared) | ChatGPT login |

### API Keys

**Deepgram** — offers a **free $200 credit**, no credit card required.

1. Sign up at [deepgram.com/pricing](https://deepgram.com/pricing)
2. Create an API key in the Deepgram console
3. Paste it into SpeakFlow via the **Providers** tab in settings

**Mistral** — one API key unlocks both Voxtral Realtime (streaming) and Voxtral Mini (batch).

1. Sign up at [console.mistral.ai](https://console.mistral.ai)
2. Create an API key in the Mistral console
3. Paste it into SpeakFlow via the **Providers** tab in settings

## Installation

### Homebrew (recommended)

```sh
brew tap rezkam/speakflow
brew install --cask speakflow
```

To update to the latest version:

```sh
brew upgrade --cask speakflow
```

To uninstall:

```sh
brew uninstall --cask speakflow
```

### From DMG

1. Download `SpeakFlow.dmg` from the [Releases](https://github.com/rezkam/SpeakFlow/releases) page
2. Open the DMG and drag SpeakFlow to Applications
3. Launch SpeakFlow — the settings window opens automatically
4. Grant **Accessibility** and **Microphone** permissions from the General tab
5. Add an API key (Deepgram or Mistral) or log in to ChatGPT from the Providers tab

### Build from Source

```bash
git clone https://github.com/rezkam/SpeakFlow.git
cd SpeakFlow
swift build -c release --product SpeakFlow

# Or build and install a signed production-version .app locally,
# without notarizing or publishing it:
make local

# To build a local release candidate with an RC display suffix:
make rc
```

Requires **macOS 26+** and **Swift 6.2+** (Xcode 26 or later).

## Permissions

SpeakFlow needs two permissions, both granted from the **General** tab in settings:

- **Accessibility** — required to type transcribed text into any app. Clicking "Grant Access" opens System Settings where you toggle SpeakFlow on.
- **Microphone** — required to hear your voice. Clicking "Grant Access" shows the macOS permission dialog.

Permissions are never requested automatically on launch — you choose when to grant them.

### Troubleshooting Accessibility

Released SpeakFlow builds are signed with a Developer ID certificate and notarized. Accessibility permission normally survives a standard release upgrade. If macOS stops recognizing Accessibility after replacing the app with a manual or locally built copy:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Turn SpeakFlow off, then on again
3. If that does not help, remove the old SpeakFlow entry and re-add `SpeakFlow.app` from `/Applications`
4. Restart SpeakFlow

## Usage

### Menu Bar

Use **Close Control Panel** to hide the settings window while keeping SpeakFlow available in the menu bar. Select **Quit SpeakFlow** when you want to fully exit the app. Command-Q and Dock Quit close only the control panel so they do not interrupt the menu-bar service.

### Hotkeys

SpeakFlow activates with a global hotkey — press it to start dictation, press it again to stop. Choose your preferred hotkey in the **General** tab:

| Hotkey | Description |
|---|---|
| **⌃⌃** (Double-tap Control) | Tap the Control key twice quickly |
| **⌃⌥D** | Control + Option + D |
| **⌃⌥Space** | Control + Option + Space |
| **⇧⌘D** | Shift + Command + D |

### During Recording

| Key | Action |
|---|---|
| **Hotkey** | Stop recording and transcribe |
| **Escape** | Cancel recording — discard audio, insert nothing |
| **Enter** | Stop recording; after transcription completes, press Enter in the target app (useful for sending messages in chat apps) |

Text is inserted into whichever app was focused when you started recording. If you switch to a different app during transcription, typing pauses automatically and resumes when you return — text never goes to the wrong app. In streaming mode, words appear in real-time as you speak. In batch mode, text appears after you stop.

### Configurable Settings

All settings are in the **Transcription** tab:

- **Interim results** (Deepgram streaming) — partial text appears and refines as you speak. Each update only retypes the changed portion, so there's no flickering. Disable for final-only output.
- **Voice activity detection** (batch) — a neural network runs locally on Apple Silicon to detect speech in real-time. Silent and noise-only chunks are filtered out before transcription, saving API calls. Adjustable sensitivity threshold.
- **Auto-end** — enabled by default in both streaming and batch modes. The shared silence duration defaults to 10 seconds and is configurable from 1–30 seconds.
- **Smart formatting** (Deepgram streaming) — automatic punctuation and capitalization.
- **Endpointing** (Deepgram streaming) — controls how quickly Deepgram detects the end of an utterance (100–3000ms).
- **Speaker diarization** (Mistral batch) — identifies different speakers in the transcription.
- **Temperature** (Mistral batch) — controls output variability. 0 gives deterministic results; higher values produce more varied output.

## Features

- **Real-time streaming transcription** — words appear as you speak with Deepgram Nova-3 or Mistral Voxtral Realtime; interim results refine in-place using smart diff (only changed characters are retyped, no flickering)
- **Batch transcription** — record first, transcribe after with GPT-4o via ChatGPT or Mistral Voxtral Mini (with optional speaker diarization)
- **On-device voice activity detection** — a neural network model runs locally on Apple Silicon to distinguish speech from silence in real-time; no audio leaves your machine until speech is confirmed
- **Automatic turn detection** — when you stop speaking, silence is detected and the session ends automatically (works in both modes — local VAD for batch, server-side for streaming)
- **Smart chunking** — in batch mode, audio is split at natural sentence boundaries detected by silence analysis
- **Noise filtering** — silent and noise-only chunks are filtered before transcription, saving API calls and improving accuracy
- **Universal text insertion** — transcribed text is typed into the focused app via macOS Accessibility, with per-keystroke focus tracking that pauses if you switch apps and resumes when you return
- **Launch at login** — runs quietly in the menu bar

## Testing

- **Main feature regression gate:** `make test-regression-core`
- **Full test suite:** `make test`
- **Thread-safety sweep:** `make test-tsan`
- **Live E2E suites (manual/pre-release):** `make test-live-e2e-all`

If local SwiftPM lock contention occurs, run the regression gate with an isolated build path:
`SPEAKFLOW_SWIFT_SCRATCH_PATH=/tmp/speakflow-regression-build make test-regression-core`

Regression feature mapping is documented in:
`docs/REGRESSION_TEST_MATRIX.md`

## Audio Pipeline

### Streaming (Deepgram)

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Stream** — raw audio is sent over WebSocket to Deepgram Nova-3 with the selected language
3. **Interim results** — partial transcriptions appear immediately as you speak
4. **Smart diff** — when text updates, only the changed suffix is retyped (common prefix is preserved)
5. **Final results** — server finalizes each utterance with punctuation and formatting
6. **Auto-end** — after the configured silence duration (default 10 seconds) of server-detected silence following speech, the session ends

### Streaming (Mistral Voxtral Realtime)

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Stream** — raw audio is base64-encoded and sent over WebSocket to Mistral's realtime transcription API
3. **Delta accumulation** — incremental text fragments arrive as `transcription.text.delta` messages and are displayed as interim results
4. **Segment finalization** — the server emits `transcription.segment` with timing info, producing a final result and resetting the delta buffer
5. **Auto-end** — after configurable silence following speech, the session ends

### Batch (ChatGPT)

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Voice activity detection** — a lightweight neural model runs on Apple Neural Engine, classifying 32ms frames as speech or silence
3. **Speech segmentation** — hysteresis thresholds with 3-second silence debounce avoid false ends during natural pauses
4. **Chunking** — audio is buffered and sent at the configured interval, waiting for natural pauses
5. **Auto-end** — after the configured silence duration (default 10 seconds) of confirmed silence following speech, the session ends
6. **Transcription** — speech chunks are sent to the ChatGPT transcription backend (GPT-4o Transcribe); results arrive in order and are typed into the active app

### Batch (Mistral Voxtral Mini)

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Voice activity detection** — same on-device neural model as ChatGPT batch mode
3. **Speech segmentation** — same hysteresis and silence debounce logic
4. **Chunking** — audio is buffered as WAV and sent via multipart POST to Mistral's `/v1/audio/transcriptions` endpoint
5. **Auto-end** — after the configured silence duration (default 10 seconds) of confirmed silence following speech, the session ends
6. **Transcription** — Voxtral Mini processes each chunk; optional speaker diarization identifies different speakers in the output

## License

Apache License, Version 2.0
