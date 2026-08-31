// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import AppKit
import Defaults
import SwiftUI

struct CodexSettingsView: View {
    @ObservedObject private var manager = CodexActivityManager.shared
    @ObservedObject private var usage = CodexUsageManager.shared
    @ObservedObject private var cost = CodexCostManager.shared
    @Default(.codexShowQuota) private var showQuota
    @Default(.codexAutoOpenApprovals) private var autoOpenApprovals
    @Default(.codexApprovalTimeout) private var approvalTimeout
    @Default(.codexCapsLockSignals) private var capsLockSignals
    @Default(.codexCapsLockFlashCount) private var capsLockFlashCount
    @Default(.codexLocalCostEstimate) private var localCostEstimate
    @Default(.codexCostWindow) private var costWindow
    @Default(.codexResetForecast) private var resetForecast
    @State private var integrationError: String?
    @State private var capsLockStatus = "Not tested"
    @State private var diagnostics = ""
    @State private var confirmRemoval = false
    @State private var isRunningSelfTest = false
    @State private var isTestingCapsLock = false
    @State private var copiedSetting: CopiedSetting?

    var body: some View {
        Form {
            Section {
                Picker("Show in the notch", selection: displayModeBinding) {
                    ForEach(CodexDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(manager.displayMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let integrationError {
                    Text(integrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Codex display")
            } footer: {
                Text("Usage only requests official account quota but does not monitor or show current tasks. Full activity observes local lifecycle metadata without retaining prompts or tool input in checkpoints.")
            }

            if manager.displayMode == .fullActivity {
            if manager.isUITesting {
                Section {
                    Label(
                        "Simulated Codex activity is shown for visual QA. Real integration health is hidden and cannot be changed here.",
                        systemImage: "testtube.2"
                    )
                } header: {
                    Text("Visual QA")
                }
            }

            Section {
                LabeledContent("Hooks", value: integrationStatus(manager.hookStatus.summary))
                LabeledContent("Hook trust", value: integrationStatus(manager.hookTrust.state.summary))
                LabeledContent("Self-test", value: integrationStatus(manager.selfTestStatus))
                LabeledContent("Local bridge", value: manager.isUITesting ? "Simulated" : manager.bridgeStatus)
                LabeledContent(
                    "Transcript observation",
                    value: manager.isUITesting ? "Off in visual QA" : manager.localObservationStatus
                )
                LabeledContent("Codex executable") {
                    Text(manager.isUITesting ? "Hidden in visual QA" : manager.executableStatus)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(manager.isUITesting ? "Hidden in visual QA" : manager.executableStatus)
                }

                if let integrationError {
                    Text(integrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if manager.isUITesting {
                    Text("Integration changes are disabled in visual QA.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(integrationActionTitle) {
                            do {
                                try manager.installCodexIntegration()
                                integrationError = nil
                                refreshDiagnostics()
                            } catch {
                                integrationError = CodexActivityManager.sanitized(
                                    error.localizedDescription
                                )
                            }
                        }
                        Button("Remove Integration", role: .destructive) {
                            confirmRemoval = true
                        }
                        .disabled(
                            !manager.hookStatus.configurationExists
                                && !manager.hookStatus.helperInstalled
                        )
                        Spacer()
                        Button("Refresh") {
                            manager.refreshCodexIntegrationStatus()
                            manager.refreshHookTrust()
                            refreshDiagnostics()
                        }
                    }
                    HStack {
                        Button("Check Trust") { manager.refreshHookTrust() }
                        Button(copiedSetting == .hooks ? "Copied /hooks" : "Copy /hooks") {
                            NSPasteboard.general.clearContents()
                            if NSPasteboard.general.setString("/hooks", forType: .string) {
                                markCopied(.hooks)
                            }
                        }
                        Button(isRunningSelfTest ? "Running Self-Test…" : "Run Self-Test") {
                            Task {
                                isRunningSelfTest = true
                                await manager.runIntegrationSelfTest()
                                isRunningSelfTest = false
                                refreshDiagnostics()
                            }
                        }
                        .disabled(!manager.hookStatus.helperInstalled || isRunningSelfTest)
                    }
                }
            } header: {
                Text("Integration")
            } footer: {
                Text("Install and repair preserve unrelated entries in ~/.codex/hooks.json. Removing only deletes boring.notch-owned hooks and helper files.")
            }

            Section {
                Toggle("Open the Codex tab for approval requests", isOn: $autoOpenApprovals)
                Toggle("Show account quota in the notch", isOn: $showQuota)
                Picker("Approval timeout", selection: $approvalTimeout) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                }
                Button(usage.isRefreshing ? "Refreshing Quota…" : "Refresh Official Quota") {
                    usage.refresh()
                }
                .disabled(usage.isRefreshing || !manager.isActivityEnabled)
                if let error = usage.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Activity and approvals")
            } footer: {
                Text("Quota percentages describe account capacity only. boring.notch never treats them as task-completion estimates. Approval timeout changes apply after restarting the app.")
            }
            .disabled(!manager.isActivityEnabled)

            Section {
                Toggle("Enable Caps Lock signaling", isOn: $capsLockSignals)
                    .onChange(of: capsLockSignals) {
                        if !capsLockSignals { manager.disableCapsLockSignal() }
                    }
                Stepper(
                    "Completion flashes: \(capsLockFlashCount)",
                    value: $capsLockFlashCount,
                    in: CapsLockPattern.completionFlashCountRange
                )
                .disabled(!capsLockSignals)
                LabeledContent("Support", value: capsLockStatus)
                Button(isTestingCapsLock ? "Testing Caps Lock Signal…" : "Test Caps Lock Signal") {
                    Task {
                        isTestingCapsLock = true
                        let result = await manager.testCapsLockSignal()
                        capsLockStatus = result == .available
                            ? "Native HID signal test passed" : result.summary
                        if result != .available { capsLockSignals = false }
                        isTestingCapsLock = false
                    }
                }
                .disabled(!capsLockSignals || isTestingCapsLock)
            } header: {
                Text("Caps Lock signal")
            } footer: {
                Text("Signals always restore the original Caps Lock state. Approval attention remains inverted only while an exact request is pending. macOS may require Input Monitoring or Accessibility permission.")
            }
            .disabled(!manager.isActivityEnabled)

            Section {
                Toggle("Estimate API-price equivalent from local transcripts", isOn: $localCostEstimate)
                    .onChange(of: localCostEstimate) { cost.refresh() }
                Picker("Estimate window", selection: $costWindow) {
                    ForEach(APICostWindow.allCases) { window in
                        Text(window.label).tag(window.rawValue)
                    }
                }
                .disabled(!localCostEstimate)
                .onChange(of: costWindow) { cost.refresh() }
                if let estimate = cost.estimate {
                    LabeledContent(
                        "Local estimate",
                        value: NSDecimalNumber(decimal: estimate.measurement.amount).doubleValue
                            .formatted(.currency(code: estimate.measurement.currency))
                    )
                    LabeledContent(
                        "Coverage",
                        value: estimate.measurement.coverage == .thisMac ? "This Mac" : "Partial"
                    )
                    if !estimate.exclusionReasons.isEmpty {
                        Text("\(estimate.exclusionReasons.count) uncertainty flag(s); tool fees are excluded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Show third-party reset forecast", isOn: $resetForecast)
                    .onChange(of: resetForecast) { cost.refresh() }
                if resetForecast {
                    Text("\(ResetForecast.sourceName): \(ResetForecast.disclaimer)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Open source website", destination: ResetForecast.sourceURL)
                }
                HStack {
                    Button(cost.isRefreshing ? "Refreshing…" : "Refresh") { cost.refresh() }
                        .disabled(cost.isRefreshing || (!localCostEstimate && !resetForecast))
                    Button("Reset Local Cost Cache") { cost.resetLocalCache() }
                        .disabled(!localCostEstimate)
                }
            } header: {
                Text("Cost and reset context")
            } footer: {
                Text("The local number is an API-price equivalent, not a subscription bill. It reads token counters only and never retains prompt or tool content. The reset forecast is opt-in network data from an attributed third party.")
            }
            .disabled(!manager.isActivityEnabled)

            ProviderAccountsSettingsSection()

            Section {
                LabeledContent(
                    "Checkpoint file",
                    value: manager.progressSnapshot?.checkpointLabel
                        ?? manager.progressError
                        ?? "Not published"
                )
                if let progress = manager.progressSnapshot {
                    LabeledContent("Phase", value: progress.phase)
                    LabeledContent("Plan revision", value: String(progress.planRevision))
                    LabeledContent("Freshness", value: progress.isStale ? "Stale" : "Current")
                }
                HStack {
                    Button("Refresh Checkpoint") { manager.refreshAgentProgress() }
                        .disabled(!manager.isActivityEnabled)
                    Spacer()
                    Link(
                        "Protocol",
                        destination: URL(string: "https://github.com/henryvn27/boring.notch/blob/dev/CODEX_PROGRESS_PROTOCOL.md")!
                    )
                }
            } header: {
                Text("Agent progress")
            } footer: {
                Text("boring.notch shows one aggregate bar only for a current, locked plan, computed from agent-reported verified milestones with timestamped evidence. It exposes the latest evidence label but does not rerun the underlying check. Agents never submit raw percentages or individual bars.")
            }
            } else if manager.displayMode == .usageOnly {
                Section {
                    LabeledContent("Current tasks", value: "Hidden")
                    LabeledContent("Agents and progress", value: "Hidden")
                    Button(usage.isRefreshing ? "Refreshing Quota…" : "Refresh Official Quota") {
                        usage.refresh()
                    }
                    .disabled(usage.isRefreshing)
                    if let limit = usage.snapshot?.primaryLimit {
                        LabeledContent(
                            limit.name,
                            value: "\(Int(limit.remainingPercent.rounded()))% left"
                        )
                    }
                    if let error = usage.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Usage only")
                } footer: {
                    Text("No task names, agent rows, checkpoint bars, approval requests, or local transcript estimates appear in this mode.")
                }
            }

            Section {
                TextEditor(text: .constant(diagnostics))
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(minHeight: 145)
                    .textSelection(.enabled)

                HStack {
                    Button(
                        copiedSetting == .diagnostics
                            ? "Diagnostics Copied" : "Copy Diagnostics"
                    ) {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(diagnostics, forType: .string) {
                            markCopied(.diagnostics)
                        }
                    }
                    Spacer()
                    Button("Refresh Diagnostics") { refreshDiagnostics() }
                }
            } header: {
                Text("Sanitized diagnostics")
            } footer: {
                Text("The report excludes prompts, tool input, approval details, full home paths, tokens, and account credentials. Software updates continue to use boring.notch's existing Sparkle controls in About.")
            }
        }
        .navigationTitle("Codex")
        .accentColor(.effectiveAccent)
        .onAppear {
            manager.refreshCodexIntegrationStatus()
            manager.refreshHookTrust()
            refreshDiagnostics()
        }
        .confirmationDialog("Remove boring.notch Codex integration?", isPresented: $confirmRemoval) {
            Button("Remove", role: .destructive) {
                do {
                    try manager.removeCodexIntegration()
                    integrationError = nil
                    refreshDiagnostics()
                } catch {
                    integrationError = CodexActivityManager.sanitized(error.localizedDescription)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Other Codex hooks and settings will be preserved.")
        }
    }

    private func refreshDiagnostics() {
        diagnostics = manager.diagnosticsReport()
    }

    private var displayModeBinding: Binding<CodexDisplayMode> {
        Binding(
            get: { manager.displayMode },
            set: { mode in
                do {
                    try manager.setDisplayMode(mode)
                    integrationError = nil
                    refreshDiagnostics()
                } catch {
                    integrationError = CodexActivityManager.sanitized(error.localizedDescription)
                }
            }
        )
    }

    private func integrationStatus(_ value: String) -> String {
        manager.isUITesting ? "Hidden in visual QA" : value
    }

    private var integrationActionTitle: String {
        if manager.hookStatus.isHealthy { return "Repair Integration" }
        if manager.hookStatus.hasLegacyIntegration { return "Migrate Cowlick Integration" }
        return "Install Integration"
    }

    private func markCopied(_ setting: CopiedSetting) {
        copiedSetting = setting
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedSetting == setting { copiedSetting = nil }
        }
    }

    private enum CopiedSetting {
        case hooks
        case diagnostics
    }
}
