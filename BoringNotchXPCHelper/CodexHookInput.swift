// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

enum CodexHookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
}

struct CodexHookInput: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let hookEventName: CodexHookEventName
    let model: String?
    let turnId: String?
    let agentId: String?
    let agentType: String?
    let prompt: String?
    let toolName: String?
    let toolInput: CodexJSONValue?
    let lastAssistantMessage: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case model
        case turnId = "turn_id"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case prompt
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case lastAssistantMessage = "last_assistant_message"
    }

    var humanDescription: String? {
        toolInput?.objectValue?["description"]?.stringValue
    }

    var hasValidIdentity: Bool {
        switch hookEventName {
        case .subagentStart, .subagentStop:
            return agentId?.isEmpty == false
                && agentType?.isEmpty == false
                && turnId?.isEmpty == false
        default:
            return !sessionId.isEmpty && !cwd.isEmpty
        }
    }
}

enum CodexHookOutput {
    static let neutralStop = Data("{}\n".utf8)

    static func permission(_ decision: CodexApprovalDecision) throws -> Data? {
        switch decision {
        case .deferDecision:
            return nil
        case .allow:
            return try JSONSerialization.data(
                withJSONObject: [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": ["behavior": "allow"],
                    ]
                ],
                options: [.sortedKeys]
            ) + Data([0x0A])
        case .deny:
            return try JSONSerialization.data(
                withJSONObject: [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": [
                            "behavior": "deny",
                            "message": "Denied in Boring Notch.",
                        ],
                    ]
                ],
                options: [.sortedKeys]
            ) + Data([0x0A])
        }
    }
}
