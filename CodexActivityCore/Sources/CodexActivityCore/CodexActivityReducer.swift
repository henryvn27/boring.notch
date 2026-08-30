// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

public struct CodexActivityEvent: Equatable, Sendable {
    public enum Origin: Int, Hashable, Sendable {
        case localObservation
        case trustedHook
    }

    public enum Kind: Equatable, Sendable {
        case sessionStarted
        case working
        case approvalRequested(id: UUID, expiresAt: Date)
        case subagentStarted(agentID: String)
        case subagentStopped(agentID: String)
        case completed
        case failed
    }

    public let origin: Origin
    public let sequence: Int
    public let timestamp: Date
    public let sessionID: String
    public let turnID: String?
    public let cwd: String
    public let kind: Kind

    public init(
        origin: Origin,
        sequence: Int,
        timestamp: Date,
        sessionID: String,
        turnID: String? = nil,
        cwd: String,
        kind: Kind
    ) {
        self.origin = origin
        self.sequence = sequence
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.kind = kind
    }
}

public struct CodexActivityReducer: Sendable {
    private struct Session: Sendable {
        var projectName: String
        var baseState: ActivitySnapshot.Activity.State
        var updatedAt: Date
        var authoritativeOrigin: CodexActivityEvent.Origin
        var sequences: [CodexActivityEvent.Origin: Int]
    }

    private struct Child: Hashable, Sendable {
        let sessionID: String
        let turnID: String
        let agentID: String
    }

    private let staleAfter: TimeInterval
    private var sessions: [String: Session] = [:]
    private var approvals: [UUID: ActivitySnapshot.Approval] = [:]
    private var seenApprovals: Set<UUID> = []
    private var activeChildren: Set<Child> = []
    private var childTombstones: Set<Child> = []
    private var lastAcceptedAt: Date?
    private var isDisconnected = true

    public init(staleAfter: TimeInterval = 30) {
        self.staleAfter = staleAfter
    }

    @discardableResult
    public mutating func receive(_ event: CodexActivityEvent, now: Date = Date()) -> Bool {
        guard !event.sessionID.isEmpty,
              event.timestamp >= now.addingTimeInterval(-15 * 60),
              event.timestamp <= now.addingTimeInterval(5 * 60)
        else { return false }

        if let session = sessions[event.sessionID] {
            guard event.sequence > (session.sequences[event.origin] ?? -1),
                  event.timestamp >= session.updatedAt,
                  session.authoritativeOrigin != .trustedHook || event.origin == .trustedHook
            else { return false }
        }

        if case let .approvalRequested(id, expiresAt) = event.kind {
            guard event.origin == .trustedHook,
                  expiresAt > now,
                  !seenApprovals.contains(id)
            else { return false }
        }

        if case .subagentStarted = event.kind, event.turnID == nil { return false }
        if case .subagentStopped = event.kind, event.turnID == nil { return false }

        var session = sessions[event.sessionID] ?? Session(
            projectName: Self.sanitizedProjectName(from: event.cwd),
            baseState: .working,
            updatedAt: event.timestamp,
            authoritativeOrigin: event.origin,
            sequences: [:]
        )

        session.projectName = Self.sanitizedProjectName(from: event.cwd)
        session.updatedAt = event.timestamp
        if event.origin.rawValue > session.authoritativeOrigin.rawValue {
            session.authoritativeOrigin = event.origin
        }
        session.sequences[event.origin] = event.sequence

        switch event.kind {
        case .sessionStarted, .working:
            session.baseState = .working
        case let .approvalRequested(id, expiresAt):
            let approval = ActivitySnapshot.Approval(
                id: id,
                activityID: event.sessionID,
                requestedAt: event.timestamp,
                expiresAt: expiresAt
            )
            approvals[id] = approval
            seenApprovals.insert(id)
        case let .subagentStarted(agentID):
            let child = Child(sessionID: event.sessionID, turnID: event.turnID!, agentID: agentID)
            guard !childTombstones.contains(child) else { return false }
            activeChildren.insert(child)
        case let .subagentStopped(agentID):
            let child = Child(sessionID: event.sessionID, turnID: event.turnID!, agentID: agentID)
            activeChildren.remove(child)
            childTombstones.insert(child)
        case .completed:
            session.baseState = .completed
            if let turnID = event.turnID {
                activeChildren = Set(activeChildren.filter {
                    $0.sessionID != event.sessionID || $0.turnID != turnID
                })
            }
            approvals = approvals.filter { $0.value.activityID != event.sessionID }
        case .failed:
            session.baseState = .failed
            if let turnID = event.turnID {
                activeChildren = Set(activeChildren.filter {
                    $0.sessionID != event.sessionID || $0.turnID != turnID
                })
            }
            approvals = approvals.filter { $0.value.activityID != event.sessionID }
        }

        sessions[event.sessionID] = session
        lastAcceptedAt = now
        isDisconnected = false
        return true
    }

    public mutating func disconnect(at date: Date = Date()) {
        sessions.removeAll()
        approvals.removeAll()
        activeChildren.removeAll()
        childTombstones.removeAll()
        lastAcceptedAt = date
        isDisconnected = true
    }

    public func snapshot(now: Date = Date()) -> ActivitySnapshot {
        guard !isDisconnected else {
            return ActivitySnapshot(
                generatedAt: now,
                availability: .disconnected,
                activities: [],
                pendingApproval: nil
            )
        }

        guard let lastAcceptedAt, now.timeIntervalSince(lastAcceptedAt) <= staleAfter else {
            return ActivitySnapshot(
                generatedAt: now,
                availability: .stale,
                activities: [],
                pendingApproval: nil
            )
        }

        let liveApprovals = approvals.values.filter { $0.expiresAt > now }
        let approvalActivityIDs = Set(liveApprovals.map(\.activityID))
        let activities = sessions.map { sessionID, session in
            ActivitySnapshot.Activity(
                id: sessionID,
                projectName: session.projectName,
                state: approvalActivityIDs.contains(sessionID) ? .approvalRequired : session.baseState,
                subagentCount: activeChildren.count { $0.sessionID == sessionID },
                updatedAt: session.updatedAt
            )
        }.sorted(by: Self.activityComesFirst)

        return ActivitySnapshot(
            generatedAt: now,
            availability: .connected,
            activities: activities,
            pendingApproval: liveApprovals.min {
                ($0.requestedAt, $0.id.uuidString) < ($1.requestedAt, $1.id.uuidString)
            }
        )
    }

    public static func sanitizedProjectName(from cwd: String) -> String {
        let component = URL(fileURLWithPath: cwd).lastPathComponent
        let clean = component.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(trimmed.unicodeScalars.prefix(80))
        return limited.isEmpty ? "Codex" : limited
    }

    private static func activityComesFirst(
        _ lhs: ActivitySnapshot.Activity,
        _ rhs: ActivitySnapshot.Activity
    ) -> Bool {
        let priority: [ActivitySnapshot.Activity.State: Int] = [
            .approvalRequired: 0,
            .failed: 1,
            .working: 2,
            .completed: 3,
        ]
        if priority[lhs.state] != priority[rhs.state] {
            return priority[lhs.state, default: .max] < priority[rhs.state, default: .max]
        }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}
