import Foundation

enum CodexLifecycleTests {
    static func run() throws {
        try transcriptEventsRemainLocalAndSubagentsUseParentIdentity()
        try ledgerRoundTripPrunesTerminalAndStaleSessions()
    }

    private static func transcriptEventsRemainLocalAndSubagentsUseParentIdentity() throws {
        var accumulator = CodexTranscriptAccumulator()
        _ = accumulator.consume(line: Data(#"{"type":"session_meta","payload":{"id":"child","cwd":"/tmp/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_role":"worker"}}}}}"#.utf8))
        _ = accumulator.consume(line: Data(#"{"type":"turn_context","payload":{"turn_id":"turn","cwd":"/tmp/project","model":"gpt-5.6"}}"#.utf8))
        let observed = try value(accumulator.consume(line: Data(#"{"type":"event_msg","timestamp":"2026-08-30T22:00:00.000Z","payload":{"type":"task_started"}}"#.utf8)))
        let event = try value(observed.activityEvent(sequence: 7))
        try expect(event.origin == .localObservation)
        try expect(event.sessionID == "parent")
        try expect(event.turnID == "turn")
        try expect(event.sequence == 7)
        guard case let .subagentStarted(agentID) = event.kind else {
            throw Failure(message: "expected subagent start")
        }
        try expect(agentID == "child")
    }

    private static func ledgerRoundTripPrunesTerminalAndStaleSessions() throws {
        let home = URL(fileURLWithPath: "/tmp/bnl-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try CodexLifecycleLedger.markWorking(
            sessionID: "stale",
            turnID: nil,
            workingDirectory: "/tmp/old",
            model: nil,
            updatedAt: now.addingTimeInterval(-CodexLifecycleLedger.staleInterval - 1),
            homeDirectory: home
        )
        try CodexLifecycleLedger.markWorking(
            sessionID: "active",
            turnID: "turn",
            workingDirectory: "/tmp/project",
            model: "gpt-5.6",
            updatedAt: now,
            homeDirectory: home
        )
        try expect(CodexLifecycleLedger.load(homeDirectory: home, now: now).map(\.sessionID) == ["active"])
        try CodexLifecycleLedger.remove(sessionID: "active", now: now, homeDirectory: home)
        try expect(CodexLifecycleLedger.load(homeDirectory: home, now: now).isEmpty)
    }

    private static func value<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "missing fixture value") }
        return value
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard condition() else { throw Failure(message: "failed at \(file):\(line)") }
    }

    private struct Failure: Error {
        let message: String
    }
}
