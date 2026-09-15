#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the toolchain selected by xcode-select, or an explicit DEVELOPER_DIR.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
bundle="$PWD/dist/SwapWatch.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/SwapWatch" "$bundle/Contents/MacOS/SwapWatch"
cp Support/Info.plist "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
printf 'Built %s\nLaunch with: open "%s"\n' "$bundle" "$bundle"
