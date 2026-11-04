#!/usr/bin/env bash
# Compile-checks and tests Broom's scanner and models on Linux. See README.md.
#
# Usage: ./run.sh [folder]
#   folder: what the ThreadSanitizer stress test scans (default /usr/lib).
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname)" != "Linux" ]]; then
    echo "This harness only runs on Linux. On a Mac, run the tests in Xcode (⌘U)." >&2
    exit 1
fi

# Hide SwiftPM's per-file progress lines; keep errors, warnings and summaries.
quiet() { grep -vE '^\[[0-9]+/[0-9]+\] ' || true; }

# Runs a test command; prints only the summary when it passes, everything when it fails.
run_tests() {
    local log
    log=$(mktemp)
    if "$@" >"$log" 2>&1; then
        grep -E '^✔ Test run' "$log" || tail -1 "$log"
        rm -f "$log"
    else
        quiet <"$log"
        rm -f "$log"
        return 1
    fi
}

echo "==> Build and test in Swift 5 mode (same settings as the Xcode project)"
swift build --build-tests 2>&1 | quiet
run_tests swift test --skip-build

echo
echo "==> Build and test in strict Swift 6 mode"
BROOM_STRICT=1 swift build --build-tests --scratch-path .build-strict 2>&1 | quiet
run_tests env BROOM_STRICT=1 swift test --skip-build --scratch-path .build-strict

echo
echo "==> Benchmark, as a check that every scanner setup matches fts"
# Timings mean little here (the shim stands in for getattrlistbulk); the totals must agree.
bench_output=$(.build/debug/Bench --runs 1 "${1:-/usr/lib}")
echo "$bench_output" | grep -vE '^(for cold|[0-9]+ cores)'
if grep -q "totals differ" <<<"$bench_output"; then
    echo "Some scanner setup disagrees with fts." >&2
    exit 1
fi

echo
echo "==> Stress test under ThreadSanitizer"
# BROOM_TSAN_MUTEX swaps in a pthread-based Mutex that TSan can see (see Sources/Broom/_TSanMutex.swift).
swift build --product Stress --sanitize=thread --scratch-path .build-tsan -Xswiftc -DBROOM_TSAN_MUTEX 2>&1 | quiet
TSAN_OPTIONS="halt_on_error=1" .build-tsan/debug/Stress "${1:-/usr/lib}"
