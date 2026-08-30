// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Darwin
import Foundation

enum CodexJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    func prettyPrinted() -> String {
        let encoder = JSONEncoder.codexBridge
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum CodexBridgeEventName: String, Codable, Sendable {
    case sessionStart
    case working
    case approvalRequested
    case subagentStarted
    case subagentStopped
    case completed
    case failed
    case ping
}

struct CodexBridgeEvent: Codable, Sendable {
    static let currentVersion = 2

    let version: Int
    let requestId: UUID
    let event: CodexBridgeEventName
    let timestamp: Date
    let sessionId: String
    let turnId: String?
    let cwd: String
    let model: String?
    let agentId: String?
    let agentType: String?
    let prompt: String?
    let lastAssistantMessage: String?
    let errorMessage: String?
    let toolName: String?
    let toolInput: CodexJSONValue?
    let humanDescription: String?
    let authToken: String
    var deliverySequence: UInt64?

    private enum CodingKeys: String, CodingKey {
        case version, requestId, event, timestamp, sessionId, turnId, cwd, model
        case agentId, agentType, prompt, lastAssistantMessage, errorMessage
        case toolName, toolInput, humanDescription, authToken
    }

    init(
        version: Int = currentVersion,
        requestId: UUID = UUID(),
        event: CodexBridgeEventName,
        timestamp: Date = Date(),
        sessionId: String,
        turnId: String? = nil,
        cwd: String,
        model: String? = nil,
        agentId: String? = nil,
        agentType: String? = nil,
        prompt: String? = nil,
        lastAssistantMessage: String? = nil,
        errorMessage: String? = nil,
        toolName: String? = nil,
        toolInput: CodexJSONValue? = nil,
        humanDescription: String? = nil,
        authToken: String = "",
        deliverySequence: UInt64? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.event = event
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.turnId = turnId
        self.cwd = cwd
        self.model = model
        self.agentId = agentId
        self.agentType = agentType
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.errorMessage = errorMessage
        self.toolName = toolName
        self.toolInput = toolInput
        self.humanDescription = humanDescription
        self.authToken = authToken
        self.deliverySequence = deliverySequence
    }

    func authenticated(with token: String) -> Self {
        Self(
            version: version,
            requestId: requestId,
            event: event,
            timestamp: timestamp,
            sessionId: sessionId,
            turnId: turnId,
            cwd: cwd,
            model: model,
            agentId: agentId,
            agentType: agentType,
            prompt: prompt,
            lastAssistantMessage: lastAssistantMessage,
            errorMessage: errorMessage,
            toolName: toolName,
            toolInput: toolInput,
            humanDescription: humanDescription,
            authToken: token,
            deliverySequence: deliverySequence
        )
    }

    func activityEvent(sequence: Int, approvalTimeout: TimeInterval = 30) -> CodexActivityEvent? {
        let kind: CodexActivityEvent.Kind
        switch event {
        case .sessionStart: kind = .sessionStarted
        case .working: kind = .working
        case .approvalRequested:
            kind = .approvalRequested(
                id: requestId,
                expiresAt: timestamp.addingTimeInterval(approvalTimeout)
            )
        case .subagentStarted:
            guard let agentId, !agentId.isEmpty else { return nil }
            kind = .subagentStarted(agentID: agentId)
        case .subagentStopped:
            guard let agentId, !agentId.isEmpty else { return nil }
            kind = .subagentStopped(agentID: agentId)
        case .completed: kind = .completed
        case .failed: kind = .failed
        case .ping: return nil
        }
        return CodexActivityEvent(
            origin: .trustedHook,
            sequence: sequence,
            timestamp: timestamp,
            sessionID: sessionId,
            turnID: turnId,
            cwd: cwd,
            kind: kind
        )
    }
}

enum CodexApprovalDecision: String, Codable, Sendable {
    case allow
    case deny
    case deferDecision = "defer"
}

struct CodexApprovalResponse: Codable, Sendable {
    let version: Int
    let requestId: UUID
    let decision: CodexApprovalDecision
}

struct CodexBridgeAcknowledgement: Codable, Sendable {
    let version: Int
    let requestId: UUID
    let accepted: Bool
    let error: String?
}

struct CodexBridgeRuntimeMetadata: Codable, Sendable {
    let version: Int
    let socketPath: String
    let tokenPath: String
    let pid: Int32
    let uid: uid_t
    let appVersion: String
    let approvalTimeout: TimeInterval
}

extension JSONEncoder {
    static var codexBridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var codexBridge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
