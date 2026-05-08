#!/bin/sh
# install-githooks.sh — point git at the .githooks dir for this repo.
#
# Run once after cloning. Enables the pre-commit hook that scans for
# ElevenLabs API keys before each commit.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x "$REPO_ROOT/.githooks/pre-commit"

echo "Git hooks installed."
echo "Pre-commit hook will scan for ElevenLabs API keys before each commit."
echo ""
echo "To disable:  git config --unset core.hooksPath"
