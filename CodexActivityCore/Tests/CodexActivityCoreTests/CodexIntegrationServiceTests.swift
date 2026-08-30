import Foundation

enum CodexIntegrationServiceTests {
    private static let cwd = "/Users/test/Project"
    private static let command = "'/Users/test/.local/bin/boring-notch-hook' hook"
    private static let events = [
        "sessionStart", "userPromptSubmit", "permissionRequest",
        "subagentStart", "subagentStop", "stop",
    ]

    static func run() throws {
        try parsesTrustedHooks()
        try requiresReviewForModifiedHook()
        try reportsIncompleteHookSet()
        try boundsSelfTestResponses()
    }

    private static func parsesTrustedHooks() throws {
        let report = try CodexHookTrustService.parseResponse(
            response(statuses: Dictionary(uniqueKeysWithValues: events.map { ($0, "trusted") })),
            workingDirectory: cwd,
            expectedCommand: command
        )
        try expect(report.state == .trusted)
        try expect(report.eventStatuses.count == events.count)
    }

    private static func requiresReviewForModifiedHook() throws {
        var statuses = Dictionary(uniqueKeysWithValues: events.map { ($0, "managed") })
        statuses["permissionRequest"] = "modified"
        let report = try CodexHookTrustService.parseResponse(
            response(statuses: statuses),
            workingDirectory: cwd,
            expectedCommand: command
        )
        try expect(report.state == .needsReview)
    }

    private static func reportsIncompleteHookSet() throws {
        let report = try CodexHookTrustService.parseResponse(
            response(statuses: ["sessionStart": "trusted"]),
            workingDirectory: cwd,
            expectedCommand: command
        )
        try expect(report.state == .incomplete)
    }

    private static func boundsSelfTestResponses() throws {
        let decoded = try IntegrationSelfTestService.decodeObject(Data(#"{"ok":true}"#.utf8))
        try expect(decoded["ok"] as? Bool == true)
        do {
            _ = try IntegrationSelfTestService.decodeObject(
                Data(repeating: 0x20, count: IntegrationSelfTestService.maximumResponseSize + 1)
            )
            throw TestFailure(message: "oversized response was accepted")
        } catch IntegrationSelfTestError.responseTooLarge {
            return
        }
    }

    private static func response(statuses: [String: String]) -> Data {
        let hooks = statuses.keys.sorted().map { event -> [String: Any] in
            [
                "eventName": event,
                "command": command,
                "enabled": true,
                "trustStatus": statuses[event]!,
            ]
        }
        let object: [String: Any] = [
            "id": 2,
            "result": ["data": [["cwd": cwd, "hooks": hooks]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard condition() else { throw TestFailure(message: "failed at \(file):\(line)") }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
