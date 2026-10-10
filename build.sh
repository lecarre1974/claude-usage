#!/bin/zsh
# Builds ClaudeUsage.app into ./build without Xcode or SwiftPM (works with Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeUsage.app
BIN_NAME=ClaudeUsage
mkdir -p build

# Command Line Tools 16.4 ships a stale usr/include/swift/module.modulemap that redefines
# SwiftBridging and breaks `import Foundation`. Hide it with a VFS overlay if present.
EXTRA=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $STALE && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
  mkdir -p build/vfs
  : > build/vfs/empty.modulemap
  cat > build/vfs/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "$STALE", "external-contents": "$PWD/build/vfs/empty.modulemap" } ] }
YAML
  EXTRA=(-vfsoverlay build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs/overlay.yaml)
fi

ARCH=$(uname -m)
echo "→ compiling ($ARCH)"
swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" "${EXTRA[@]}" \
  -module-name ClaudeUsage $(find Sources -name '*.swift') -o "build/$BIN_NAME"

echo "→ bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ icon"
rm -rf build/AppIcon.iconset
"build/$BIN_NAME" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

echo "✓ built $APP"
