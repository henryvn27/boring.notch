import Darwin
import Foundation

enum CodexAgentProgressError: LocalizedError, Equatable {
    case unavailable
    case insecureFile
    case oversized
    case malformed
    case unsupportedVersion
    case invalidField(String)
    case futureTimestamp
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: "No Codex progress checkpoint is available."
        case .insecureFile: "The Codex progress file is not an owner-only regular file."
        case .oversized: "The Codex progress file exceeds 64 KB."
        case .malformed: "The Codex progress file is unreadable."
        case .unsupportedVersion: "The Codex progress file uses an unsupported schema."
        case .invalidField(let field): "The Codex progress file has an invalid \(field)."
        case .futureTimestamp: "The Codex progress timestamp is too far in the future."
        case .writeFailed(let code): "The Codex progress file could not be saved (errno \(code))."
        }
    }
}

enum CodexAgentWorkState: String, Codable, Sendable {
    case planning
    case working
    case blocked
    case completed
    case failed
}

enum CodexMilestoneState: String, Codable, Sendable {
    case pending
    case working
    case blocked
    case verified
}

struct CodexAgentProgressSnapshot: Equatable, Sendable {
    struct Agent: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let state: CodexAgentWorkState
        let phase: String
    }

    let taskID: String
    let title: String
    let state: CodexAgentWorkState
    let phase: String
    let planRevision: Int
    let planLocked: Bool
    let verifiedMilestones: Int
    let totalMilestones: Int
    let agents: [Agent]
    let updatedAt: Date
    let isStale: Bool

    var checkpointFraction: Double? {
        guard planLocked, totalMilestones >= 2, !isStale else { return nil }
        return Double(verifiedMilestones) / Double(totalMilestones)
    }

    var checkpointLabel: String {
        guard planLocked, totalMilestones > 0 else { return "Plan is still changing" }
        return "\(verifiedMilestones) of \(totalMilestones) checkpoints verified"
    }
}

struct CodexAgentProgressStore: Sendable {
    static let schemaVersion = 1
    static let maximumDocumentSize = 65_536
    static let staleInterval: TimeInterval = 5 * 60
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    let fileURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        fileURL = homeDirectory.appendingPathComponent(
            "Library/Application Support/BoringNotch/agent-progress.json"
        )
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(now: Date = Date()) throws -> CodexAgentProgressSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try readPrivateFile()
        let snapshot = try Self.decode(data, now: now)
        guard now.timeIntervalSince(snapshot.updatedAt) <= Self.retentionInterval else { return nil }
        return snapshot
    }

    func write(_ data: Data, now: Date = Date()) throws {
        _ = try Self.decode(data, now: now)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, 0o700) == 0 else {
            throw CodexAgentProgressError.writeFailed(errno)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try validatePrivateFile(at: fileURL)
        }
        let temporaryURL = directory.appendingPathComponent(".agent-progress-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [])
            guard chmod(temporaryURL.path, 0o600) == 0 else {
                throw CodexAgentProgressError.writeFailed(errno)
            }
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw CodexAgentProgressError.writeFailed(errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try validatePrivateFile(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> CodexAgentProgressSnapshot {
        guard data.count <= maximumDocumentSize else { throw CodexAgentProgressError.oversized }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAgentProgressError.malformed
        }
        try rejectSensitiveOrPercentageFields(raw)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            throw CodexAgentProgressError.malformed
        }
        guard document.schemaVersion == schemaVersion else {
            throw CodexAgentProgressError.unsupportedVersion
        }
        try validate(document.taskID, field: "task ID", limit: 128)
        try validate(document.title, field: "title", limit: 160)
        try validate(document.phase, field: "phase", limit: 120)
        guard (1...10_000).contains(document.planRevision) else {
            throw CodexAgentProgressError.invalidField("plan revision")
        }
        guard document.milestones.count <= 50 else {
            throw CodexAgentProgressError.invalidField("milestones")
        }
        var milestoneIDs = Set<String>()
        var verified = 0
        for milestone in document.milestones {
            try validate(milestone.id, field: "milestone ID", limit: 80)
            try validate(milestone.title, field: "milestone title", limit: 160)
            guard milestoneIDs.insert(milestone.id).inserted else {
                throw CodexAgentProgressError.invalidField("milestone ID")
            }
            if milestone.state == .verified {
                guard let evidence = milestone.evidence else {
                    throw CodexAgentProgressError.invalidField("verified milestone evidence")
                }
                try validate(evidence, field: "verified milestone evidence", limit: 200)
                verified += 1
            }
        }
        guard document.agents.count <= 20 else {
            throw CodexAgentProgressError.invalidField("agents")
        }
        var agentIDs = Set<String>()
        let agents = try document.agents.map { agent -> CodexAgentProgressSnapshot.Agent in
            try validate(agent.id, field: "agent ID", limit: 80)
            try validate(agent.title, field: "agent title", limit: 120)
            try validate(agent.phase, field: "agent phase", limit: 120)
            guard agentIDs.insert(agent.id).inserted else {
                throw CodexAgentProgressError.invalidField("agent ID")
            }
            return .init(id: agent.id, title: agent.title, state: agent.state, phase: agent.phase)
        }
        guard document.updatedAt <= now.addingTimeInterval(5 * 60) else {
            throw CodexAgentProgressError.futureTimestamp
        }
        let active = document.state == .planning || document.state == .working || document.state == .blocked
        return CodexAgentProgressSnapshot(
            taskID: document.taskID,
            title: document.title,
            state: document.state,
            phase: document.phase,
            planRevision: document.planRevision,
            planLocked: document.planLocked,
            verifiedMilestones: verified,
            totalMilestones: document.milestones.count,
            agents: agents,
            updatedAt: document.updatedAt,
            isStale: active && now.timeIntervalSince(document.updatedAt) > staleInterval
        )
    }

    private func readPrivateFile() throws -> Data {
        try validatePrivateFile(at: fileURL)
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CodexAgentProgressError.insecureFile }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0,
              status.st_size <= Self.maximumDocumentSize
        else { throw CodexAgentProgressError.insecureFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= Self.maximumDocumentSize else { throw CodexAgentProgressError.oversized }
        return data
    }

    private func validatePrivateFile(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0
        else { throw CodexAgentProgressError.insecureFile }
    }

    private static func validate(_ value: String, field: String, limit: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CodexAgentProgressError.invalidField(field) }
    }

    private static func rejectSensitiveOrPercentageFields(_ object: Any) throws {
        let forbidden = Set(["percent", "percentage", "progress", "prompt", "toolinput", "operation"])
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if forbidden.contains(key.lowercased()) {
                    throw CodexAgentProgressError.invalidField(key)
                }
                try rejectSensitiveOrPercentageFields(value)
            }
        } else if let array = object as? [Any] {
            for value in array { try rejectSensitiveOrPercentageFields(value) }
        }
    }
}

private struct Document: Decodable {
    let schemaVersion: Int
    let taskID: String
    let title: String
    let state: CodexAgentWorkState
    let phase: String
    let planRevision: Int
    let planLocked: Bool
    let milestones: [Milestone]
    let agents: [Agent]
    let updatedAt: Date

    struct Milestone: Decodable {
        let id: String
        let title: String
        let state: CodexMilestoneState
        let evidence: String?
    }

    struct Agent: Decodable {
        let id: String
        let title: String
        let state: CodexAgentWorkState
        let phase: String
    }
}
