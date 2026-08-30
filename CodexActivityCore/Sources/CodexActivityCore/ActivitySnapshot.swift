// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable {
        case connected
        case stale
        case disconnected
    }

    public struct Activity: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case approvalRequired
            case failed
            case working
            case completed
        }

        public let id: String
        public let projectName: String
        public let state: State
        public let subagentCount: Int
        public let updatedAt: Date

        public init(
            id: String,
            projectName: String,
            state: State,
            subagentCount: Int,
            updatedAt: Date
        ) {
            self.id = id
            self.projectName = projectName
            self.state = state
            self.subagentCount = subagentCount
            self.updatedAt = updatedAt
        }
    }

    public struct Approval: Codable, Equatable, Sendable {
        public let id: UUID
        public let activityID: String
        public let requestedAt: Date
        public let expiresAt: Date

        public init(id: UUID, activityID: String, requestedAt: Date, expiresAt: Date) {
            self.id = id
            self.activityID = activityID
            self.requestedAt = requestedAt
            self.expiresAt = expiresAt
        }
    }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let availability: Availability
    public let activities: [Activity]
    public let pendingApproval: Approval?

    public init(
        schemaVersion: Int = ActivitySnapshot.currentSchemaVersion,
        generatedAt: Date,
        availability: Availability,
        activities: [Activity],
        pendingApproval: Approval?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.availability = availability
        self.activities = activities
        self.pendingApproval = pendingApproval
    }
}
