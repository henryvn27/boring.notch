import Foundation

enum CapsLockSignalServiceTests {
    static func run() async throws {
        try await signalTestRestoresOriginalState()
        try await persistentApprovalRestoresOnCancel()
    }

    private static func signalTestRestoresOriginalState() async throws {
        let controller = TestCapsLockController(initialState: true)
        let service = NativeCapsLockSignalService(controller: controller)
        let result = await service.testSignal()
        try expect(result == .available)
        try expect(controller.state == true)
    }

    private static func persistentApprovalRestoresOnCancel() async throws {
        let controller = TestCapsLockController(initialState: false)
        let service = NativeCapsLockSignalService(controller: controller)
        await service.setPersistentAttention(.approval)
        try expect(controller.state == true)
        await service.cancelAndRestore()
        try expect(controller.state == false)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        guard condition() else {
            throw TestFailure(message: "failed at \(file):\(line)")
        }
    }

    private final class TestCapsLockController: CapsLockControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(initialState: Bool) {
            value = initialState
        }

        var state: Bool { lock.withLock { value } }

        func readState() throws -> Bool {
            lock.withLock { value }
        }

        func setState(_ state: Bool) throws {
            lock.withLock { value = state }
        }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
