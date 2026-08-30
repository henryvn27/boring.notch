// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

struct CodexUsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
    let windowDurationMinutes: Int?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    func pace(at now: Date = Date()) -> CodexUsagePace? {
        guard let resetsAt, let windowDurationMinutes, windowDurationMinutes > 0 else { return nil }
        let duration = TimeInterval(windowDurationMinutes * 60)
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 60, elapsed < duration else { return nil }
        let expectedUsed = elapsed / duration * 100
        if usedPercent <= max(0, expectedUsed - 10) { return .belowPace }
        let projectedExhaustion = start.addingTimeInterval(elapsed * 100 / max(usedPercent, 0.1))
        if projectedExhaustion >= resetsAt || usedPercent <= expectedUsed + 10 { return .onPace }
        return .mayExhaustBeforeReset
    }
}

enum CodexUsagePace: Equatable, Sendable {
    case belowPace
    case onPace
    case mayExhaustBeforeReset

    var label: String {
        switch self {
        case .belowPace: "Below quota pace"
        case .onPace: "On pace through reset"
        case .mayExhaustBeforeReset: "May run out before reset"
        }
    }
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let limits: [CodexUsageLimit]
    let planType: String?
    let fetchedAt: Date

    var primaryLimit: CodexUsageLimit? { limits.first }
}
