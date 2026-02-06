#!/bin/bash
# Test coverage script for SpeakFlow
# Usage: ./scripts/coverage.sh [--html]

set -e

cd "$(dirname "$0")/.."

echo "Running tests with coverage..."
swift test --enable-code-coverage

PROFDATA=".build/arm64-apple-macosx/debug/codecov/default.profdata"
BINARY=".build/arm64-apple-macosx/debug/SpeakFlowPackageTests.xctest/Contents/MacOS/SpeakFlowPackageTests"

if [ ! -f "$PROFDATA" ]; then
    echo "Error: Coverage data not found at $PROFDATA"
    exit 1
fi

if [ ! -f "$BINARY" ]; then
    echo "Error: Test binary not found at $BINARY"
    exit 1
fi

echo ""
echo "=================================="
echo "       TEST COVERAGE REPORT       "
echo "=================================="
echo ""

# Generate report (exclude .build and Tests directories)
xcrun llvm-cov report "$BINARY" \
    -instr-profile="$PROFDATA" \
    -ignore-filename-regex='.build|Tests'

# Optional: Generate HTML report
if [ "$1" == "--html" ]; then
    echo ""
    echo "Generating HTML coverage report..."
    
    COVERAGE_DIR=".build/coverage"
    mkdir -p "$COVERAGE_DIR"
    
    xcrun llvm-cov show "$BINARY" \
        -instr-profile="$PROFDATA" \
        -ignore-filename-regex='.build|Tests' \
        -format=html \
        -output-dir="$COVERAGE_DIR"
    
    echo "HTML report generated at: $COVERAGE_DIR/index.html"
    
    # Open in browser on macOS
    if command -v open &> /dev/null; then
        open "$COVERAGE_DIR/index.html"
    fi
fi

echo ""
echo "=================================="
echo "          SUMMARY                 "
echo "=================================="

# Extract and display total coverage
xcrun llvm-cov report "$BINARY" \
    -instr-profile="$PROFDATA" \
    -ignore-filename-regex='.build|Tests' 2>/dev/null | tail -1 | \
    awk '{print "Total Line Coverage: " $10}'
