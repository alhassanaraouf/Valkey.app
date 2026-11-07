#!/usr/bin/env bash
# Compiles CLI.swift with its standalone tests and runs them (macOS; CLI.swift uses CFMessagePort).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
cp Tests/CLITests.swift "$out/main.swift"
swiftc -o "$out/cli-tests" Valkey/CLI.swift "$out/main.swift"
"$out/cli-tests"
