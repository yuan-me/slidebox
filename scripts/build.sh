#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
configuration=release
architectures=(arm64 x86_64)
if [[ "${1:-}" == "--debug" ]]; then
  configuration=debug
  architectures=("$(uname -m)")
fi
binaries=()
for architecture in "${architectures[@]}"; do
  swift build --disable-sandbox --cache-path "$PWD/.build/cache" \
    --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" \
    --scratch-path "$PWD/.build/$architecture" --arch "$architecture" -c "$configuration"
  binaries+=("$PWD/.build/$architecture/$architecture-apple-macosx/$configuration/Slidebox")
done
app="$PWD/dist/Slidebox.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ ${#binaries[@]} -gt 1 ]]; then
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Slidebox"
else
  cp "${binaries[0]}" "$app/Contents/MacOS/Slidebox"
fi
cp Assets/Info.plist "$app/Contents/Info.plist"
cp Assets/Slidebox.icns "$app/Contents/Resources/"
for icon in Assets/deepseek.png Assets/chatgpt.png; do
  [[ -e "$icon" ]] && cp "$icon" "$app/Contents/Resources/"
done
codesign --force --sign - --entitlements Assets/Slidebox.entitlements "$app"
codesign --verify --strict "$app"
echo "Built $app"
