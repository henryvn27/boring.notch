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
  "$root/../boringNotch/Codex/CapsLockSignalService.swift" \
  "$root/../boringNotch/Codex/CodexCostModels.swift" \
  "$root/../boringNotch/Codex/CodexPriorityTierReader.swift" \
  "$root/../boringNotch/Codex/LocalCodexCostService.swift" \
  "$root/../boringNotch/Codex/ResetForecastService.swift" \
  "$root/../boringNotch/Codex/ProviderModels.swift" \
  "$root/../boringNotch/Codex/ProviderBillingModels.swift" \
  "$root/../boringNotch/Codex/CredentialSecretStore.swift" \
  "$root/../boringNotch/Codex/ProviderAccountStore.swift" \
  "$root/../boringNotch/Codex/ProviderCostService.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexBridgeServerTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexHookInstallerTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexLifecycleTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexUsageServiceTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CapsLockSignalServiceTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexCostServiceTests.swift" \
  "$root/Tests/CodexActivityCoreTests/ProviderAccountTests.swift" \
  "$root/Tests/CodexActivityCoreTests/CodexActivityReducerTests.swift" \
  -framework AppKit \
  -framework CoreServices \
  -framework IOKit \
  -framework Security \
  -lsqlite3 \
  -o "$build_dir/CodexActivityCoreTests"

"$build_dir/CodexActivityCoreTests"
