.PHONY: build test check coverage coverage-html clean

# LLM-friendly check: build + test + coverage (concise output, full log saved)
check:
	@./scripts/check.sh

# Build the project
build:
	swift build

# Run all tests
test:
	swift test

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
	@echo "  make check          - LLM-friendly: build + test + coverage (concise)"
	@echo "  make build          - Build the project"
	@echo "  make test           - Run all tests"
	@echo "  make coverage       - Run tests with coverage report"
	@echo "  make coverage-html  - Run tests with HTML coverage (opens browser)"
	@echo "  make clean          - Clean build artifacts"
	@echo "  make release        - Build release version"
	@echo "  make test-security  - Run security tests only"
	@echo "  make test-cancellation - Run cancellation tests only"
	@echo "  make test-p2        - Run P2 issue tests only"
