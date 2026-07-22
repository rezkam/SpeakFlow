.PHONY: build test test-regression-core test-tsan check lint test-live-e2e test-live-e2e-autoend test-live-e2e-chunks test-live-e2e-accuracy test-live-e2e-noise test-live-e2e-all test-live-mistral coverage coverage-html clean rc local release release-yes help

# Strict check: build + tests, concise output, full log saved
check:
	@./scripts/check.sh

# Build the project
build:
	swift build

# Run all tests
test:
	@./scripts/test.sh

# Run main-feature regression suites (deterministic behavioral coverage)
test-regression-core:
	@./scripts/test-regression-core.sh

# Run tests with Thread Sanitizer (detects data races)
test-tsan:
	swift test --sanitize=thread

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

# Run live Mistral API integration tests (real api.mistral.ai; opt-in)
test-live-mistral:
	@SPEAKFLOW_RUN_LIVE_MISTRAL=1 swift test --filter MistralAPITests

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

# Run SwiftLint and documentation consistency checks
lint:
	swiftlint lint --quiet
	@./scripts/check-documentation-consistency.sh

# RC build: compile, sign, install locally — nothing pushed or uploaded
rc:
	@./scripts/build-release.sh rc

# Local production build: compile, sign, validate, and install without publishing
local:
	@./scripts/build-release.sh local

# Production release: compile, sign, notarize, publish to GitHub
release:
	@./scripts/build-release.sh release

# Production release, non-interactive (skip all confirmations)
release-yes:
	@./scripts/build-release.sh release --yes

help:
	@echo "Available commands:"
	@echo "  make check               - Build + tests"
	@echo "  make build               - Build the project"
	@echo "  make test                - Run all tests (concise), full log path printed"
	@echo "  make test-regression-core - Run main-feature regression suites + stress loop"
	@echo "  make test-tsan           - Run tests with Thread Sanitizer (data races)"
	@echo "  make test-live-e2e       - Run real mic+API end-to-end transcription test"
	@echo "  make test-live-e2e-autoend  - Run auto-end timing live E2E suite"
	@echo "  make test-live-e2e-chunks   - Run chunk duration verification E2E suite"
	@echo "  make test-live-e2e-accuracy - Run transcription accuracy E2E suite"
	@echo "  make test-live-e2e-noise    - Run noise rejection E2E suite"
	@echo "  make test-live-e2e-all      - Run ALL live E2E suites"
	@echo "  make test-live-mistral      - Run live Mistral API integration tests (opt-in)"
	@echo "  make coverage            - Run tests with coverage report"
	@echo "  make coverage-html       - Run tests with HTML coverage (opens browser)"
	@echo "  make lint                - Run SwiftLint"
	@echo "  make clean               - Clean build artifacts"
	@echo "  make rc                  - Build + sign + install locally (RC, nothing uploaded)"
	@echo "  make local               - Build + sign + install production version locally (no publishing)"
	@echo "  make release             - Build + sign + notarize + publish to GitHub"
	@echo "  make release-yes         - Same as release, skip all confirmations"
