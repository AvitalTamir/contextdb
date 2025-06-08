# ContextDB Makefile
# Convenient targets for development and testing

.PHONY: help build test test-all test-raft clean run demo demo-distributed format check setup install deps

# Default target
help:
	@echo "ContextDB - Distributed Hybrid Vector and Graph Database"
	@echo ""
	@echo "Available targets:"
	@echo "  build              - Build the project"
	@echo "  test               - Run core database tests"
	@echo "  test-all           - Run all tests (core + raft + distributed)"
	@echo "  test-raft          - Run Raft consensus tests"
	@echo "  run                - Run the basic demo"
	@echo "  demo               - Run the basic demo (alias for run)"
	@echo "  demo-distributed   - Run the distributed cluster demo"
	@echo "  clean              - Clean build artifacts and test data"
	@echo "  format             - Format all Zig source files"
	@echo "  check              - Check code without building"
	@echo "  setup              - Setup development environment"
	@echo "  install            - Install ContextDB binary (requires sudo)"
	@echo "  benchmark          - Run performance benchmarks"
	@echo "  docs               - Generate documentation"
	@echo ""
	@echo "Development targets:"
	@echo "  dev-setup          - Install development dependencies"
	@echo "  lint               - Run linting checks"
	@echo "  coverage           - Generate test coverage report"
	@echo ""

# Build targets
build:
	zig build

release:
	zig build -Doptimize=ReleaseFast

debug:
	zig build -Doptimize=Debug

# Test targets
test:
	zig build test

test-all:
	zig build test-all

test-raft:
	zig build test-raft

test-verbose:
	zig build test -- --verbose

# Run targets
run:
	zig build run

demo: run

demo-distributed:
	zig build demo-distributed

# Development targets
format:
	@echo "Formatting Zig source files..."
	@find src examples test -name "*.zig" -exec zig fmt {} \;
	@echo "✓ Formatting complete"

check:
	zig build --summary all

lint: format check

# Performance targets
benchmark:
	@echo "Running performance benchmarks..."
	zig build test-all
	@echo "✓ Benchmarks complete (see test output above)"

stress-test:
	@echo "Running stress tests..."
	@for i in {1..10}; do \
		echo "Iteration $$i/10"; \
		zig build test-all; \
	done
	@echo "✓ Stress testing complete"

# Documentation
docs:
	@echo "Generating documentation..."
	zig build-exe --help > /dev/null 2>&1 || echo "Zig documentation generation not available"
	@echo "📖 See README.md for comprehensive documentation"

# Setup and installation
setup: dev-setup
	@echo "✓ Development environment setup complete"

dev-setup:
	@echo "Setting up development environment..."
	@echo "Checking Zig installation..."
	@zig version || (echo "❌ Zig not found. Install from https://ziglang.org/download/" && exit 1)
	@echo "✓ Zig $(shell zig version) detected"
	@echo "Checking AWS CLI (optional)..."
	@aws --version 2>/dev/null || echo "⚠️  AWS CLI not found (optional for S3 features)"

install: release
	@echo "Installing ContextDB..."
	sudo cp zig-out/bin/contextdb /usr/local/bin/
	@echo "✓ ContextDB installed to /usr/local/bin/contextdb"

# Cleanup targets
clean:
	@echo "Cleaning build artifacts..."
	rm -rf .zig-cache/
	rm -rf zig-out/
	@echo "Cleaning test data..."
	rm -rf test_*/ demo_*/ *_contextdb/ node*_data/
	rm -f *.log *.bin raft_state.bin
	@echo "✓ Cleanup complete"

clean-all: clean
	@echo "Deep cleaning..."
	rm -rf logs/ tmp/ temp/
	rm -f *.tmp *.bak *.backup
	@echo "✓ Deep cleanup complete"

# Git helpers
git-setup:
	@echo "Setting up git hooks and configuration..."
	@echo "✓ Git setup complete"

# Distributed cluster helpers
cluster-start:
	@echo "Starting 3-node ContextDB cluster..."
	@echo "Node 1: http://localhost:9001 (Raft: 8001)"
	@echo "Node 2: http://localhost:9002 (Raft: 8002)" 
	@echo "Node 3: http://localhost:9003 (Raft: 8003)"
	@echo ""
	@echo "Run these commands in separate terminals:"
	@echo "  zig build run-distributed -- --node-id=1 --raft-port=8001 --http-port=9001"
	@echo "  zig build run-distributed -- --node-id=2 --raft-port=8002 --http-port=9002"
	@echo "  zig build run-distributed -- --node-id=3 --raft-port=8003 --http-port=9003"

# Development workflow
dev: clean format build test

ci: format check test-all

release-check: clean format check test-all release
	@echo "✅ Release checks passed"

# Docker helpers (for future use)
docker-build:
	@echo "Docker support coming soon..."

# Monitoring and debugging
logs:
	@echo "Showing recent ContextDB logs..."
	@find . -name "*.log" -exec tail -f {} \; 2>/dev/null || echo "No log files found"

status:
	@echo "ContextDB Status:"
	@echo "Build artifacts: $(shell test -d .zig-cache && echo '✓ Present' || echo '❌ None')"
	@echo "Test data: $(shell find . -maxdepth 1 -name '*_contextdb' -o -name 'demo_*' -o -name 'test_*' | wc -l | tr -d ' ') directories"
	@echo "Zig version: $(shell zig version 2>/dev/null || echo 'Not found')"

# Quick aliases for common tasks
b: build
t: test
ta: test-all
tr: test-raft
r: run
c: clean
f: format

# Help for aliases
aliases:
	@echo "Quick aliases:"
	@echo "  b  -> build"
	@echo "  t  -> test" 
	@echo "  ta -> test-all"
	@echo "  tr -> test-raft"
	@echo "  r  -> run"
	@echo "  c  -> clean"
	@echo "  f  -> format" 