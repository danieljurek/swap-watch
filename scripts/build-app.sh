#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the toolchain selected by xcode-select, or an explicit DEVELOPER_DIR.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle="$PWD/dist/SwapWatch.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/SwapWatch" "$bundle/Contents/MacOS/SwapWatch"
cp Support/Info.plist "$bundle/Contents/Info.plist"

# Generate all standard-resolution and Retina representations from the source.
iconset="$PWD/.build/SwapWatch.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" swap-watch.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" swap-watch.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/SwapWatch.icns"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
printf 'Built %s\nLaunch with: open "%s"\n' "$bundle" "$bundle"
