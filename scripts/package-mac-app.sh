#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release

app="$root/build/SketchIntentServer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/.build/release/SketchIntentServer" "$app/Contents/MacOS/SketchIntentServer"
cp "$root/mac/Info.plist" "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/SketchIntentServer"

echo "Built $app"
echo "Open it once, allow Screen Recording, then open it again."
