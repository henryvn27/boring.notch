import Foundation

enum CodexAgentProgressStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func run() throws {
        try computesOneAggregateFromVerifiedMilestones()
        try hidesNumericProgressForChangingPlans()
        try rejectsWriterSuppliedPercentages()
        try marksActiveCheckpointsStale()
        try writesOwnerPrivateFileAtomically()
        try rejectsSymlinkedProgressFile()
    }

    private static func computesOneAggregateFromVerifiedMilestones() throws {
        let snapshot = try CodexAgentProgressStore.decode(document(), now: now)
        try expect(snapshot.checkpointFraction == 2.0 / 3.0)
        try expect(snapshot.checkpointLabel == "2 of 3 checkpoints verified")
        try expect(snapshot.agents.count == 2)
    }

    private static func hidesNumericProgressForChangingPlans() throws {
        let snapshot = try CodexAgentProgressStore.decode(
            document(planLocked: false),
            now: now
        )
        try expect(snapshot.checkpointFraction == nil)
        try expect(snapshot.checkpointLabel == "Plan is still changing")
    }

    private static func rejectsWriterSuppliedPercentages() throws {
        var object = try decodedObject(document())
        object["percentage"] = 73
        do {
            _ = try CodexAgentProgressStore.decode(try JSONSerialization.data(withJSONObject: object), now: now)
            throw TestFailure(message: "writer-supplied percentage was accepted")
        } catch CodexAgentProgressError.invalidField("percentage") {
            return
        }
    }

    private static func marksActiveCheckpointsStale() throws {
        let snapshot = try CodexAgentProgressStore.decode(
            document(updatedAt: now.addingTimeInterval(-CodexAgentProgressStore.staleInterval - 1)),
            now: now
        )
        try expect(snapshot.isStale)
        try expect(snapshot.checkpointFraction == nil)
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
        updatedAt: Date = now
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = [
            "schemaVersion": 1,
            "taskID": "CS-2144",
            "title": "Finish Codex integration",
            "state": "working",
            "phase": "Verify macOS builds",
            "planRevision": 3,
            "planLocked": planLocked,
            "milestones": [
                ["id": "transport", "title": "Transport", "state": "verified", "evidence": "Tests passed"],
                ["id": "ui", "title": "Notch UI", "state": "verified", "evidence": "Rendered locally"],
                ["id": "release", "title": "Public PR", "state": "working"],
            ],
            "agents": [
                ["id": "root", "title": "Primary agent", "state": "working", "phase": "Verify macOS builds"],
                ["id": "review", "title": "Review agent", "state": "completed", "phase": "Review complete"],
            ],
            "updatedAt": formatter.string(from: updatedAt),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func decodedObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "test fixture is invalid")
        }
        return object
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
