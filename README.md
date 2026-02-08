# SpeakFlow

> **You speak 3× faster than you type. SpeakFlow is a keyboard you talk to.**

A macOS menu bar app that turns your voice into text — anywhere. Press a hotkey, speak naturally, and your words are transcribed and typed into whatever app you're using.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## Features

- **Voice-to-text dictation** — press a hotkey, speak, text appears in any app
- **On-device voice activity detection** — a neural network model runs locally on Apple Silicon to distinguish speech from silence in real-time; no audio leaves your machine until speech is confirmed
- **Smart chunking** — audio is split at natural sentence boundaries detected by silence analysis, not arbitrary time cuts
- **Automatic turn detection** — when you stop speaking, silence is detected and the session ends automatically
- **Noise filtering** — silent and noise-only chunks are filtered before transcription, saving API calls and improving accuracy
- **Universal text insertion** — transcribed text is typed into the focused app via macOS Accessibility
- **Configurable chunk duration** — 15 seconds up to 10 minutes
- **Launch at login** — runs quietly in the menu bar

## Audio Pipeline

1. **Capture** — 16 kHz, mono, 16-bit PCM from the system microphone
2. **Voice activity detection** — a lightweight (~2M parameter) neural model runs on Apple Neural Engine, classifying 32ms audio frames as speech or silence
3. **Speech segmentation** — the model uses hysteresis thresholds with a 3-second silence debounce to avoid false speech-end events during natural pauses
4. **Chunking** — audio is buffered and sent at the configured interval, always waiting for a natural pause so sentences aren't cut mid-word
5. **Auto-end** — after confirmed silence of 5+ seconds following speech, the session ends automatically
6. **Transcription** — speech chunks are sent to the Whisper API; results arrive in order and are typed into the active app

## License

Apache License, Version 2.0
