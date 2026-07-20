#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_path="$(xcrun --show-sdk-path)"
host_arch="$(uname -m)"
host_major="$(sw_vers -productVersion | cut -d. -f1)"
target_triple="${host_arch}-apple-macosx${host_major}.0"
build_root="$repo_root/.build/direct"
module_root="$build_root/Modules"
module_cache="$build_root/ModuleCache"
app_bundle="$repo_root/.build/TokPulse.app"

mkdir -p "$module_root" "$module_cache"

core_sources=("$repo_root"/Sources/TokPulseCore/*.swift)
app_sources=("$repo_root"/Sources/TokPulseApp/*.swift)

xcrun swiftc \
    -target "$target_triple" \
    -sdk "$sdk_path" \
    -module-cache-path "$module_cache" \
    -parse-as-library \
    -whole-module-optimization \
    -emit-module \
    -emit-module-path "$module_root/TokPulseCore.swiftmodule" \
    -emit-object \
    -module-name TokPulseCore \
    "${core_sources[@]}" \
    -o "$build_root/TokPulseCore.o"

xcrun swiftc \
    -target "$target_triple" \
    -sdk "$sdk_path" \
    -module-cache-path "$module_cache" \
    -parse-as-library \
    -I "$module_root" \
    "${app_sources[@]}" \
    "$build_root/TokPulseCore.o" \
    -o "$build_root/TokPulse"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$build_root/TokPulse" "$app_bundle/Contents/MacOS/TokPulse"
cp "$repo_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$host_major.0" \
    "$app_bundle/Contents/Info.plist"
codesign --force --sign - "$app_bundle" >/dev/null

echo "$app_bundle"
