#!/bin/sh
# run-tests.sh — run the AudioQueueActor drone-lifecycle test suite.
#
# WHY A STANDALONE HARNESS (not `swift test`):
# The build machine has Command Line Tools only (no full Xcode). That toolchain
# ships neither XCTest nor Swift Testing on the SwiftPM module search path, so a
# `.testTarget` fails with `no such module 'XCTest'` / `'Testing'`. Rather than
# restructure the Sparkle/rpath-sensitive app build, this harness compiles the
# REAL Engine sources (AudioQueueActor + CaldwellConfig + NativeVoiceClient — no
# source duplication, so the tests exercise the shipping code) together with a
# self-contained assert framework in Tests/DroneLifecycleTests.swift, then runs
# it as a plain executable.
#
# The suite drives the actor via its internal test seams — no audio worker, no
# afplay, no live daemon — and points the drone store at a temp dir, so the real
# cache/drones.json and the running app are never touched. Safe to run alongside
# a live daemon; does NOT build or install the app.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/macos/CaldwellDashboard"
ENGINE="$APP_DIR/Sources/Engine"
HARNESS="$APP_DIR/Tests/DroneLifecycleTests.swift"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc not found. Install Xcode or Command Line Tools." >&2
  exit 1
fi

BIN="$(mktemp -d)/drone-tests"

echo "Compiling drone-lifecycle test harness..."
# -parse-as-library so the top-level code in the harness runs from its own
# `await runAll()` entry (the harness is the last file, so its top-level `await`
# is the program's main). The three Engine files supply the code under test.
swiftc \
  -swift-version 5 \
  -o "$BIN" \
  "$ENGINE/AudioQueueActor.swift" \
  "$ENGINE/CaldwellConfig.swift" \
  "$HARNESS"

echo "Running..."
"$BIN"
