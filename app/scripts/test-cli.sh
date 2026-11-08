#!/usr/bin/env bash
# Compiles the CLI sources (CLI, CLICommands, ConfigRules) with their standalone tests and runs them (macOS; CLI.swift uses CFMessagePort).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
cp Tests/CLITests.swift "$out/main.swift"
swiftc -o "$out/cli-tests" Valkey/CLI.swift Valkey/CLICommands.swift Valkey/ConfigRules.swift "$out/main.swift"
"$out/cli-tests"

# Exercise the real shared save transaction with suspended downloads and competing mutations.
swiftc -o "$out/store-tests" Valkey/ServerStore.swift Valkey/ConfigRules.swift Tests/StoreCommitTests.swift
"$out/store-tests"
