import Foundation

@main
struct CodexActivityReducerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() async throws {
        try orderingUsesStateRecencyThenStableSessionID()
        try onlyTrustedHooksCreateApprovalsAndDuplicateIDsAreRejected()
        try exactTurnChildTombstonesPreventDelayedResurrection()
        try staleAndDisconnectedSnapshotsExposeNoActivity()
        try serializedSnapshotIsAllowlistedAndStripsSensitivePathData()
        try rejectsReplayedOlderAndImplausiblyTimedEvents()
        try presentationStateUsesOneSafetyFirstPrecedence()
        try activityConsentRequiresAChoiceOrExistingInstallation()
        try CodexBridgeServerTests.run()
        try CodexHookInstallerTests.run()
        try CodexLifecycleTests.run()
        try CodexUsageServiceTests.run()
        try await CapsLockSignalServiceTests.run()
        try await CodexCostServiceTests.run()
        try await ProviderAccountTests.run()
        try CodexIntegrationServiceTests.run()
        try CodexAgentProgressStoreTests.run()
        print("CodexActivityCore: focused test suites passed")
    }

    private static func orderingUsesStateRecencyThenStableSessionID() throws {
        var reducer = CodexActivityReducer()
        try expect(reducer.receive(event(session: "z", sequence: 1, kind: .completed), now: now))
        try expect(reducer.receive(event(session: "b", sequence: 1, kind: .working), now: now))
        try expect(reducer.receive(event(session: "a", sequence: 1, kind: .working), now: now))
        try expect(reducer.receive(event(session: "f", sequence: 1, kind: .failed), now: now))
        try expect(reducer.snapshot(now: now).activities.map(\.id) == ["f", "a", "b", "z"])
    }

    private static func onlyTrustedHooksCreateApprovalsAndDuplicateIDsAreRejected() throws {
        let approvalID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var reducer = CodexActivityReducer()
        try expect(!reducer.receive(event(
            origin: .localObservation,
            session: "session",
            sequence: 1,
            kind: .approvalRequested(id: approvalID, expiresAt: now.addingTimeInterval(60))
        ), now: now))
        try expect(reducer.receive(event(
            session: "session",
            sequence: 1,
            kind: .approvalRequested(id: approvalID, expiresAt: now.addingTimeInterval(60))
        ), now: now))
        try expect(!reducer.receive(event(
            session: "session",
            sequence: 2,
            kind: .approvalRequested(id: approvalID, expiresAt: now.addingTimeInterval(120))
        ), now: now))
        try expect(!reducer.receive(event(
            origin: .localObservation,
            session: "session",
            sequence: 2,
            kind: .working
        ), now: now))
        try expect(reducer.receive(event(
            session: "later-session",
            sequence: 1,
            timestamp: now.addingTimeInterval(1),
            kind: .approvalRequested(
                id: UUID(uuidString: "FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                expiresAt: now.addingTimeInterval(120)
            )
        ), now: now))
        try expect(reducer.snapshot(now: now).pendingApproval?.id == approvalID)
        try expect(reducer.snapshot(now: now).activities.first?.state == .approvalRequired)
        try expect(reducer.resolveApproval(id: approvalID, now: now))
        try expect(reducer.snapshot(now: now).pendingApproval?.id != approvalID)
    }

    private static func exactTurnChildTombstonesPreventDelayedResurrection() throws {
        var reducer = CodexActivityReducer()
        try expect(reducer.receive(event(session: "s", turn: "one", sequence: 1, kind: .subagentStarted(agentID: "child")), now: now))
        try expect(reducer.receive(event(session: "s", turn: "one", sequence: 2, kind: .subagentStopped(agentID: "child")), now: now))
        try expect(!reducer.receive(event(session: "s", turn: "one", sequence: 3, kind: .subagentStarted(agentID: "child")), now: now))
        try expect(reducer.receive(event(session: "s", turn: "two", sequence: 4, kind: .subagentStarted(agentID: "child")), now: now))
        try expect(reducer.receive(event(session: "s", turn: "one", sequence: 5, kind: .completed), now: now))
        try expect(reducer.snapshot(now: now).activities.first?.subagentCount == 1)
    }

    private static func staleAndDisconnectedSnapshotsExposeNoActivity() throws {
        var reducer = CodexActivityReducer(staleAfter: 10)
        try expect(reducer.snapshot(now: now).availability == .disconnected)
        try expect(reducer.receive(event(session: "s", sequence: 1, kind: .working), now: now))
        try expect(reducer.snapshot(now: now).availability == .connected)
        try expect(reducer.snapshot(now: now.addingTimeInterval(11)).availability == .stale)
        try expect(reducer.snapshot(now: now.addingTimeInterval(11)).activities.isEmpty)
        reducer.disconnect(at: now.addingTimeInterval(12))
        try expect(reducer.snapshot(now: now.addingTimeInterval(12)).availability == .disconnected)
    }

    private static func serializedSnapshotIsAllowlistedAndStripsSensitivePathData() throws {
        var reducer = CodexActivityReducer()
        try expect(reducer.receive(event(
            session: "opaque-session",
            sequence: 1,
            cwd: "/Users/secret/Projects/Private\nProject",
            kind: .working
        ), now: now))
        let json = String(decoding: try JSONEncoder().encode(reducer.snapshot(now: now)), as: UTF8.self)
        try expect(json.contains("PrivateProject"))
        try expect(!json.contains("/Users/secret"))
        try expect(!json.contains("prompt"))
        try expect(!json.contains("percentage"))
        try expect(!json.contains("toolInput"))
    }

    private static func rejectsReplayedOlderAndImplausiblyTimedEvents() throws {
        var reducer = CodexActivityReducer()
        try expect(reducer.receive(event(session: "s", sequence: 2, kind: .working), now: now))
        try expect(!reducer.receive(event(session: "s", sequence: 2, kind: .failed), now: now))
        try expect(!reducer.receive(event(session: "s", sequence: 3, timestamp: now.addingTimeInterval(-1), kind: .failed), now: now))
        try expect(!reducer.receive(event(session: "old", sequence: 1, timestamp: now.addingTimeInterval(-901), kind: .working), now: now))
        try expect(!reducer.receive(event(session: "future", sequence: 1, timestamp: now.addingTimeInterval(301), kind: .working), now: now))
    }

    private static func presentationStateUsesOneSafetyFirstPrecedence() throws {
        let completedActivity = ActivitySnapshot(
            generatedAt: now,
            availability: .connected,
            activities: [
                .init(
                    id: "session", projectName: "Project", state: .completed,
                    subagentCount: 0, updatedAt: now
                ),
            ],
            pendingApproval: nil
        )
        let working = progress(state: .working)
        try expect(CodexActivityPresentation.resolve(
            activity: completedActivity, progress: working, hasApproval: false
        ) == .working)

        let approvalActivity = ActivitySnapshot(
            generatedAt: now,
            availability: .connected,
            activities: [
                .init(
                    id: "session", projectName: "Project", state: .approvalRequired,
                    subagentCount: 0, updatedAt: now
                ),
            ],
            pendingApproval: nil
        )
        try expect(CodexActivityPresentation.resolve(
            activity: approvalActivity, progress: working, hasApproval: false
        ) == .approvalRequired)

        let idle = ActivitySnapshot(
            generatedAt: now, availability: .connected, activities: [], pendingApproval: nil
        )
        try expect(CodexActivityPresentation.resolve(
            activity: idle, progress: progress(state: .failed), hasApproval: false
        ) == .failed)
        try expect(CodexActivityPresentation.resolve(
            activity: idle, progress: progress(state: .blocked), hasApproval: false
        ) == .blocked)
    }

    private static func activityConsentRequiresAChoiceOrExistingInstallation() throws {
        try expect(!CodexActivityConsentPolicy.resolved(
            explicitValue: nil, integrationInstalled: false
        ))
        try expect(CodexActivityConsentPolicy.resolved(
            explicitValue: nil, integrationInstalled: true
        ))
        try expect(!CodexActivityConsentPolicy.resolved(
            explicitValue: false, integrationInstalled: true
        ))
        try expect(CodexActivityConsentPolicy.resolved(
            explicitValue: true, integrationInstalled: false
        ))
    }

    private static func progress(state: CodexAgentWorkState) -> CodexAgentProgressSnapshot {
        CodexAgentProgressSnapshot(
            taskID: "task",
            title: "Task",
            state: state,
            phase: "Working",
            planRevision: 1,
            planLocked: true,
            verifiedMilestones: 1,
            totalMilestones: 2,
            milestones: [
                .init(
                    id: "one", title: "One", state: .verified,
                    evidence: "Test passed", evidenceAt: now
                ),
                .init(id: "two", title: "Two", state: .working, evidence: nil, evidenceAt: nil),
            ],
            agents: [],
            updatedAt: now,
            isStale: false
        )
    }

    private static func event(
        origin: CodexActivityEvent.Origin = .trustedHook,
        session: String,
        turn: String? = nil,
        sequence: Int,
        timestamp: Date? = nil,
        cwd: String = "/Users/henry/Developer/Codex",
        kind: CodexActivityEvent.Kind
    ) -> CodexActivityEvent {
        CodexActivityEvent(
            origin: origin,
            sequence: sequence,
            timestamp: timestamp ?? now,
            sessionID: session,
            turnID: turn,
            cwd: cwd,
            kind: kind
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard condition() else {
            throw TestFailure(message: "failed at \(file):\(line)")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
