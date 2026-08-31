import Foundation

enum CodexAgentProgressStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func run() throws {
        try computesOneAggregateFromVerifiedMilestones()
        try hidesNumericProgressForChangingPlans()
        try rejectsUnknownRootAndNestedFields()
        try marksRootOrActiveAgentStale()
        try rejectsFalseCompletion()
        try representsVerifiedCompletionWithoutAPercentageBar()
        try requiresRevisionAndUnlockedPublicationForPlanChanges()
        try writesOwnerPrivateFileAtomically()
        try rejectsSymlinkedProgressFile()
    }

    private static func computesOneAggregateFromVerifiedMilestones() throws {
        let snapshot = try CodexAgentProgressStore.decode(document(), now: now)
        try expect(snapshot.checkpointFraction == 2.0 / 3.0)
        try expect(snapshot.checkpointLabel == "2 of 3 checkpoints verified")
        try expect(snapshot.latestVerifiedMilestone?.evidence == "Rendered locally")
        try expect(snapshot.agents.count == 2)
        try expect(snapshot.agents[0].state == .working)
        try expect(snapshot.agents[0].phase == "Verify macOS builds")
        try expect(!snapshot.agents[0].isStale)
        try expect(snapshot.agents[1].state == .completed)
    }

    private static func hidesNumericProgressForChangingPlans() throws {
        let snapshot = try CodexAgentProgressStore.decode(
            document(planLocked: false),
            now: now
        )
        try expect(snapshot.checkpointFraction == nil)
        try expect(snapshot.checkpointLabel == "Plan changed · 3 required")
    }

    private static func rejectsUnknownRootAndNestedFields() throws {
        var root = try decodedObject(document())
        root["percentage"] = 73
        try expectInvalidField(root, field: "percentage")

        root = try decodedObject(document())
        var agents = root["agents"] as! [[String: Any]]
        agents[0]["tool_input"] = ["command": "cat ~/.ssh/id_rsa"]
        root["agents"] = agents
        try expectInvalidField(root, field: "tool_input")
    }

    private static func marksRootOrActiveAgentStale() throws {
        let staleDate = now.addingTimeInterval(-CodexAgentProgressStore.staleInterval - 1)
        let rootStale = try CodexAgentProgressStore.decode(
            document(updatedAt: staleDate),
            now: now
        )
        try expect(rootStale.isStale)
        try expect(rootStale.checkpointFraction == nil)

        let agentStale = try CodexAgentProgressStore.decode(
            document(agentUpdatedAt: staleDate),
            now: now
        )
        try expect(agentStale.isStale)
        try expect(agentStale.agents[0].isStale)
        try expect(agentStale.checkpointFraction == nil)
    }

    private static func rejectsFalseCompletion() throws {
        var object = try decodedObject(document())
        object["state"] = "completed"
        do {
            _ = try CodexAgentProgressStore.decode(try encoded(object), now: now)
            throw TestFailure(message: "false completion was accepted")
        } catch CodexAgentProgressError.invalidField("completed task state") {
            return
        }
    }

    private static func representsVerifiedCompletionWithoutAPercentageBar() throws {
        var object = try decodedObject(document())
        object["state"] = "completed"
        var milestones = object["milestones"] as! [[String: Any]]
        milestones[2]["state"] = "verified"
        milestones[2]["evidence"] = "PR checks passed"
        milestones[2]["evidenceAt"] = iso(now)
        object["milestones"] = milestones
        var agents = object["agents"] as! [[String: Any]]
        for index in agents.indices { agents[index]["state"] = "completed" }
        object["agents"] = agents

        let snapshot = try CodexAgentProgressStore.decode(try encoded(object), now: now)
        try expect(snapshot.isComplete)
        try expect(snapshot.checkpointFraction == nil)
        try expect(snapshot.checkpointLabel == "3 checks verified")

        object["state"] = "working"
        agents[0]["state"] = "working"
        object["agents"] = agents
        let finishing = try CodexAgentProgressStore.decode(try encoded(object), now: now)
        try expect(!finishing.isComplete)
        try expect(finishing.checkpointFraction == nil)
        try expect(finishing.checkpointLabel == "3 checks verified · finishing")
    }

    private static func requiresRevisionAndUnlockedPublicationForPlanChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boring-notch-progress-transition-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexAgentProgressStore(fileURL: root.appendingPathComponent("progress.json"))
        try store.write(document(), now: now)

        var changed = try decodedObject(document())
        var milestones = changed["milestones"] as! [[String: Any]]
        milestones.append(["id": "ship", "title": "Ship", "state": "pending"])
        changed["milestones"] = milestones
        try expectWriteFailure(store, object: changed, field: "plan revision")

        changed["planRevision"] = 4
        try expectWriteFailure(store, object: changed, field: "plan lock")

        changed["planLocked"] = false
        try store.write(try encoded(changed), now: now)
        changed["planLocked"] = true
        try store.write(try encoded(changed), now: now)

        var older = changed
        older["updatedAt"] = iso(now.addingTimeInterval(-1))
        var olderAgents = older["agents"] as! [[String: Any]]
        for index in olderAgents.indices {
            olderAgents[index]["updatedAt"] = iso(now.addingTimeInterval(-1))
        }
        older["agents"] = olderAgents
        var olderMilestones = older["milestones"] as! [[String: Any]]
        olderMilestones[0]["evidenceAt"] = iso(now.addingTimeInterval(-2))
        olderMilestones[1]["evidenceAt"] = iso(now.addingTimeInterval(-1))
        older["milestones"] = olderMilestones
        try expectWriteFailure(store, object: older, field: "timestamp")

        var rollback = changed
        milestones = rollback["milestones"] as! [[String: Any]]
        milestones[0]["state"] = "pending"
        milestones[0].removeValue(forKey: "evidence")
        milestones[0].removeValue(forKey: "evidenceAt")
        rollback["milestones"] = milestones
        rollback["planRevision"] = 5
        try expectWriteFailure(store, object: rollback, field: "plan lock")
    }

    private static func writesOwnerPrivateFileAtomically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boring-notch-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("progress.json")
        let store = CodexAgentProgressStore(fileURL: file)
        try store.write(document(), now: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try expect(try store.load(now: now)?.verifiedMilestones == 2)
        try store.clear()
        try expect(!FileManager.default.fileExists(atPath: file.path))
    }

    private static func rejectsSymlinkedProgressFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boring-notch-progress-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.json")
        try document().write(to: target)
        let link = root.appendingPathComponent("progress.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try CodexAgentProgressStore(fileURL: link).load(now: now)
            throw TestFailure(message: "symlinked progress file was accepted")
        } catch CodexAgentProgressError.insecureFile {
            return
        }
    }

    private static func document(
        planLocked: Bool = true,
        planRevision: Int = 3,
        updatedAt: Date = now,
        agentUpdatedAt: Date? = nil
    ) -> Data {
        let agentDate = agentUpdatedAt ?? updatedAt
        let object: [String: Any] = [
            "schemaVersion": 2,
            "taskID": "CS-2144",
            "title": "Finish Codex integration",
            "state": "working",
            "phase": "Verify macOS builds",
            "planRevision": planRevision,
            "planLocked": planLocked,
            "milestones": [
                [
                    "id": "transport", "title": "Transport", "state": "verified",
                    "evidence": "Tests passed",
                    "evidenceAt": iso(updatedAt.addingTimeInterval(-1)),
                ],
                [
                    "id": "ui", "title": "Notch UI", "state": "verified",
                    "evidence": "Rendered locally", "evidenceAt": iso(updatedAt),
                ],
                ["id": "release", "title": "Public PR", "state": "working"],
            ],
            "agents": [
                [
                    "id": "root", "title": "Primary agent", "state": "working",
                    "phase": "Verify macOS builds", "updatedAt": iso(agentDate),
                ],
                [
                    "id": "review", "title": "Review agent", "state": "completed",
                    "phase": "Review complete", "updatedAt": iso(updatedAt),
                ],
            ],
            "updatedAt": iso(updatedAt),
        ]
        return (try? encoded(object)) ?? Data()
    }

    private static func expectInvalidField(_ object: [String: Any], field: String) throws {
        do {
            _ = try CodexAgentProgressStore.decode(try encoded(object), now: now)
            throw TestFailure(message: "unknown field \(field) was accepted")
        } catch CodexAgentProgressError.invalidField(let actual) where actual == field {
            return
        }
    }

    private static func expectWriteFailure(
        _ store: CodexAgentProgressStore,
        object: [String: Any],
        field: String
    ) throws {
        do {
            try store.write(try encoded(object), now: now)
            throw TestFailure(message: "invalid \(field) transition was accepted")
        } catch CodexAgentProgressError.invalidField(let actual) where actual == field {
            return
        }
    }

    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func decodedObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "test fixture is invalid")
        }
        return object
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard try condition() else { throw TestFailure(message: "failed at \(file):\(line)") }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
