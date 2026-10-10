#!/bin/zsh
# Builds a universal (Apple silicon + Intel) ClaudeUsage.app and zips it into dist/.
#   ./release.sh 1.1.0             build + zip
#   ./release.sh 1.1.0 --publish   also create a GitHub release with the zip attached
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version> [--publish]}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must look like 1.2.3" >&2; exit 1; }
PUBLISH=${2:-}
APP=build/ClaudeUsage.app
mkdir -p build dist

EXTRA=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $STALE && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
  mkdir -p build/vfs; : > build/vfs/empty.modulemap
  print -r -- "{ \"version\": 0, \"case-sensitive\": \"false\", \"roots\": [ { \"type\": \"file\", \"name\": \"$STALE\", \"external-contents\": \"$PWD/build/vfs/empty.modulemap\" } ] }" > build/vfs/overlay.yaml
  EXTRA=(-vfsoverlay build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc build/vfs/overlay.yaml)
fi

for ARCH in arm64 x86_64; do
  echo "→ compiling $ARCH"
  swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" "${EXTRA[@]}" \
    -module-name ClaudeUsage $(find Sources -name '*.swift') -o "build/ClaudeUsage-$ARCH"
done
lipo -create build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64 -output build/ClaudeUsage

echo "→ bundling v$VERSION"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/ClaudeUsage "$APP/Contents/MacOS/ClaudeUsage"
sed -e "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$VERSION</string>|" \
    -e "s|<key>CFBundleVersion</key><string>[^<]*</string>|<key>CFBundleVersion</key><string>$VERSION</string>|" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
rm -rf build/AppIcon.iconset
build/ClaudeUsage --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null

ZIP="dist/ClaudeUsage-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "✓ $ZIP  ($(lipo -archs "$APP/Contents/MacOS/ClaudeUsage"))"
echo "  sha256 $SHA"

if [[ $PUBLISH == --publish ]]; then
  gh release create "v$VERSION" "$ZIP" --title "Claude Usage $VERSION" --notes "Universal build (Apple silicon + Intel), macOS 14+.

The app is ad-hoc signed, not notarized. After unzipping and moving it to Applications, right-click → **Open** the first time, or run:
\`\`\`
xattr -dr com.apple.quarantine /Applications/ClaudeUsage.app
\`\`\`
sha256: \`$SHA\`"
fi
