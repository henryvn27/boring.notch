#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$root/.build/direct"
mkdir -p "$build_dir"

swiftc \
  "$root/Sources/CodexActivityCore/"*.swift \
  "$root/../BoringNotchXPCHelper/CodexHookBridgeClient.swift" \
  "$root/../boringNotch/Codex/CodexHookInstaller.swift" \
  "$root/../boringNotch/Codex/CodexLocalSessionObserver.swift" \
  "$root/../boringNotch/Codex/BoundedProcessRunner.swift" \
  "$root/../boringNotch/Codex/CodexExecutableLocator.swift" \
  "$root/../boringNotch/Codex/CodexUsage.swift" \
  "$root/../boringNotch/Codex/CodexUsageService.swift" \
  "$root/../boringNotch/Codex/JSONRPCResponseCursor.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexBridgeServerTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexHookInstallerTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexLifecycleTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexUsageServiceTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexActivityReducerTests.swift" \
  -framework AppKit \
  -framework CoreServices \
  -o "$build_dir/CodexActivityCoreTests"

"$build_dir/CodexActivityCoreTests"
