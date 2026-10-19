#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
configuration=${1:-debug}
output_dir="$repo_root/dist"
app_dir="$output_dir/IMacAsMonitor.app"

cd "$repo_root"
mkdir -p "$repo_root/.build/clang-cache"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/clang-cache"
swift build --disable-sandbox -c "$configuration" -debug-info-format none --arch arm64 --arch x86_64

binary_path=$(swift build --disable-sandbox -c "$configuration" -debug-info-format none --arch arm64 --arch x86_64 --show-bin-path)
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path/IMacAsMonitor" "$app_dir/Contents/MacOS/IMacAsMonitor"
cp "$repo_root/AppResources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_root/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
