#!/bin/bash
set -e

# Build the E2E test runner first
echo "Building SpeakFlowLiveE2E..."
swift build -c release --product SpeakFlowLiveE2E

BINARY_PATH=".build/release/SpeakFlowLiveE2E"
TEST_DIR="/tmp/speakflow_noise_test"
mkdir -p "$TEST_DIR"

# Generate test audio files
echo "Generating test audio files..."

# 1. White Noise (10s)
# - volume=0.5 to be audible but not clipping
ffmpeg -y -f lavfi -i "anoisesrc=c=pink:r=16000:a=0.5" -t 10 "$TEST_DIR/white_noise.wav" > /dev/null 2>&1

# 2. Sine Wave (Tone) (10s)
# - 440Hz beep, volume=0.5
ffmpeg -y -f lavfi -i "sine=f=440:r=16000:d=10" -filter:a "volume=0.5" "$TEST_DIR/tone.wav" > /dev/null 2>&1

# 3. Typing / Clicks (10s)
# - Simulate by generating random noise bursts?
# - Or just use a simple pulse train: 5Hz pulses
ffmpeg -y -f lavfi -i "anoisesrc=c=brown:r=16000:a=0.5" -filter:a "apulsator=mode=sine:hz=5" -t 10 "$TEST_DIR/typing.wav" > /dev/null 2>&1

# 4. Silence (10s) - Control
ffmpeg -y -f lavfi -i "anullsrc=r=16000:cl=mono" -t 10 "$TEST_DIR/silence.wav" > /dev/null 2>&1


run_test() {
    local name="$1"
    local file="$2"
    
    echo "---------------------------------------------------"
    echo "Testing: $name ($file)"
    echo "---------------------------------------------------"
    
    # Run with noise rejection mode enabled
    # Set record seconds slightly longer than audio to catch trailing chunks
    export SPEAKFLOW_E2E_TEST_NOISE_REJECTION=1
    export SPEAKFLOW_E2E_AUDIO_FILE_PATH="$file"
    export SPEAKFLOW_E2E_RECORD_SECONDS=12
    export SPEAKFLOW_E2E_TIMEOUT_SECONDS=20
    
    if "$BINARY_PATH"; then
        echo "✅ PASSED: $name"
    else
        echo "❌ FAILED: $name"
        exit 1
    fi
}

echo "Starting Noise Rejection Tests..."

run_test "White Noise" "$TEST_DIR/white_noise.wav"
run_test "Sine Tone" "$TEST_DIR/tone.wav"
run_test "Typing/Clicks" "$TEST_DIR/typing.wav"
run_test "Silence" "$TEST_DIR/silence.wav"

echo "---------------------------------------------------"
echo "✅ All noise rejection tests passed!"
