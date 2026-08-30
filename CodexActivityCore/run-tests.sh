#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$root/.build/direct"
mkdir -p "$build_dir"

swiftc \
  "$root/Sources/CodexActivityCore/"*.swift \
  "$root/../BoringNotchXPCHelper/CodexHookBridgeClient.swift" \
  "$root/../boringNotch/Codex/CodexHookInstaller.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexBridgeServerTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexHookInstallerTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexActivityReducerTests.swift" \
  -o "$build_dir/CodexActivityCoreTests"

"$build_dir/CodexActivityCoreTests"
