// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

enum CostMeasurementKind: String, Codable, Sendable {
    case actualBilled
    case apiEquivalentEstimate
}

enum CostCoverage: String, Codable, Sendable {
    case accountWide
    case thisMac
    case partial
}

struct CostMeasurement: Equatable, Codable, Sendable {
    let kind: CostMeasurementKind
    let amount: Decimal
    let currency: String
    let interval: DateInterval
    let coverage: CostCoverage
    let pricingAsOf: Date?
}

protocol LocalCodexCostEstimating: Sendable {
    func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate
    func resetCache() async
}

enum LocalCodexCostExclusionReason: String, CaseIterable, Equatable, Sendable {
    case unknownModel
    case malformedRecord
    case oversizedRecord
    case incompleteFinalRecord
    case missingRolloutIdentifier
    case unresolvedLineage
    case counterDiscontinuity
    case inconsistentTokenCounters
    case ambiguousLongContextPricing
    case priorityMetadataUnavailable
    case missingTurnIdentifier
    case ambiguousPriorityPricing
    case invalidTokenPartition
    case fileChangedDuringScan
    case duplicateRollout
    case forkLineageUncertainty
}

struct LocalCodexCostScanMetrics: Equatable, Sendable {
    var bytesRead = 0
    var completeRecordCount = 0
    var decodedRecordCount = 0
    var decodedRecordBytes = 0
    var peakRetainedRecordBytes = 0
    var recordBufferAppendCount = 0
    var fullyReadFileCount = 0
    var incrementallyReadFileCount = 0
    var reusedFileCount = 0
    var skippedHistoricalFileCount = 0
    var invalidatedFileCount = 0
}

struct LocalCodexCostEstimate: Equatable, Sendable {
    let measurement: CostMeasurement
    let pricedTokenCount: Int
    let unpricedTokenCount: Int
    let excludedToolFees: Bool
    let exclusionReasons: [LocalCodexCostExclusionReason]
    let scannedFileCount: Int
    let refreshedAt: Date
}

enum APICostWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case last30Days
    case monthToDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .last30Days: "Last 30 days"
        case .monthToDate: "Month to date"
        }
    }

    func interval(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
        case .last30Days:
            let today = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .monthToDate:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        }
        return DateInterval(start: start, end: max(now, start.addingTimeInterval(0.001)))
    }
}
