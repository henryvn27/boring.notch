// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

enum CodexHookCommand {
    static let supportedCommands = Set([
        "hook", "ping", "diagnostics", "demo", "progress", "progress-clear",
        "version", "--version", "-v",
    ])

    static func canHandle(arguments: [String]) -> Bool {
        arguments.dropFirst().first.map(supportedCommands.contains) ?? false
    }

    static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.dropFirst().first else { return 2 }
        let client = CodexHookBridgeClient()
        switch command {
        case "hook": return runHook(client: client)
        case "ping": return runPing(client: client)
        case "diagnostics":
            writeJSON(client.diagnostics())
            return 0
        case "demo":
            guard let name = arguments.dropFirst(2).first else { return 2 }
            return runDemo(name: name, client: client)
        case "progress": return runProgress()
        case "progress-clear": return clearProgress()
        case "version", "--version", "-v":
            writeOutput("Boring Notch Codex hook \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")\n")
            return 0
        default:
            return 2
        }
    }

    private static func runHook(client: CodexHookBridgeClient) -> Int32 {
        guard let inputData = readBoundedInput() else {
            writeError("hook input is unavailable or exceeds 1 MB; deferring safely")
            return 0
        }
        let input: CodexHookInput
        do {
            input = try JSONDecoder().decode(CodexHookInput.self, from: inputData)
        } catch {
            writeError("invalid Codex hook input: \(error.localizedDescription)")
            return 1
        }
        guard input.hasValidIdentity else {
            writeError("invalid Codex hook identity")
            return 1
        }
        let event = bridgeEvent(from: input)
        updateLifecycleLedger(input: input, event: event)
        do {
            switch input.hookEventName {
            case .permissionRequest:
                if let response = try client.send(event, waitForResponse: true),
                   let output = try CodexHookOutput.permission(response.decision)
                {
                    FileHandle.standardOutput.write(output)
                }
            case .stop:
                _ = try client.send(event, waitForResponse: false)
                FileHandle.standardOutput.write(CodexHookOutput.neutralStop)
            case .sessionStart, .userPromptSubmit, .subagentStart, .subagentStop:
                _ = try client.send(event, waitForResponse: false)
            }
        } catch {
            writeError("Codex event delivery deferred: \(error.localizedDescription)")
        }
        return 0
    }

    private static func runPing(client: CodexHookBridgeClient) -> Int32 {
        let result = client.diagnostics()
        writeJSON(result)
        return result["ok"] as? Bool == true ? 0 : 1
    }

    private static func runProgress() -> Int32 {
        guard let input = readBoundedInput(maximumSize: CodexAgentProgressStore.maximumDocumentSize) else {
            writeError("progress input is unavailable or exceeds 64 KB")
            return 1
        }
        do {
            try CodexAgentProgressStore().write(input)
            writeJSON(["stored": true])
            return 0
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func clearProgress() -> Int32 {
        do {
            try CodexAgentProgressStore().clear()
            writeJSON(["cleared": true])
            return 0
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func runDemo(name: String, client: CodexHookBridgeClient) -> Int32 {
        let eventName: CodexBridgeEventName
        switch name {
        case "working": eventName = .working
        case "approval": eventName = .approvalRequested
        case "completed": eventName = .completed
        case "failed": eventName = .failed
        default: return 2
        }
        let requestedSessionID = ProcessInfo.processInfo.environment["BORING_NOTCH_DEMO_SESSION_ID"]
        let sessionID = requestedSessionID.flatMap { value in
            let bounded = String(value.prefix(256))
            return bounded.isEmpty ? nil : bounded
        } ?? "boring-notch-demo"
        let event = CodexBridgeEvent(
            event: eventName,
            sessionId: sessionID,
            turnId: "demo-turn",
            cwd: FileManager.default.currentDirectoryPath,
            prompt: name == "working" ? "Prepare the release verification" : nil,
            lastAssistantMessage: name == "completed" ? "Release verification passed" : nil,
            errorMessage: name == "failed" ? "Bridge self-test failed" : nil,
            toolName: name == "approval" ? "Bash" : nil,
            toolInput: name == "approval"
                ? .object(["command": .string("git push"), "description": .string("Publish the verified branch")])
                : nil,
            humanDescription: name == "approval" ? "Publish the verified branch" : nil
        )
        do {
            let response = try client.send(event, waitForResponse: name == "approval")
            writeJSON(response.map { ["decision": $0.decision.rawValue] } ?? ["sent": true])
            return 0
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func bridgeEvent(from input: CodexHookInput) -> CodexBridgeEvent {
        let name: CodexBridgeEventName
        switch input.hookEventName {
        case .sessionStart: name = .sessionStart
        case .userPromptSubmit: name = .working
        case .permissionRequest: name = .approvalRequested
        case .subagentStart: name = .subagentStarted
        case .subagentStop: name = .subagentStopped
        case .stop: name = .completed
        }
        return CodexBridgeEvent(
            event: name,
            sessionId: input.sessionId,
            turnId: input.turnId,
            cwd: input.cwd,
            model: input.model,
            agentId: input.agentId.map { String($0.prefix(256)) },
            agentType: input.agentType.map { String($0.prefix(128)) },
            prompt: input.prompt.map { String($0.prefix(65_536)) },
            lastAssistantMessage: input.lastAssistantMessage.map { String($0.prefix(65_536)) },
            toolName: input.toolName,
            toolInput: input.toolInput,
            humanDescription: input.humanDescription
        )
    }

    private static func updateLifecycleLedger(
        input: CodexHookInput,
        event: CodexBridgeEvent
    ) {
        do {
            switch input.hookEventName {
            case .userPromptSubmit, .permissionRequest:
                try CodexLifecycleLedger.markWorking(
                    sessionID: event.sessionId,
                    turnID: event.turnId,
                    workingDirectory: event.cwd,
                    model: event.model,
                    updatedAt: event.timestamp
                )
            case .sessionStart, .stop:
                try CodexLifecycleLedger.remove(
                    sessionID: event.sessionId,
                    now: event.timestamp
                )
            case .subagentStart, .subagentStop:
                break
            }
        } catch {
            writeError("lifecycle recovery state was not updated: \(error.localizedDescription)")
        }
    }

    private static func readBoundedInput(
        maximumSize: Int = CodexHookBridgeClient.maximumMessageSize
    ) -> Data? {
        var input = Data()
        do {
            while input.count <= maximumSize {
                let remaining = maximumSize + 1 - input.count
                guard let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty
                else { return input }
                input.append(chunk)
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func writeJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    private static func writeOutput(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data("boring-notch-hook: \(value)\n".utf8))
    }
}
