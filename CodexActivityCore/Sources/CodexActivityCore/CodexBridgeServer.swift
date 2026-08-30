// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Darwin
import Foundation

struct CodexBridgePaths: Sendable {
    let tokenURL: URL
    let runtimeMetadataURL: URL
    let socketURL: URL

    static var applicationSupport: Self {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("BoringNotch", isDirectory: true)
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoringNotch-\(getuid())", isDirectory: true)
        return Self(
            tokenURL: support.appendingPathComponent("auth-token"),
            runtimeMetadataURL: support.appendingPathComponent("runtime.json"),
            socketURL: runtime.appendingPathComponent("bridge.sock")
        )
    }

    func prepareDirectories() throws {
        for directory in [tokenURL.deletingLastPathComponent(), socketURL.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}

enum CodexBridgeServerError: LocalizedError {
    case pathTooLong
    case socketCreation(Int32)
    case bind(Int32)
    case listen(Int32)
    case insecurePrivateFile
    case permissions(Int32)
    case alreadyRunning
    case unsafeExistingSocketPath

    var errorDescription: String? {
        switch self {
        case .pathTooLong: "The Codex bridge socket path is too long."
        case let .socketCreation(code): "Could not create the Codex bridge socket (errno \(code))."
        case let .bind(code): "Could not bind the Codex bridge socket (errno \(code))."
        case let .listen(code): "Could not listen on the Codex bridge socket (errno \(code))."
        case .insecurePrivateFile: "A Codex bridge private file is not an owner-only regular file."
        case let .permissions(code): "Could not secure a Codex bridge file (errno \(code))."
        case .alreadyRunning: "Another Boring Notch instance is already receiving Codex events."
        case .unsafeExistingSocketPath: "The Codex bridge socket path is occupied by an unsafe file."
        }
    }
}

final class CodexBridgeServer: @unchecked Sendable {
    static let maximumMessageSize = 1_048_576

    private let acceptQueue = DispatchQueue(
        label: "com.boringnotch.codex.socket.accept",
        qos: .userInitiated
    )
    private let clientQueue = DispatchQueue(
        label: "com.boringnotch.codex.socket.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let paths: CodexBridgePaths
    private let approvalTimeout: TimeInterval
    private let appVersion: String
    private let eventHandler: @Sendable (CodexBridgeEvent) async -> CodexApprovalDecision?
    private let stateLock = NSLock()

    private var listeningDescriptor: Int32 = -1
    private var running = false
    private var nextDeliverySequence: UInt64 = 0
    private(set) var authenticationToken = ""

    init(
        paths: CodexBridgePaths = .applicationSupport,
        approvalTimeout: TimeInterval = 30,
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        eventHandler: @escaping @Sendable (CodexBridgeEvent) async -> CodexApprovalDecision?
    ) {
        self.paths = paths
        self.approvalTimeout = approvalTimeout
        self.appVersion = appVersion
        self.eventHandler = eventHandler
    }

    func start() throws {
        try paths.prepareDirectories()
        authenticationToken = try loadOrCreateToken()

        let socketPath = paths.socketURL.path
        guard socketPath.utf8CString.count <= Self.maximumSocketPathLength else {
            throw CodexBridgeServerError.pathTooLong
        }
        try Self.recoverStaleSocket(at: socketPath)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexBridgeServerError.socketCreation(errno) }
        var committed = false
        var bound = false
        defer {
            if !committed {
                Darwin.close(descriptor)
                if bound { unlink(socketPath) }
                Self.removeOwnedRegularFileIfPresent(at: paths.runtimeMetadataURL)
            }
        }

        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = try Self.socketAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, Self.addressLength(path: socketPath))
            }
        }
        guard result == 0 else { throw CodexBridgeServerError.bind(errno) }
        bound = true
        guard chmod(socketPath, 0o600) == 0 else {
            throw CodexBridgeServerError.permissions(errno)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            throw CodexBridgeServerError.listen(errno)
        }

        try publishRuntimeMetadata()
        stateLock.withLock {
            listeningDescriptor = descriptor
            nextDeliverySequence = 0
            running = true
        }
        committed = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        let descriptor = stateLock.withLock { () -> Int32 in
            running = false
            let descriptor = listeningDescriptor
            listeningDescriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        unlink(paths.socketURL.path)
        Self.removeOwnedRegularFileIfPresent(at: paths.runtimeMetadataURL)
    }

    static func recoverStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw CodexBridgeServerError.unsafeExistingSocketPath
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            throw CodexBridgeServerError.unsafeExistingSocketPath
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexBridgeServerError.socketCreation(errno) }
        defer { Darwin.close(descriptor) }
        var address = try socketAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength(path: path))
            }
        }
        if result == 0 { throw CodexBridgeServerError.alreadyRunning }
        guard errno == ECONNREFUSED || errno == ENOENT, unlink(path) == 0 || errno == ENOENT else {
            throw CodexBridgeServerError.unsafeExistingSocketPath
        }
    }

    private func acceptLoop() {
        while stateLock.withLock({ running }) {
            let descriptor = stateLock.withLock { listeningDescriptor }
            guard descriptor >= 0 else { return }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let sequence = stateLock.withLock { () -> UInt64 in
                nextDeliverySequence &+= 1
                return nextDeliverySequence
            }
            clientQueue.async { [weak self] in self?.handle(client: client, sequence: sequence) }
        }
    }

    private func handle(client: Int32, sequence: UInt64) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            writeAcknowledgement(client: client, requestID: UUID(), accepted: false, error: "Peer user mismatch")
            Darwin.close(client)
            return
        }
        guard let data = readLine(from: client) else {
            Darwin.close(client)
            return
        }

        guard var event = try? JSONDecoder.codexBridge.decode(CodexBridgeEvent.self, from: data) else {
            writeAcknowledgement(client: client, requestID: UUID(), accepted: false, error: "Malformed bridge event")
            Darwin.close(client)
            return
        }
        guard event.version == CodexBridgeEvent.currentVersion else {
            writeAcknowledgement(client: client, requestID: event.requestId, accepted: false, error: "Unsupported protocol version")
            Darwin.close(client)
            return
        }
        guard Self.constantTimeEquals(event.authToken, authenticationToken) else {
            writeAcknowledgement(client: client, requestID: event.requestId, accepted: false, error: "Authentication failed")
            Darwin.close(client)
            return
        }
        let age = Date().timeIntervalSince(event.timestamp)
        guard age >= -300, age <= 15 * 60 else {
            writeAcknowledgement(client: client, requestID: event.requestId, accepted: false, error: "Stale bridge event")
            Darwin.close(client)
            return
        }
        event.deliverySequence = sequence

        Task { [eventHandler] in
            let decision = await eventHandler(event)
            if event.event == .approvalRequested {
                write(
                    CodexApprovalResponse(
                        version: CodexBridgeEvent.currentVersion,
                        requestId: event.requestId,
                        decision: decision ?? .deferDecision
                    ),
                    to: client
                )
            } else {
                writeAcknowledgement(client: client, requestID: event.requestId, accepted: true, error: nil)
            }
            Darwin.close(client)
        }
    }

    private func readLine(from descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= Self.maximumMessageSize {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                guard data.count + newline <= Self.maximumMessageSize else { return nil }
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        return data.isEmpty || data.count > Self.maximumMessageSize ? nil : data
    }

    private func writeAcknowledgement(
        client: Int32,
        requestID: UUID,
        accepted: Bool,
        error: String?
    ) {
        write(
            CodexBridgeAcknowledgement(
                version: CodexBridgeEvent.currentVersion,
                requestId: requestID,
                accepted: accepted,
                error: error
            ),
            to: client
        )
    }

    private func write<Value: Encodable>(_ value: Value, to descriptor: Int32) {
        guard var data = try? JSONEncoder.codexBridge.encode(value) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    private func loadOrCreateToken() throws -> String {
        if try Self.secureExistingRegularFile(at: paths.tokenURL) {
            let token = try String(contentsOf: paths.tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Data(base64Encoded: token)?.count == 32 else {
                throw CodexBridgeServerError.insecurePrivateFile
            }
            return token
        }
        var generator = SystemRandomNumberGenerator()
        let token = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64EncodedString()
        try Data(token.utf8).write(to: paths.tokenURL, options: .atomic)
        try Self.secureRegularFile(at: paths.tokenURL)
        return token
    }

    private func publishRuntimeMetadata() throws {
        _ = try Self.secureExistingRegularFile(at: paths.runtimeMetadataURL)
        let metadata = CodexBridgeRuntimeMetadata(
            version: CodexBridgeEvent.currentVersion,
            socketPath: paths.socketURL.path,
            tokenPath: paths.tokenURL.path,
            pid: getpid(),
            uid: getuid(),
            appVersion: appVersion,
            approvalTimeout: approvalTimeout
        )
        try JSONEncoder.codexBridge.encode(metadata).write(to: paths.runtimeMetadataURL, options: .atomic)
        try Self.secureRegularFile(at: paths.runtimeMetadataURL)
    }

    private static var maximumSocketPathLength: Int {
        MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = path.utf8CString
        guard bytes.count <= maximumSocketPathLength else { throw CodexBridgeServerError.pathTooLong }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for index in bytes.indices { destination[index] = bytes[index] }
            }
        }
        return address
    }

    private static func addressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
    }

    private static func secureExistingRegularFile(at url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw CodexBridgeServerError.insecurePrivateFile
        }
        try secureRegularFile(at: url)
        return true
    }

    private static func secureRegularFile(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid()
        else { throw CodexBridgeServerError.insecurePrivateFile }
        guard chmod(url.path, 0o600) == 0 else {
            throw CodexBridgeServerError.permissions(errno)
        }
        guard lstat(url.path, &info) == 0, info.st_mode & 0o777 == 0o600 else {
            throw CodexBridgeServerError.insecurePrivateFile
        }
    }

    private static func removeOwnedRegularFileIfPresent(at url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid()
        else { return }
        unlink(url.path)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
