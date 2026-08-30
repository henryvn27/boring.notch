import Darwin
import Foundation

enum CodexBridgeServerTests {
    static func run() throws {
        try authenticatedRoundTripUsesPrivateFilesAndSameUserSocket()
        try unsafeSocketOccupantIsNeverRemoved()
    }

    private static func authenticatedRoundTripUsesPrivateFilesAndSameUserSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/bnt-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent(
            "Library/Application Support/BoringNotch",
            isDirectory: true
        )
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let paths = CodexBridgePaths(
            tokenURL: support.appendingPathComponent("auth-token"),
            runtimeMetadataURL: support.appendingPathComponent("runtime.json"),
            socketURL: runtime.appendingPathComponent("bridge.sock")
        )
        let received = DispatchSemaphore(value: 0)
        let server = CodexBridgeServer(paths: paths, approvalTimeout: 1, appVersion: "test") { event in
            if event.event == .working { received.signal() }
            return event.event == .approvalRequested ? .deny : nil
        }
        try server.start()
        defer { server.stop() }

        try expect(mode(of: support) == 0o700)
        try expect(mode(of: runtime) == 0o700)
        try expect(mode(of: paths.tokenURL) == 0o600)
        try expect(mode(of: paths.runtimeMetadataURL) == 0o600)
        try expect(mode(of: paths.socketURL) == 0o600)

        let client = CodexHookBridgeClient(homeDirectory: home)
        let event = CodexBridgeEvent(
            event: .working,
            sessionId: "session",
            turnId: "turn",
            cwd: "/Users/hidden/Project"
        )
        _ = try client.send(event, waitForResponse: true)
        try expect(received.wait(timeout: .now() + 1) == .success)

        let approval = try client.send(
            CodexBridgeEvent(
                event: .approvalRequested,
                sessionId: "session",
                turnId: "turn",
                cwd: "/Users/hidden/Project"
            ),
            waitForResponse: true
        )
        try expect(approval?.decision == .deny)

        server.stop()
        try expect(!FileManager.default.fileExists(atPath: paths.runtimeMetadataURL.path))
        try expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
    }

    private static func unsafeSocketOccupantIsNeverRemoved() throws {
        let root = URL(fileURLWithPath: "/tmp/bnu-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketURL = root.appendingPathComponent("bridge.sock")
        try Data("owned data".utf8).write(to: socketURL)
        do {
            try CodexBridgeServer.recoverStaleSocket(at: socketURL.path)
            throw TestFailure(message: "unsafe socket occupant was accepted")
        } catch CodexBridgeServerError.unsafeExistingSocketPath {
            try expect(try String(contentsOf: socketURL, encoding: .utf8) == "owned data")
        }
    }

    private static func mode(of url: URL) -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard try condition() else {
            throw TestFailure(message: "failed at \(file):\(line)")
        }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
