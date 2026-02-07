#!/bin/bash
# LLM-friendly check script - concise output with full log saved to file
# Usage: ./scripts/check.sh

set -o pipefail

cd "$(dirname "$0")/.."

LOG_FILE=".build/check.log"
mkdir -p .build

# Clear previous log
> "$LOG_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SpeakFlow Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FAILED=0

# Step 1: Build
echo -n "Build........... "
if swift build 2>&1 >> "$LOG_FILE"; then
    echo "OK"
else
    echo "ERROR"
    echo "  → Build failed. Check $LOG_FILE for details."
    FAILED=1
fi

# Step 2: Tests (only if build succeeded)
if [ $FAILED -eq 0 ]; then
    echo -n "Tests........... "
    TEST_OUTPUT=$(swift run SpeakFlowTestRunner 2>&1)
    echo "$TEST_OUTPUT" >> "$LOG_FILE"
    
    if echo "$TEST_OUTPUT" | grep -q "0 failed"; then
        # Extract test count
        PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ passed' | head -1)
        echo "OK ($PASSED)"
    else
        echo "ERROR"
        FAILED=1
        
        # Extract failed tests (brief)
        echo "$TEST_OUTPUT" | grep -E "^✗" | head -5 | while read -r line; do
            echo "  → $line"
        done
    fi
fi

# Step 3: Coverage (skipped - using custom test runner)
if [ $FAILED -eq 0 ]; then
    echo "Coverage........ SKIP (custom test runner)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAILED -eq 0 ]; then
    echo "Status: ALL OK ✓"
else
    echo "Status: FAILED ✗"
fi

echo "Log: $LOG_FILE"
echo ""

exit $FAILED
