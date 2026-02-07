#!/usr/bin/env bash
set -uo pipefail

START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Starting CHUNK DURATION tests at $START_TS"

# Function to run a test case
run_test() {
    local duration_setting=$1
    local record_seconds=$2
    local expected_chunks=$3
    local test_name=$4

    echo "--------------------------------------------------"
    echo "TEST: $test_name"
    echo "Setting: $duration_setting, Record: ${record_seconds}s, Expect: $expected_chunks+ chunks"
    
    export SPEAKFLOW_E2E_CHUNK_DURATION=$duration_setting
    export SPEAKFLOW_E2E_RECORD_SECONDS=$record_seconds
    export SPEAKFLOW_E2E_TEST_AUTO_END=false
    # Long text (~60s of speech)
    export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="One two three four five six seven eight nine ten. Let me continue speaking for a while longer to test chunking behavior. The quick brown fox jumps over the lazy dog. This is additional filler text to ensure we speak long enough. We need to keep talking to generate audio data. Alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu. Repeating the sequence again to ensure sufficient duration. One two three four five six seven eight nine ten."
    export SPEAKFLOW_E2E_TIMEOUT_SECONDS=$((record_seconds + 10))

    # Run and capture output
    OUTPUT=$(swift run --disable-sandbox SpeakFlowLiveE2E 2>&1)
    
    # Analyze output
    CHUNKS=$(echo "$OUTPUT" | grep -c "chunk #")
    echo "Chunks received: $CHUNKS"
    
    if [ "$CHUNKS" -ge "$expected_chunks" ]; then
        echo "✅ PASSED: Received $CHUNKS chunks (>= $expected_chunks)"
    else
        echo "❌ FAILED: Received $CHUNKS chunks (expected >= $expected_chunks)"
        echo "Output tail:"
        echo "$OUTPUT" | tail -n 10
        return 1
    fi
}

# TEST 1: 15s Chunks
# Record 35s -> Expect at least 2 chunks (15s, 30s)
run_test "15.0" "35" "2" "15 Second Chunks" || exit 1

# TEST 2: 30s Chunks
# Record 65s -> Expect at least 2 chunks (30s, 60s)
run_test "30.0" "65" "2" "30 Second Chunks" || exit 1

# TEST 3: Unlimited
# Record 45s -> Expect exactly 1 chunk (final)
echo "--------------------------------------------------"
echo "TEST: Unlimited Mode"
export SPEAKFLOW_E2E_CHUNK_DURATION=3600
export SPEAKFLOW_E2E_RECORD_SECONDS=45
OUTPUT=$(swift run --disable-sandbox SpeakFlowLiveE2E 2>&1)
CHUNKS=$(echo "$OUTPUT" | grep -c "chunk #")
echo "Chunks received: $CHUNKS"

if [ "$CHUNKS" -eq "1" ]; then
    echo "✅ PASSED: Received exactly 1 chunk (final)"
else
    echo "❌ FAILED: Received $CHUNKS chunks (expected 1)"
    return 1
fi

echo "ALL CHUNK TESTS PASSED"
