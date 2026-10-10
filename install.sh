#!/bin/zsh
# Builds, installs to ~/Applications and (re)launches Claude Usage.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x ClaudeUsage 2>/dev/null || true
rm -rf "$DEST/ClaudeUsage.app"
cp -R build/ClaudeUsage.app "$DEST/"
open "$DEST/ClaudeUsage.app"
echo "✓ installed to $DEST/ClaudeUsage.app — look for the ✻ in your menu bar"
