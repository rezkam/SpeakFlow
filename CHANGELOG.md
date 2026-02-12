# Changelog

## Unreleased

* Fixed recording silently proceeding without a configured provider on first launch — an early configuration gate now blocks recording and shows a banner directing users to Accounts setup.
* Provider picker in transcription settings now only shows configured providers, preventing selection of unusable providers.
* Accounts view reactively updates after OAuth login, so newly authenticated providers appear immediately.
* Introduced `KeyIntercepting`, `TextInserting`, and `BannerPresenting` DI protocols for `RecordingController`, enabling proper behavioral testing with spy mocks.
* Replaced ~170 brittle source-parsing tests with ~20 behavioral tests backed by dependency injection — test suite is now 280 tests in 72 suites, all exercising real runtime behavior.

## 0.2.0

* Replaced hardcoded provider logic with an extensible protocol hierarchy (`TranscriptionProvider` → `BatchTranscriptionProvider` / `StreamingTranscriptionProvider`) and a central `ProviderRegistry`.
* Added `ProviderId` constants eliminating 12+ scattered string literals across the codebase.
* Introduced `APIKeyValidatable` protocol moving key validation from generic settings to the owning provider.
* Added provider-owned streaming config via `buildSessionConfig()`.
* Unified credential storage consolidates all provider credentials in `~/.speakflow/auth.json`.
* Extracted `TextInserter` and `KeyInterceptor` from `RecordingController` for single responsibility.
* Added `AppState.binding(for:)` generic helper eliminating 12 copy-paste binding properties.
* Split the monolithic 7,187-line `VADTests.swift` into 10 domain-specific test files.

## 0.1.0

* Initial release with ChatGPT and Deepgram transcription providers.
