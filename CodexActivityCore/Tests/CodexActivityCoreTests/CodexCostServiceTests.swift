import Foundation

enum CodexCostServiceTests {
    static func run() async throws {
        try await localEstimateUsesTokenCountersWithoutRetainingContent()
        try resetForecastParsingClampsAndAttributesSource()
    }

    private static func localEstimateUsesTokenCountersWithoutRetainingContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boring-cost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secret = "PRIVATE-PROMPT-DO-NOT-RETAIN"
        let rollout = """
        {"type":"session_meta","timestamp":"2026-07-20T00:01:00Z","payload":{"id":"cost-test"}}
        {"type":"response_item","timestamp":"2026-07-20T00:01:30Z","payload":{"type":"message","content":"\(secret)"}}
        {"type":"turn_context","timestamp":"2026-07-20T00:02:00Z","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","timestamp":"2026-07-20T00:10:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}
        """
        try Data((rollout + "\n").utf8).write(
            to: root.appendingPathComponent("cost-test.jsonl"),
            options: .atomic
        )
        let service = LocalCodexCostService(
            roots: [root],
            now: { Date(timeIntervalSince1970: 1_784_509_000) },
            priorityTierReader: nil,
            parserPricingFingerprint: { "test-v1" }
        )
        let estimate = try await service.estimate(
            interval: DateInterval(
                start: Date(timeIntervalSince1970: 1_784_505_600),
                end: Date(timeIntervalSince1970: 1_784_509_200)
            )
        )
        try expect(estimate.measurement.amount == Decimal(string: "0.5"))
        try expect(estimate.pricedTokenCount == 100_000)
        try expect(!String(reflecting: estimate).contains(secret))
        try expect(!String(reflecting: service).contains(secret))
    }

    private static func resetForecastParsingClampsAndAttributesSource() throws {
        let data = Data(
            #"{"fetchedAt":"2026-08-30T12:00:00Z","nextRefreshAt":"2026-08-30T13:00:00Z","forecast":{"score":140,"resetAnnounced":false}}"#.utf8
        )
        let forecast = try ResetForecastService.parseResponse(data)
        try expect(forecast.score == 100)
        try expect(forecast.scoreLabel == "100% in the next 48 hours")
        try expect(ResetForecast.sourceURL.host == "www.willcodexquotareset.com")
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
