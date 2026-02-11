<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="SpeakFlow">
</p>

<h1 align="center">SpeakFlow</h1>

<p align="center">
  <strong>You speak 3x faster than you type. SpeakFlow is a keyboard you talk to.</strong>
</p>

<p align="center">
  A macOS menu bar app that turns your voice into text — anywhere.<br>
  Press a hotkey, speak naturally, and your words appear in whatever app you're using.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

## Two Transcription Modes

| | **Deepgram Nova-3 — Real-time** | **ChatGPT (GPT-4o) — Batch** |
|---|---|---|
| **How it works** | Audio streams to Deepgram over WebSocket; text appears as you speak | Audio is recorded locally, then sent for transcription when you stop |
| **Latency** | Words appear in ~300ms | Text appears after you finish speaking |
| **Best for** | Live dictation, long-form writing, conversations | Short notes, high-accuracy single takes |
| **Requires** | Deepgram API key | ChatGPT login |

Switch between modes from the **Transcription** tab in the settings window.

### Deepgram API Key

Deepgram offers a **free $200 credit** — no credit card required.

1. Sign up at [deepgram.com/pricing](https://deepgram.com/pricing)
2. Create an API key in the Deepgram console
3. Paste it into SpeakFlow via the **Accounts** tab in settings

## Installation

### From DMG (recommended)

1. Download `SpeakFlow.dmg` from the [Releases](https://github.com/rezkam/SpeakFlow/releases) page
2. Open the DMG and drag SpeakFlow to Applications
3. Launch SpeakFlow — the settings window opens automatically
4. Grant **Accessibility** and **Microphone** permissions from the General tab
5. Log in to ChatGPT or add a Deepgram API key from the Accounts tab

### Build from Source

```bash
git clone https://github.com/rezkam/SpeakFlow.git
cd SpeakFlow
swift build -c release --product SpeakFlow

# Or build the full .app bundle + DMG:
bash scripts/build-release.sh 0.1.0
```

Requires **macOS 15+** and **Xcode 26+** (Swift 6.2).

## Permissions

SpeakFlow needs two permissions, both granted from the **General** tab in settings:

- **Accessibility** — required to type transcribed text into any app. Clicking "Grant Access" opens System Settings where you toggle SpeakFlow on.
- **Microphone** — required to hear your voice. Clicking "Grant Access" shows the macOS permission dialog.

Permissions are never requested automatically on launch — you choose when to grant them.

## Features

- **Real-time streaming transcription** — words appear as you speak with Deepgram Nova-3; interim results refine in-place using smart diff (only changed characters are retyped, no flickering)
- **Batch transcription** — record first, transcribe after with GPT-4o via ChatGPT
- **On-device voice activity detection** — a neural network model runs locally on Apple Silicon to distinguish speech from silence in real-time; no audio leaves your machine until speech is confirmed
- **Automatic turn detection** — when you stop speaking, silence is detected and the session ends automatically (works in both modes — local VAD for batch, server-side for streaming)
- **Smart chunking** — in batch mode, audio is split at natural sentence boundaries detected by silence analysis
- **Noise filtering** — silent and noise-only chunks are filtered before transcription, saving API calls and improving accuracy
- **Universal text insertion** — transcribed text is typed into the focused app via macOS Accessibility
- **Launch at login** — runs quietly in the menu bar

## Audio Pipeline

### Streaming (Deepgram)

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Stream** — raw audio is sent over WebSocket to Deepgram Nova-3 (English, monolingual)
3. **Interim results** — partial transcriptions appear immediately as you speak
4. **Smart diff** — when text updates, only the changed suffix is retyped (common prefix is preserved)
5. **Final results** — server finalizes each utterance with punctuation and formatting
6. **Auto-end** — after 5+ seconds of server-detected silence following speech, the session ends

### Batch (ChatGPT)

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Voice activity detection** — a lightweight neural model runs on Apple Neural Engine, classifying 32ms frames as speech or silence
3. **Speech segmentation** — hysteresis thresholds with 3-second silence debounce avoid false ends during natural pauses
4. **Chunking** — audio is buffered and sent at the configured interval, waiting for natural pauses
5. **Auto-end** — after 5+ seconds of confirmed silence following speech, the session ends
6. **Transcription** — speech chunks are sent to the Whisper API; results arrive in order and are typed into the active app

## License

Apache License, Version 2.0
