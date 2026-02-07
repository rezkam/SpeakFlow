# SpeakFlow UI Test Harness

This folder contains `XCTest` UI tests intended for an Xcode UI Testing Bundle target.

## What It Covers

- Click flow: start dictation, stop dictation.
- Hotkey flow: trigger dictation toggle with keyboard shortcuts inside the harness window.
- Hotkey settings flow: cycle hotkeys and verify only the active one toggles recording.
- Statistics flow: seed/reset stats and verify values update in the harness.

The app exposes a dedicated test window when launched with:

- `SPEAKFLOW_UI_TEST_MODE=1`
- `SPEAKFLOW_UI_TEST_MOCK_RECORDING=1`
- `SPEAKFLOW_UI_TEST_RESET_STATE=1`

## One-Time Xcode Setup

1. Open this repository in Xcode.
2. Create a new target:
   - `File > New > Target... > macOS > UI Testing Bundle`
   - Name: `SpeakFlowUITests`
   - Target to be tested: `SpeakFlow`
3. Remove template test files from the new target.
4. Add existing files from this folder to `SpeakFlowUITests` target membership:
   - `UITests/SpeakFlowUITests.swift`
   - `UITests/SpeakFlowUITestsLaunchTests.swift`

## Run

- In Xcode: run the `SpeakFlowUITests` test target (`Cmd+U`).
- From terminal (used by `make test` / `make check`): `./scripts/run-ui-tests.sh`

## Notes

- The harness window is only shown in UI test mode.
- Mock recording mode avoids permission prompts and audio hardware dependency during UI automation.
