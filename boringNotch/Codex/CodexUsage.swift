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
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let limits: [CodexUsageLimit]
    let planType: String?
    let fetchedAt: Date

    var primaryLimit: CodexUsageLimit? { limits.first }
}
