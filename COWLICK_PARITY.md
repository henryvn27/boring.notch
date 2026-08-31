# Cowlick capability parity

This fork keeps Boring Notch as the product and windowing foundation while integrating Cowlick's Codex capabilities as a native notch tab and settings surface. Cowlick's separate window system was intentionally not copied.

## Audited sources

- Boring Notch foundation: `TheBoredTeam/boring.notch` at `99900bf630a3d3e97fae079df2175993318d51f7`.
- Cowlick capability source: `henryvn27/cowlick` `origin/main` at `2fc8c7222a6a4ac9806c151c82602d2b1d9a61e0`.
- Combined implementation: public `dev` through pull request [#9](https://github.com/henryvn27/boring.notch/pull/9), merged as `c5fad2574ef5541f45b0fb83cb3e75334f040e7e`.

## Matrix

| Cowlick capability | Combined implementation | Verification |
| --- | --- | --- |
| Local hook transport and lifecycle state | `BoringNotchXPCHelper/`, `CodexBridgeProtocol.swift`, `CodexBridgeServer.swift`, `CodexLifecycleLedger.swift` | Bridge, lifecycle, and protocol tests |
| Independent sessions, subagents, project context, completion, failure, and stale state | `CodexActivityReducer.swift`, `ActivitySnapshot.swift`, `CodexLocalSessionObserver.swift` | Reducer and lifecycle tests |
| Exact-request approvals that fail closed | `CodexBridgeServer.swift`, `CodexActivityViews.swift` | Bridge and reducer approval tests |
| Compact and expanded Codex notch surfaces | `CodexActivityViews.swift`, `ContentView.swift`, `BoringHeader.swift` | Three macOS CI build lanes and launchable-app visual proof |
| Official Codex quota windows, used/remaining semantics, reset time, and pace | `CodexUsageService.swift`, `CodexUsage.swift`, `CodexActivityViews.swift` | Usage parsing and pace tests |
| Local API-price-equivalent cost context and reset forecast | `LocalCodexCostService.swift`, `ResetForecastService.swift`, `CodexCostManager.swift` | Cost and reset parsing tests |
| Multiple OpenAI and Anthropic organization billing accounts | `ProviderAccountStore.swift`, `ProviderAccountsManager.swift`, `ProviderCostService.swift`, `ProviderAccountsView.swift` | Provider account and billing tests |
| Keychain-only provider credentials and explicit privacy labels | `CredentialSecretStore.swift`, provider account views, sanitized diagnostics | Credential cleanup and account-store tests |
| First-run activity consent, hook install/repair, trust check, and self-test | `CodexHookInstaller.swift`, `CodexHookTrustService.swift`, `IntegrationSelfTestService.swift`, `CodexSettingsView.swift` | Consent-policy, installer, trust, and integration tests |
| Open Codex, approval attention, optional Caps Lock signaling, accessibility, and Reduce Motion | `CodexActivationService.swift`, `CapsLockSignalService.swift`, `CodexActivityViews.swift` | Caps Lock tests, accessibility labels, Reduce Motion path, visual proof |
| Local-first diagnostics and bounded process execution | `BoundedProcessRunner.swift`, `CodexSettingsView.swift` | Diagnostics output excludes prompts, tool input, approval details, full home paths, tokens, and credentials |
| Updates | Existing Boring Notch Sparkle update controls are preserved; Cowlick's parallel updater was not copied | Existing project builds and update configuration remain in the Boring Notch foundation |
| Honest Codex agent progress | `CodexAgentProgressStore.swift`, helper `progress` command, `CODEX_PROGRESS_PROTOCOL.md` | Focused tests plus launch proof showing one aggregate evidence-backed bar and no per-agent percentages |

## Progress accuracy model

The progress surface does not accept a raw percentage. A coordinator writes a locked, versioned milestone set to an owner-private application-support file through the installed helper. The app computes coverage only from milestones reported `verified` with timestamped evidence and shows the latest evidence label without pretending to rerun arbitrary checks. A changed plan must first publish unlocked under a higher revision, active root or agent data becomes stale after five minutes, and the document expires after 24 hours. Completion requires every milestone and declared agent to agree. Agents contribute state and phase text but never receive separate percentage bars.

See [CODEX_PROGRESS_PROTOCOL.md](CODEX_PROGRESS_PROTOCOL.md) for the schema, limits, privacy rules, and example command.

## Licensing and provenance

The combined repository remains GPLv3 under the root [LICENSE](LICENSE). Cowlick-derived code retains its MIT provenance in source headers and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). The Ping Island hosting view used by Cowlick was not ported because this integration reuses Boring Notch's existing windowing architecture.
