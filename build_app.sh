#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Building GemmaFind..."
swift build -c release --product GemmaFind
BIN_DIR="$(swift build -c release --show-bin-path)"

APP_DIR="$SCRIPT_DIR/GemmaFind.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/GemmaFind" "$MACOS_DIR/GemmaFind"
cp "Info.plist" "$CONTENTS_DIR/Info.plist"
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# LiteRT-LM runtime (Metal GPU backend statically linked inside).
DYLIB="$(find "$BIN_DIR" .build/artifacts -name libCLiteRTLM_mac.dylib -print -quit)"
if [ -z "$DYLIB" ]; then echo "❌ libCLiteRTLM_mac.dylib not found"; exit 1; fi
cp "$DYLIB" "$FRAMEWORKS_DIR/"
# The executable is linked with rpath @executable_path/../Frameworks (see Package.swift);
# make sure it is there even if the toolchain dropped it.
if ! otool -l "$MACOS_DIR/GemmaFind" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/GemmaFind"
fi
chmod +x "$MACOS_DIR/GemmaFind"

# Sign with a stable local certificate so folder-access (TCC) grants survive rebuilds.
KEYCHAIN="$HOME/Library/Keychains/gemmafind-signing.keychain-db"
CERT_SHA1=""
if ./setup_signing.sh && security unlock-keychain -p gemmafind "$KEYCHAIN" 2>/dev/null; then
    CERT_SHA1="$(security find-certificate -c "GemmaFind Local Signing" -Z "$KEYCHAIN" | awk '/SHA-1/ {print $NF}')"
fi
SIGN_ID="${CERT_SHA1:--}"
[ "$SIGN_ID" = "-" ] && echo "⚠️  Falling back to ad-hoc signing (folder permissions may be re-requested after each build)"
codesign --force --sign "$SIGN_ID" --timestamp=none "$FRAMEWORKS_DIR/libCLiteRTLM_mac.dylib"
codesign --force --sign "$SIGN_ID" --timestamp=none --identifier "com.gemmafind.mac" "$APP_DIR"

echo "✅ Packaged $APP_DIR"
echo "   Run with: open \"$APP_DIR\""
