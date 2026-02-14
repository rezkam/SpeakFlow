.PHONY: build test check lint test-live-e2e test-live-e2e-autoend test-live-e2e-chunks test-live-e2e-accuracy test-live-e2e-noise coverage coverage-html clean

# Strict check: build + tests + optional lint, concise output, full log saved
check:
	@./scripts/check.sh

# Build the project
build:
	swift build

# Run all tests
test:
	@./scripts/test.sh

# Run live end-to-end test (real microphone + real transcription API)
test-live-e2e:
	@./scripts/run-live-e2e.sh

# Run auto-end timing live E2E suite (4 scenarios)
test-live-e2e-autoend:
	@./scripts/run-auto-end-timing-e2e.sh

# Run chunk duration verification live E2E suite
test-live-e2e-chunks:
	@./scripts/run-chunk-duration-e2e.sh

# Run transcription accuracy live E2E suite
test-live-e2e-accuracy:
	@./scripts/run-transcription-accuracy-e2e.sh

# Run noise rejection live E2E suite (non-human audio)
test-live-e2e-noise:
	@./scripts/run-noise-rejection-e2e.sh

# Run all live E2E suites (auto-end + chunks + accuracy + noise)
test-live-e2e-all:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Running ALL Live E2E Suites"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@./scripts/run-auto-end-timing-e2e.sh
	@./scripts/run-chunk-duration-e2e.sh
	@./scripts/run-transcription-accuracy-e2e.sh
	@./scripts/run-noise-rejection-e2e.sh
	@echo ""
	@echo "✅ All live E2E suites passed!"

# Run tests with coverage report
coverage:
	@./scripts/coverage.sh

# Run tests with HTML coverage report (opens in browser)
coverage-html:
	@./scripts/coverage.sh --html

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build/coverage

# Run SwiftLint
lint:
	swiftlint lint --quiet

# Build release version
release:
	@./scripts/build-release.sh

# Run specific test suite
test-security:
	swift test --filter SecurityTests

test-cancellation:
	swift test --filter CancellationTests

test-p2:
	swift test --filter P2IssueTests

help:
	@echo "Available commands:"
	@echo "  make check               - Build + tests + optional lint"
	@echo "  make build               - Build the project"
	@echo "  make test                - Run all tests (concise), full log path printed"
	@echo "  make test-live-e2e       - Run real mic+API end-to-end transcription test"
	@echo "  make test-live-e2e-autoend  - Run auto-end timing live E2E suite"
	@echo "  make test-live-e2e-chunks   - Run chunk duration verification E2E suite"
	@echo "  make test-live-e2e-accuracy - Run transcription accuracy E2E suite"
	@echo "  make test-live-e2e-noise    - Run noise rejection E2E suite"
	@echo "  make test-live-e2e-all      - Run ALL live E2E suites"
	@echo "  make coverage            - Run tests with coverage report"
	@echo "  make coverage-html       - Run tests with HTML coverage (opens browser)"
	@echo "  make lint                - Run SwiftLint"
	@echo "  make clean               - Clean build artifacts"
	@echo "  make release             - Build release version"
	@echo "  make test-security       - Run security tests only"
	@echo "  make test-cancellation   - Run cancellation tests only"
	@echo "  make test-p2             - Run P2 issue tests only"
