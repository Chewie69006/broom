#!/usr/bin/env bash
# Times Broom's scanner against fts on the folders you give it (default: your home folder).
#
# Usage: Benchmark/run.sh [--runs N] [folder ...]
#
# Builds with optimizations from Broom/Scanning/*.swift and Benchmark/main.swift, using the
# Xcode project's Swift settings. Run it from Terminal; to include protected folders, give
# Terminal Full Disk Access first (both contenders then see the same files).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
    echo "The benchmark runs on macOS. On Linux, LinuxHarness/run.sh builds it as a compile check." >&2
    exit 1
fi

mkdir -p Benchmark/.build
xcrun swiftc -O -swift-version 5 \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature MemberImportVisibility \
    Broom/Scanning/*.swift Benchmark/main.swift \
    -o Benchmark/.build/broom-bench

Benchmark/.build/broom-bench "$@"
