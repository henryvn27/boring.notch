// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import AppKit
import Defaults
import SwiftUI

struct CodexApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let activityID: String
    let projectName: String
    let toolName: String
    let reason: String
    let operation: String
    let workingDirectory: String?
    let requestedAt: Date
    let expiresAt: Date

    init(bridgeEvent: CodexBridgeEvent, expiresAt: Date) {
        id = bridgeEvent.requestId
        activityID = bridgeEvent.sessionId
        projectName = CodexActivityReducer.sanitizedProjectName(from: bridgeEvent.cwd)
        toolName = Self.preview(bridgeEvent.toolName ?? "Codex action", limit: 80)
        reason = Self.preview(
            bridgeEvent.humanDescription ?? "Codex is requesting permission to continue.",
            limit: 180
        )
        operation = bridgeEvent.toolInput?.prettyPrinted() ?? reason
        workingDirectory = bridgeEvent.cwd
        requestedAt = bridgeEvent.timestamp
        self.expiresAt = expiresAt
    }

    private static func preview(_ value: String, limit: Int) -> String {
        let singleLine = value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}

struct CodexCompactActivityView: View {
    @ObservedObject var manager = CodexActivityManager.shared
    let notchWidth: CGFloat
    let height: CGFloat
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activity: ActivitySnapshot.Activity? { manager.snapshot.activities.first }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                compactWing(alignment: .trailing) {
                    Text(activity?.projectName ?? "Codex")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Color.black.frame(width: notchWidth)
                compactWing(alignment: .leading) {
                    HStack(spacing: 5) {
                        stateIcon
                        Text(statusText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(CodexCompactButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open Codex activity")
    }

    private func compactWing<Content: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 110, alignment: alignment)
            .padding(.horizontal, 9)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch activity?.state {
        case .approvalRequired:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .working:
            ProgressView().controlSize(.mini).tint(.white.opacity(0.75))
        case nil:
            Image(systemName: "terminal").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if let progress = manager.progressSnapshot {
            if progress.isStale { return "Checkpoint stale" }
            if progress.planLocked { return "\(progress.verifiedMilestones)/\(progress.totalMilestones) checks" }
            return progress.phase
        }
        guard let activity else { return "Ready" }
        let base: String
        switch activity.state {
        case .approvalRequired: base = "Approval"
        case .failed: base = "Failed"
        case .working: base = "Working"
        case .completed: base = "Done"
        }
        guard activity.subagentCount > 0 else { return base }
        return "\(base) · \(activity.subagentCount) agent\(activity.subagentCount == 1 ? "" : "s")"
    }

    private var accessibilityLabel: String {
        [activity?.projectName, statusText].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct CodexCompactButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1, anchor: .top)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

struct CodexActivityPanel: View {
    @ObservedObject private var manager = CodexActivityManager.shared
    @ObservedObject private var usage = CodexUsageManager.shared
    @ObservedObject private var cost = CodexCostManager.shared
    @Default(.codexShowQuota) private var showQuota
    @State private var integrationError: String?

    var body: some View {
        Group {
            if let approval = manager.currentApproval {
                approvalView(approval)
            } else {
                activityView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .accessibilityIdentifier("codex-activity-panel")
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: headerIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(headerColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle).font(.system(size: 13, weight: .semibold))
                    Text(activitySummary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Button {
                    SettingsWindowController.shared.showWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Codex settings")
                .accessibilityLabel("Codex settings")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().overlay(.white.opacity(0.12))

            if let progress = manager.progressSnapshot {
                agentProgressView(progress)
                Divider().overlay(.white.opacity(0.12))
            }

            if manager.snapshot.activities.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(manager.snapshot.activities.prefix(5), id: \.id) { activity in
                            activityRow(activity)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }

            if showQuota && (usage.snapshot != nil || usage.isRefreshing) {
                Divider().overlay(.white.opacity(0.12))
                usageView
            }

            if !manager.hookStatus.isHealthy || integrationError != nil {
                Divider().overlay(.white.opacity(0.12))
                integrationView
            }
        }
    }

    private func agentProgressView(_ progress: CodexAgentProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(progress.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(progress.isStale ? "Checkpoint is stale" : progress.phase)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                Text(progress.checkpointLabel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            if let fraction = progress.checkpointFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.effectiveAccent)
                    .accessibilityLabel("Verified task checkpoints")
                    .accessibilityValue(progress.checkpointLabel)
            }
            if !progress.agents.isEmpty {
                Text(agentSummary(progress.agents))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(progress.agents.prefix(3)) { agent in
                        agentProgressRow(agent)
                    }
                    if progress.agents.count > 3 {
                        Text("+\(progress.agents.count - 3) more agents")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func agentProgressRow(_ agent: CodexAgentProgressSnapshot.Agent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: agentStateIcon(agent.state))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(agentStateColor(agent.state))
                .frame(width: 10)
            Text(agent.title)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.white.opacity(0.28))
            Text(agent.phase)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.title)
        .accessibilityValue("\(agentStateLabel(agent.state)), \(agent.phase)")
    }

    private func agentSummary(_ agents: [CodexAgentProgressSnapshot.Agent]) -> String {
        let working = agents.count { $0.state == .working }
        let blocked = agents.count { $0.state == .blocked }
        var parts = ["\(agents.count) agent\(agents.count == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }

    private func agentStateIcon(_ state: CodexAgentWorkState) -> String {
        switch state {
        case .planning: "circle.dotted"
        case .working: "circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func agentStateColor(_ state: CodexAgentWorkState) -> Color {
        switch state {
        case .planning: .white.opacity(0.55)
        case .working: .effectiveAccent
        case .blocked: .orange
        case .completed: .green
        case .failed: .red
        }
    }

    private func agentStateLabel(_ state: CodexAgentWorkState) -> String {
        switch state {
        case .planning: "Planning"
        case .working: "Working"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private var usageView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Codex quota", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                if usage.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        usage.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh Codex quota")
                    .accessibilityLabel("Refresh Codex quota")
                }
            }

            if let snapshot = usage.snapshot {
                HStack(spacing: 16) {
                    ForEach(Array(snapshot.limits.prefix(2))) { limit in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(limit.remainingPercent.rounded()))% quota left")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            HStack(spacing: 3) {
                                Text(limit.name)
                                if let reset = limit.resetsAt {
                                    Text("· resets")
                                    Text(reset, style: .relative)
                                }
                            }
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                            if let pace = limit.pace() {
                                Text(pace.label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(
                                        pace == .mayExhaustBeforeReset
                                            ? Color.orange : Color.white.opacity(0.48)
                                    )
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let estimate = cost.estimate {
                HStack(spacing: 5) {
                    Text("API-price equivalent")
                        .foregroundStyle(.white.opacity(0.52))
                    Text(
                        NSDecimalNumber(decimal: estimate.measurement.amount).doubleValue,
                        format: .currency(code: estimate.measurement.currency)
                    )
                    .fontWeight(.semibold)
                    Text("· this Mac estimate")
                        .foregroundStyle(.white.opacity(0.52))
                }
                .font(.system(size: 9.5))
                .accessibilityElement(children: .combine)
            }

            if let forecast = cost.forecast {
                HStack(spacing: 5) {
                    Text(ResetForecast.sourceName)
                        .foregroundStyle(.white.opacity(0.52))
                    Text(forecast.scoreLabel)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 9.5))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text("No active Codex work")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Sessions appear here as Codex starts working.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .accessibilityElement(children: .combine)
    }

    private func activityRow(_ activity: ActivitySnapshot.Activity) -> some View {
        HStack(spacing: 10) {
            rowIcon(activity.state).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.projectName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(rowDetail(activity))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowIcon(_ state: ActivitySnapshot.Activity.State) -> some View {
        switch state {
        case .working: ProgressView().controlSize(.mini).tint(.white.opacity(0.72))
        case .approvalRequired: Image(systemName: "exclamationmark").foregroundStyle(.orange)
        case .completed: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").foregroundStyle(.red)
        }
    }

    private func rowDetail(_ activity: ActivitySnapshot.Activity) -> String {
        let state: String
        switch activity.state {
        case .working: state = "Working"
        case .approvalRequired: state = "Approval required"
        case .completed: state = "Completed"
        case .failed: state = "Failed"
        }
        guard activity.subagentCount > 0 else { return state }
        return "\(state) · \(activity.subagentCount) active agent\(activity.subagentCount == 1 ? "" : "s")"
    }

    private var integrationView: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex integration needs attention")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(integrationError ?? manager.hookStatus.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
            }
            Spacer()
            Button("Repair") {
                do {
                    try manager.installCodexIntegration()
                    integrationError = nil
                } catch {
                    integrationError = error.localizedDescription
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func approvalView(_ request: CodexApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.projectName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(request.toolName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
            }

            Text(request.reason)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)

            Text(request.operation)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Deny") {
                    manager.resolveApproval(id: request.id, decision: .deny)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("d", modifiers: .command)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request.operation, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy operation")
                .accessibilityLabel("Copy operation")
                Button("Open Codex") {
                    CodexActivationService.openCodex(fallbackDirectory: request.workingDirectory)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Allow once") {
                    manager.resolveApproval(id: request.id, decision: .allow)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var primaryActivity: ActivitySnapshot.Activity? { manager.snapshot.activities.first }

    private var headerTitle: String {
        switch primaryActivity?.state {
        case .working: "Codex is working"
        case .approvalRequired: "Approval required"
        case .completed: "Codex finished"
        case .failed: "Codex needs attention"
        case nil: "Codex activity"
        }
    }

    private var activitySummary: String {
        let active = manager.snapshot.activities.count { $0.state == .working || $0.state == .approvalRequired }
        let agents = manager.snapshot.activities.reduce(0) { $0 + $1.subagentCount }
        if active == 0 { return manager.snapshot.availability == .stale ? "Activity may be stale" : "Ready" }
        return "\(active) active session\(active == 1 ? "" : "s")" + (agents > 0 ? " · \(agents) agent\(agents == 1 ? "" : "s")" : "")
    }

    private var headerIcon: String {
        switch primaryActivity?.state {
        case .working: "waveform.path"
        case .approvalRequired: "exclamationmark.shield"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case nil: "terminal"
        }
    }

    private var headerColor: Color {
        switch primaryActivity?.state {
        case .approvalRequired: .orange
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }
}
