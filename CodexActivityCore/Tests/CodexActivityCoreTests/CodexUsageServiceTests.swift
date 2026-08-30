import Foundation

enum CodexUsageServiceTests {
    static func run() throws {
        try parsesOfficialRateLimitWindowsAndClampsValues()
        try rejectsMissingRateLimitPayload()
    }

    private static func parsesOfficialRateLimitWindowsAndClampsValues() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = Data(
            """
            {"id":0,"result":{}}
            {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","planType":"plus","primary":{"usedPercent":27.4,"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":102,"windowDurationMins":10080,"resetsAt":1800604800}}}}}
            """.utf8
        )
        let snapshot = try CodexUsageService.parseResponse(payload, fetchedAt: fetchedAt)
        try expect(snapshot.planType == "plus")
        try expect(snapshot.limits.map(\.name) == ["5-hour window", "Weekly window"])
        try expect(snapshot.limits.map(\.usedPercent) == [27.4, 100])
        try expect(snapshot.limits[0].remainingPercent == 72.6)
        try expect(snapshot.fetchedAt == fetchedAt)
    }

    private static func rejectsMissingRateLimitPayload() throws {
        do {
            _ = try CodexUsageService.parseResponse(Data(#"{"id":2,"result":{}}"#.utf8))
            throw TestFailure(message: "missing limits were accepted")
        } catch CodexUsageServiceError.unavailable {
            return
        }
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

    private struct TestFailure: Error {
        let message: String
    }
}
