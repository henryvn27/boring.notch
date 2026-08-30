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

    var body: some View {
        Form {
            Section {
                LabeledContent("Hooks", value: manager.hookStatus.summary)
                LabeledContent("Local bridge", value: manager.bridgeStatus)
                LabeledContent("Transcript observation", value: manager.localObservationStatus)
                LabeledContent("Codex executable", value: manager.executableStatus)

                if let integrationError {
                    Text(integrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button(manager.hookStatus.isHealthy ? "Repair Integration" : "Install Integration") {
                        do {
                            try manager.installCodexIntegration()
                            integrationError = nil
                            refreshDiagnostics()
                        } catch {
                            integrationError = error.localizedDescription
                        }
                    }
                    Button("Remove Integration", role: .destructive) {
                        confirmRemoval = true
                    }
                    .disabled(!manager.hookStatus.configurationExists && !manager.hookStatus.helperInstalled)
                    Spacer()
                    Button("Refresh") {
                        manager.refreshCodexIntegrationStatus()
                        refreshDiagnostics()
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
                .disabled(usage.isRefreshing)
                if let error = usage.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Activity and approvals")
            } footer: {
                Text("Quota percentages describe account capacity only. boring.notch never treats them as task-completion estimates. Approval timeout changes apply after restarting the app.")
            }

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
                Button("Test Caps Lock Signal") {
                    Task {
                        let result = await manager.testCapsLockSignal()
                        capsLockStatus = result == .available
                            ? "Native HID signal test passed" : result.summary
                        if result != .available { capsLockSignals = false }
                    }
                }
                .disabled(!capsLockSignals)
            } header: {
                Text("Caps Lock signal")
            } footer: {
                Text("Signals always restore the original Caps Lock state. Approval attention remains inverted only while an exact request is pending. macOS may require Input Monitoring or Accessibility permission.")
            }

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

            ProviderAccountsSettingsSection()

            Section {
                TextEditor(text: .constant(diagnostics))
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(minHeight: 145)
                    .textSelection(.enabled)

                HStack {
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics, forType: .string)
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
            refreshDiagnostics()
        }
        .confirmationDialog("Remove boring.notch Codex integration?", isPresented: $confirmRemoval) {
            Button("Remove", role: .destructive) {
                do {
                    try manager.removeCodexIntegration()
                    integrationError = nil
                    refreshDiagnostics()
                } catch {
                    integrationError = error.localizedDescription
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
}
