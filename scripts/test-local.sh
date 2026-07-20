#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_path="$(xcrun --show-sdk-path)"
developer_root="$(xcode-select -p)/Library/Developer"
host_arch="$(uname -m)"
host_major="$(sw_vers -productVersion | cut -d. -f1)"
target_triple="${host_arch}-apple-macosx${host_major}.0"
build_root="$repo_root/.build/direct-tests"
module_root="$build_root/Modules"
module_cache="$build_root/ModuleCache"

mkdir -p "$module_root" "$module_cache"

core_sources=("$repo_root"/Sources/TokPulseCore/*.swift)
test_sources=("$repo_root"/Tests/TokPulseCoreTests/*.swift)

xcrun swiftc \
    -target "$target_triple" \
    -sdk "$sdk_path" \
    -module-cache-path "$module_cache" \
    -parse-as-library \
    -whole-module-optimization \
    -enable-testing \
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
    -whole-module-optimization \
    -emit-module \
    -emit-module-path "$module_root/TokPulseCoreTests.swiftmodule" \
    -emit-object \
    -module-name TokPulseCoreTests \
    -I "$module_root" \
    -F "$developer_root/Frameworks" \
    -plugin-path "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" \
    "${test_sources[@]}" \
    -o "$build_root/TokPulseCoreTests.o"

xcrun swiftc \
    -target "$target_triple" \
    -sdk "$sdk_path" \
    -module-cache-path "$module_cache" \
    -parse-as-library \
    -F "$developer_root/Frameworks" \
    -plugin-path "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" \
    "$repo_root/scripts/DirectTestRunner.swift" \
    "$build_root/TokPulseCore.o" \
    "$build_root/TokPulseCoreTests.o" \
    -framework Testing \
    -Xlinker -rpath \
    -Xlinker "$developer_root/Frameworks" \
    -Xlinker -rpath \
    -Xlinker "$developer_root/usr/lib" \
    -o "$build_root/TokPulsePackageTests"

"$build_root/TokPulsePackageTests" --testing-library swift-testing
