#!/usr/bin/env bash
# Compiles ArchiveSafety.swift with its standalone tests and runs them (macOS or Linux with Swift).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
cp Tests/ArchiveSafetyTests.swift "$out/main.swift"
swiftc -o "$out/archive-safety-tests" Valkey/ArchiveSafety.swift "$out/main.swift"
"$out/archive-safety-tests"
