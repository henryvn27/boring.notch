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
    private var presentationState: CodexActivityPresentationState {
        CodexActivityPresentation.resolve(
            activity: manager.snapshot,
            progress: manager.progressSnapshot,
            hasApproval: manager.currentApproval != nil
        )
    }
    private var displayName: String {
        manager.progressSnapshot?.title ?? activity?.projectName ?? "Codex"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                compactWing(alignment: .trailing) {
                    Text(displayName)
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
        switch presentationState {
        case .approvalRequired:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .stale:
            Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
        case .blocked:
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .working:
            if reduceMotion {
                Image(systemName: "circle.fill").foregroundStyle(Color.effectiveAccent)
            } else {
                ProgressView().controlSize(.mini).tint(.white.opacity(0.75))
            }
        case .idle:
            Image(systemName: "terminal").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch presentationState {
        case .approvalRequired: return "Approval"
        case .failed: return "Failed"
        case .stale: return "Checkpoint stale"
        case .blocked: return "Blocked"
        case .completed: return "Done"
        case .idle: return "Ready"
        case .working:
            if let progress = manager.progressSnapshot, progress.planLocked,
               progress.verifiedMilestones < progress.totalMilestones
            {
                return "\(progress.verifiedMilestones)/\(progress.totalMilestones) checks"
            }
            guard let activity, activity.subagentCount > 0 else { return "Working" }
            return "Working · \(activity.subagentCount) agent\(activity.subagentCount == 1 ? "" : "s")"
        }
    }

    private var accessibilityLabel: String {
        var parts = [displayName, statusText]
        if let progress = manager.progressSnapshot, presentationState == .working {
            parts.append(progress.checkpointLabel)
        }
        return parts.joined(separator: ", ")
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
    @State private var copiedApprovalID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    SettingsWindowController.shared.showWindow(selectedTab: .codex)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Codex settings")
                .accessibilityLabel("Codex settings")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().overlay(.white.opacity(0.12))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !manager.snapshot.activities.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(manager.snapshot.activities.prefix(5), id: \.id) { activity in
                                activityRow(activity)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        if manager.snapshot.activities.count > 5 {
                            Text("+\(manager.snapshot.activities.count - 5) more sessions")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.62))
                                .padding(.horizontal, 14)
                                .padding(.bottom, 7)
                                .accessibilityLabel(
                                    "\(manager.snapshot.activities.count - 5) more Codex sessions"
                                )
                        }
                    }

                    if let progress = manager.progressSnapshot {
                        if !manager.snapshot.activities.isEmpty {
                            Divider().overlay(.white.opacity(0.12))
                        }
                        agentProgressView(progress)
                    }

                    if manager.snapshot.activities.isEmpty && manager.progressSnapshot == nil
                        && manager.progressError == nil
                    {
                        emptyState
                    }

                    if let progressError = manager.progressError {
                        if !manager.snapshot.activities.isEmpty || manager.progressSnapshot != nil {
                            Divider().overlay(.white.opacity(0.12))
                        }
                        progressErrorView(progressError)
                    }

                    if manager.isActivityEnabled && showQuota
                        && (usage.snapshot != nil || usage.isRefreshing)
                    {
                        Divider().overlay(.white.opacity(0.12))
                        usageView
                    }

                    if manager.isActivityEnabled
                        && !manager.isUITesting
                        && (!manager.hookStatus.isHealthy
                            || manager.bridgeError != nil || integrationError != nil)
                    {
                        Divider().overlay(.white.opacity(0.12))
                        integrationView
                    }
                }
            }
        }
    }

    private func agentProgressView(_ progress: CodexAgentProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(progress.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(progressPhaseLabel(progress))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                Spacer()
                Label(
                    progress.checkpointLabel,
                    systemImage: progress.isComplete ? "checkmark.seal.fill" : "checklist"
                )
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(progress.isComplete ? Color.green : Color.white.opacity(0.72))
                .lineLimit(1)
            }
            if let fraction = progress.checkpointFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.effectiveAccent)
                    .accessibilityLabel("Verified task checkpoints")
                    .accessibilityValue(progress.checkpointLabel)
            }
            if let milestone = progress.latestVerifiedMilestone,
               let evidence = milestone.evidence
            {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Latest reported evidence · \(milestone.title)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(evidence)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            if !progress.agents.isEmpty {
                Text(agentSummary(progress.agents))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(progress.agents.prefix(3)) { agent in
                        agentProgressRow(agent)
                    }
                    if progress.agents.count > 3 {
                        Text("+\(progress.agents.count - 3) more agents")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.62))
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
            Image(systemName: agentStateIcon(agent))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(agentStateColor(agent))
                .frame(width: 10)
            Text(agent.title)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.white.opacity(0.28))
            Text(agent.phase)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.title)
        .accessibilityValue("\(agentStateLabel(agent)), \(agent.phase)")
    }

    private func agentSummary(_ agents: [CodexAgentProgressSnapshot.Agent]) -> String {
        let working = agents.count { $0.state == .working }
        let blocked = agents.count { $0.state == .blocked }
        let stale = agents.count { $0.isStale }
        var parts = ["\(agents.count) agent\(agents.count == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if stale > 0 { parts.append("\(stale) stale") }
        return parts.joined(separator: " · ")
    }

    private func agentStateIcon(_ agent: CodexAgentProgressSnapshot.Agent) -> String {
        if agent.isStale { return "clock.badge.exclamationmark.fill" }
        switch agent.state {
        case .planning: return "circle.dotted"
        case .working: return "circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func agentStateColor(_ agent: CodexAgentProgressSnapshot.Agent) -> Color {
        if agent.isStale { return .orange }
        switch agent.state {
        case .planning: return .white.opacity(0.55)
        case .working: return .effectiveAccent
        case .blocked: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func agentStateLabel(_ agent: CodexAgentProgressSnapshot.Agent) -> String {
        if agent.isStale { return "Stale" }
        switch agent.state {
        case .planning: return "Planning"
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private func progressPhaseLabel(_ progress: CodexAgentProgressSnapshot) -> String {
        if progress.isStale { return "Checkpoint is stale — verify before trusting it" }
        if progress.isComplete { return "Completed with verified evidence" }
        return progress.phase
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
                    .buttonStyle(.borderless)
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
            Image(systemName: manager.isActivityEnabled ? "terminal" : "eye.slash")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(manager.isActivityEnabled ? "No active Codex work" : "Codex activity is off")
                .font(.system(size: 12.5, weight: .semibold))
            Text(
                manager.isActivityEnabled
                    ? "Sessions appear here as Codex starts working."
                    : "Turn it on in Codex settings when you want local monitoring."
            )
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .accessibilityElement(children: .combine)
    }

    private func progressErrorView(_ error: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent checkpoint unavailable")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") { manager.refreshAgentProgress() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
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
        case .working:
            if reduceMotion {
                Image(systemName: "circle.fill").foregroundStyle(Color.effectiveAccent)
            } else {
                ProgressView().controlSize(.mini).tint(.white.opacity(0.72))
            }
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
                Text(integrationTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(integrationError ?? manager.bridgeError ?? manager.hookStatus.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
            }
            Spacer()
            Button(integrationActionTitle) {
                do {
                    if manager.hookStatus.isHealthy, manager.bridgeError != nil {
                        try manager.retryActivityServices()
                    } else {
                        try manager.installCodexIntegration()
                    }
                    integrationError = nil
                } catch {
                    integrationError = CodexActivityManager.sanitized(error.localizedDescription)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var integrationTitle: String {
        manager.hookStatus.isHealthy && manager.bridgeError != nil
            ? "Codex connection needs attention" : "Codex integration needs attention"
    }

    private var integrationActionTitle: String {
        if manager.hookStatus.isHealthy, manager.bridgeError != nil { return "Retry" }
        if manager.hookStatus.hasLegacyIntegration { return "Migrate" }
        if manager.hookStatus.installedEvents.isEmpty && !manager.hookStatus.helperInstalled {
            return "Install"
        }
        return "Repair"
    }

    private func approvalView(_ request: CodexApprovalRequest) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            approvalContent(request, now: context.date)
        }
    }

    private func approvalContent(_ request: CodexApprovalRequest, now: Date) -> some View {
        let secondsRemaining = max(0, Int(ceil(request.expiresAt.timeIntervalSince(now))))
        return VStack(alignment: .leading, spacing: 9) {
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
                Text(secondsRemaining > 0 ? "Defers safely in \(secondsRemaining)s" : "Deferred safely")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(secondsRemaining > 5 ? Color.white.opacity(0.7) : Color.orange)
                    .fixedSize()
            }

            Text(request.reason)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)

            ScrollView(.vertical, showsIndicators: true) {
                Text(request.operation)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.76))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 40, maxHeight: 78)
            .padding(7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Requested operation")

            HStack(spacing: 8) {
                Button("Deny") {
                    manager.resolveApproval(id: request.id, decision: .deny)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("d", modifiers: .command)
                Button(copiedApprovalID == request.id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(request.operation, forType: .string) {
                        copiedApprovalID = request.id
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if copiedApprovalID == request.id { copiedApprovalID = nil }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .help("Copy operation")
                Button("Not now") {
                    manager.resolveApproval(id: request.id, decision: .deferDecision)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("Return this request to Codex without allowing or denying it")
                Button("Open Codex") {
                    CodexActivationService.openCodex(fallbackDirectory: request.workingDirectory)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Allow once") {
                    manager.resolveApproval(id: request.id, decision: .allow)
                }
                .buttonStyle(.borderedProminent)
                .disabled(secondsRemaining == 0)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var presentationState: CodexActivityPresentationState {
        CodexActivityPresentation.resolve(
            activity: manager.snapshot,
            progress: manager.progressSnapshot,
            hasApproval: manager.currentApproval != nil
        )
    }

    private var headerTitle: String {
        switch presentationState {
        case .approvalRequired: "Approval required"
        case .failed: "Codex needs attention"
        case .stale: "Codex update is stale"
        case .blocked: "Codex is blocked"
        case .working: "Codex is working"
        case .completed: "Codex finished"
        case .idle: "Codex activity"
        }
    }

    private var activitySummary: String {
        let active = manager.snapshot.activities.count { $0.state == .working || $0.state == .approvalRequired }
        let lifecycleAgents = manager.snapshot.activities.reduce(0) { $0 + $1.subagentCount }
        let checkpointAgents = manager.progressSnapshot?.agents.count ?? 0
        switch presentationState {
        case .approvalRequired: return "Review the complete operation before allowing it"
        case .failed: return "A session or agent reported failure"
        case .stale: return "The last active update is too old to trust"
        case .blocked: return "A reported agent or task cannot continue"
        case .completed: return "Reported work finished"
        case .idle: return manager.isActivityEnabled ? "Ready" : "Activity monitoring is off"
        case .working:
            let sessions = active > 0 ? "\(active) active session\(active == 1 ? "" : "s")" : "Checkpoint active"
            let agents = max(lifecycleAgents, checkpointAgents)
            return sessions + (agents > 0 ? " · \(agents) agent\(agents == 1 ? "" : "s")" : "")
        }
    }

    private var headerIcon: String {
        switch presentationState {
        case .approvalRequired: "exclamationmark.shield.fill"
        case .failed: "xmark.circle.fill"
        case .stale: "clock.badge.exclamationmark.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .working: "waveform.path"
        case .completed: "checkmark.circle.fill"
        case .idle: "terminal"
        }
    }

    private var headerColor: Color {
        switch presentationState {
        case .approvalRequired: .orange
        case .blocked, .stale: .orange
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }
}
