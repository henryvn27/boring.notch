// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Darwin
import Foundation

enum CodexHookBridgeError: LocalizedError {
    case appUnavailable
    case insecureMetadata
    case unsupportedVersion
    case oversizedMessage
    case socketFailure(Int32)
    case malformedResponse
    case mismatchedResponse
    case rejectedResponse

    var errorDescription: String? {
        switch self {
        case .appUnavailable: "Boring Notch is not running."
        case .insecureMetadata: "Codex bridge metadata failed owner or permission validation."
        case .unsupportedVersion: "Boring Notch and its Codex hook use different protocol versions."
        case .oversizedMessage: "The Codex bridge message exceeds 1 MB."
        case let .socketFailure(code): "The Codex bridge socket failed (errno \(code))."
        case .malformedResponse: "Boring Notch returned malformed bridge JSON."
        case .mismatchedResponse: "The bridge response did not match this request."
        case .rejectedResponse: "Boring Notch rejected the bridge request."
        }
    }
}

struct CodexHookBridgeClient {
    static let maximumMessageSize = 1_048_576

    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    var runtimeMetadataURL: URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/BoringNotch/runtime.json"
        )
    }

    func send(
        _ unauthenticatedEvent: CodexBridgeEvent,
        waitForResponse: Bool
    ) throws -> CodexApprovalResponse? {
        let metadata = try loadMetadata()
        guard metadata.version == CodexBridgeEvent.currentVersion else {
            throw CodexHookBridgeError.unsupportedVersion
        }
        guard metadata.uid == getuid(), kill(metadata.pid, 0) == 0 else {
            throw CodexHookBridgeError.appUnavailable
        }
        let token = try loadPrivateFile(at: URL(fileURLWithPath: metadata.tokenPath))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let event = unauthenticatedEvent.authenticated(with: token)

        var payload = try JSONEncoder.codexBridge.encode(event)
        guard payload.count < Self.maximumMessageSize else {
            throw CodexHookBridgeError.oversizedMessage
        }
        payload.append(0x0A)

        let timeout = event.event == .approvalRequested ? metadata.approvalTimeout + 1 : 1
        let descriptor = try connect(path: metadata.socketPath, timeout: timeout)
        defer { Darwin.close(descriptor) }
        try write(payload, to: descriptor)
        guard waitForResponse else { return nil }

        let responseData = try readLine(from: descriptor)
        if event.event == .approvalRequested {
            guard let response = try? JSONDecoder.codexBridge.decode(
                CodexApprovalResponse.self,
                from: responseData
            ) else { throw CodexHookBridgeError.malformedResponse }
            guard response.version == CodexBridgeEvent.currentVersion,
                  response.requestId == event.requestId
            else { throw CodexHookBridgeError.mismatchedResponse }
            return response
        }
        guard let acknowledgement = try? JSONDecoder.codexBridge.decode(
            CodexBridgeAcknowledgement.self,
            from: responseData
        ) else { throw CodexHookBridgeError.malformedResponse }
        guard acknowledgement.version == CodexBridgeEvent.currentVersion,
              acknowledgement.requestId == event.requestId
        else { throw CodexHookBridgeError.mismatchedResponse }
        guard acknowledgement.accepted else { throw CodexHookBridgeError.rejectedResponse }
        return nil
    }

    func diagnostics() -> [String: Any] {
        do {
            let metadata = try loadMetadata()
            let event = CodexBridgeEvent(
                event: .ping,
                sessionId: "diagnostics",
                cwd: FileManager.default.currentDirectoryPath
            )
            _ = try send(event, waitForResponse: true)
            return [
                "ok": true,
                "appVersion": metadata.appVersion,
                "pid": metadata.pid,
                "protocolVersion": metadata.version,
                "socket": "reachable",
            ]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func loadMetadata() throws -> CodexBridgeRuntimeMetadata {
        let data = Data(try loadPrivateFile(at: runtimeMetadataURL).utf8)
        guard let metadata = try? JSONDecoder.codexBridge.decode(
            CodexBridgeRuntimeMetadata.self,
            from: data
        ) else { throw CodexHookBridgeError.appUnavailable }
        return metadata
    }

    private func loadPrivateFile(at url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0
        else { throw CodexHookBridgeError.insecureMetadata }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
            throw CodexHookBridgeError.appUnavailable
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexHookBridgeError.socketFailure(errno) }
        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var socketTimeout = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for index in bytes.indices { destination[index] = bytes[index] }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CodexHookBridgeError.socketFailure(code)
        }
        return descriptor
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        let sentAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
        guard sentAll else { throw CodexHookBridgeError.socketFailure(errno) }
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= Self.maximumMessageSize {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { throw CodexHookBridgeError.socketFailure(errno) }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                guard data.count + newline <= Self.maximumMessageSize else {
                    throw CodexHookBridgeError.oversizedMessage
                }
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw CodexHookBridgeError.oversizedMessage
    }
}
