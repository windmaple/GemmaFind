#!/usr/bin/env bash
# Records the README demo GIF from the real app (scripted, offscreen) over the test corpus.
#   scripts/record_demo.sh            → assets/demo.gif
# Requires: ffmpeg, a built GemmaFind.app (./build_app.sh), and the model downloaded.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CORPUS="$HOME/Library/Caches/GemmaFind/demo-corpus"   # outside TCC-protected folders
FRAMES="$(mktemp -d)/frames"
OUT="assets/demo.gif"

[ -d Tests/Fixtures/corpus ] || scripts/make_fixtures.sh >/dev/null
rm -rf "$CORPUS"; mkdir -p "$(dirname "$CORPUS")"; cp -R Tests/Fixtures/corpus "$CORPUS"
rm -f "$HOME/Library/Caches/GemmaFind/test-index.sqlite"*

echo "🎬 Recording frames…"
pkill -x GemmaFind 2>/dev/null || true
GEMMAFIND_TEST_FOLDER="$CORPUS" GEMMAFIND_RECORD_DEMO="$FRAMES" \
    GemmaFind.app/Contents/MacOS/GemmaFind >/tmp/gemmafind-demo.log 2>&1
[ -f "$FRAMES/frames.txt" ] || { echo "❌ recording failed, see /tmp/gemmafind-demo.log"; exit 1; }
echo "   $(ls "$FRAMES"/*.png | wc -l | tr -d ' ') frames"

echo "🎞  Encoding GIF…"
mkdir -p assets
FILTER="fps=15,scale=960:-1:flags=lanczos"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$FRAMES/frames.txt" \
    -vf "$FILTER,palettegen=max_colors=192:stats_mode=diff" "$FRAMES/palette.png"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$FRAMES/frames.txt" -i "$FRAMES/palette.png" \
    -lavfi "$FILTER[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 "$OUT"

echo "✅ $OUT ($(du -h "$OUT" | cut -f1))"
