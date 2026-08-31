import Darwin
import Foundation

enum CodexHookInstallerTests {
    static func run() throws {
        try mergingIsIdempotentAndPreservesForeignHooks()
        try explicitInstallAndRemovalPreserveUnrelatedConfiguration()
        try symlinkedHooksAreRejectedWithoutTouchingTheirTarget()
        try cowlickCommandIsMigratedOnlyWhenExplicitlyNamed()
        try cowlickStatusExplainsMigration()
    }

    private static func mergingIsIdempotentAndPreservesForeignHooks() throws {
        let command = "'/Users/test/.local/bin/boring-notch-hook' hook"
        let original = Data(
            #"{"future":{"enabled":true},"hooks":{"Stop":[{"matcher":"keep","hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#.utf8
        )
        let merged = try CodexHookInstaller.merging(original, command: command)
        try expect(merged == CodexHookInstaller.merging(merged, command: command))
        let root = try object(merged)
        try expect((root["future"] as? [String: Any])?["enabled"] as? Bool == true)
        let hooks = try value(root["hooks"] as? [String: Any])
        for event in CodexHookInstaller.supportedEvents {
            let groups = try value(hooks[event] as? [[String: Any]])
            let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            try expect(handlers.count {
                ($0["boringNotch"] as? [String: Any])?["product"] as? String == "Boring Notch"
            } == 1)
        }
        let stopGroups = try value(hooks["Stop"] as? [[String: Any]])
        try expect(stopGroups.first?["matcher"] as? String == "keep")
    }

    private static func explicitInstallAndRemovalPreserveUnrelatedConfiguration() throws {
        let root = URL(fileURLWithPath: "/tmp/bni-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bundle = root.appendingPathComponent("boringNotch.app", isDirectory: true)
        let helper = root.appendingPathComponent("BoringNotchXPCHelper")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("signed-helper-fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let installer = CodexHookInstaller(
            homeDirectory: home,
            applicationBundleURL: bundle,
            bundledHelperURL: helper,
            arguments: []
        )
        let original = Data(
            #"{"custom":"preserve","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#.utf8
        )
        try FileManager.default.createDirectory(
            at: installer.hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: installer.hooksURL)

        try installer.installOrRepair()
        try expect(installer.status().isHealthy)
        try expect(mode(of: installer.installedHelperURL) == 0o755)
        try expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: installer.shimURL.path)
                == installer.installedHelperURL.path
        )
        try installer.removeIntegration()
        try expect(!FileManager.default.fileExists(atPath: installer.installedHelperURL.path))
        let restored = try object(Data(contentsOf: installer.hooksURL))
        try expect(restored["custom"] as? String == "preserve")
        let hooks = try value(restored["hooks"] as? [String: Any])
        let handlers = try value((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        try expect(handlers.first?["command"] as? String == "/usr/local/bin/other")
    }

    private static func symlinkedHooksAreRejectedWithoutTouchingTheirTarget() throws {
        let root = URL(fileURLWithPath: "/tmp/bns-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let helper = root.appendingPathComponent("helper")
        let target = root.appendingPathComponent("foreign.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        let targetData = Data(#"{"foreign":true}"#.utf8)
        try targetData.write(to: target)
        let installer = CodexHookInstaller(homeDirectory: home, bundledHelperURL: helper, arguments: [])
        try FileManager.default.createDirectory(
            at: installer.hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: installer.hooksURL, withDestinationURL: target)
        do {
            try installer.installOrRepair()
            throw Failure(message: "symlinked hooks were accepted")
        } catch CodexHookInstallerError.unsafeHooksFile {
            try expect(try Data(contentsOf: target) == targetData)
        }
    }

    private static func cowlickCommandIsMigratedOnlyWhenExplicitlyNamed() throws {
        let cowlick = "'/Users/test/.local/bin/cowlick-hook' hook"
        let boring = "'/Users/test/.local/bin/boring-notch-hook' hook"
        let original = Data(
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/Users/test/.local/bin/cowlick-hook' hook"}]}]}}"#.utf8
        )
        let migrated = try CodexHookInstaller.merging(
            original,
            command: boring,
            legacyCommands: [cowlick]
        )
        let hooks = try value(try object(migrated)["hooks"] as? [String: Any])
        let handlers = (try value(hooks["Stop"] as? [[String: Any]]))
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        try expect(handlers.count == 1)
        try expect(handlers.first?["command"] as? String == boring)
    }

    private static func cowlickStatusExplainsMigration() throws {
        let root = URL(fileURLWithPath: "/tmp/bnc-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helper)
        let installer = CodexHookInstaller(
            homeDirectory: home,
            bundledHelperURL: helper,
            arguments: []
        )
        let command = "'\(installer.cowlickShimURL.path)' hook"
        let hooks = try CodexHookInstaller.merging(Data("{}".utf8), command: command)
        try hooks.write(to: installer.hooksURL)

        let status = installer.status()
        try expect(!status.isHealthy)
        try expect(status.legacyEvents == Set(CodexHookInstaller.supportedEvents))
        try expect(status.summary == "Cowlick hooks detected — migration needed")
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try value(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func value<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "missing fixture value") }
        return value
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
        guard try condition() else { throw Failure(message: "failed at \(file):\(line)") }
    }

    private struct Failure: Error {
        let message: String
    }
}
