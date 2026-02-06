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
    TEST_OUTPUT=$(swift test 2>&1)
    echo "$TEST_OUTPUT" >> "$LOG_FILE"
    
    if echo "$TEST_OUTPUT" | grep -q "Test run.*passed"; then
        # Extract test count
        PASSED=$(echo "$TEST_OUTPUT" | grep "Test run" | grep -oE '[0-9]+ tests? passed' | head -1)
        echo "OK ($PASSED)"
    else
        echo "ERROR"
        FAILED=1
        
        # Extract failed tests (brief)
        echo "$TEST_OUTPUT" | grep -E "^✘|failed" | head -5 | while read -r line; do
            echo "  → $line"
        done
    fi
fi

# Step 3: Coverage summary (only if tests passed)
if [ $FAILED -eq 0 ]; then
    echo -n "Coverage........ "
    
    # Run with coverage
    swift test --enable-code-coverage >> "$LOG_FILE" 2>&1
    
    PROFDATA=".build/arm64-apple-macosx/debug/codecov/default.profdata"
    BINARY=".build/arm64-apple-macosx/debug/SpeakFlowPackageTests.xctest/Contents/MacOS/SpeakFlowPackageTests"
    
    if [ -f "$PROFDATA" ] && [ -f "$BINARY" ]; then
        COV=$(xcrun llvm-cov report "$BINARY" \
            -instr-profile="$PROFDATA" \
            -ignore-filename-regex='.build|Tests' 2>/dev/null | tail -1 | awk '{print $10}')
        echo "OK ($COV)"
        
        # Log full coverage report
        echo "" >> "$LOG_FILE"
        echo "=== COVERAGE REPORT ===" >> "$LOG_FILE"
        xcrun llvm-cov report "$BINARY" \
            -instr-profile="$PROFDATA" \
            -ignore-filename-regex='.build|Tests' >> "$LOG_FILE" 2>&1
    else
        echo "SKIP (no coverage data)"
    fi
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
