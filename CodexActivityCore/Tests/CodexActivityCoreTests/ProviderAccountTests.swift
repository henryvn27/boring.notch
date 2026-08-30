import Darwin
import Foundation

enum ProviderAccountTests {
    static func run() async throws {
        try await metadataNeverContainsCredentialAndRemovalCleansSecret()
        try await openAIBillingUsesOfficialAccountWideMeasurement()
    }

    private static func metadataNeverContainsCredentialAndRemovalCleansSecret() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("boring-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent("provider-accounts.json")
        let credentials = TestCredentialStore()
        let store = ProviderAccountStore(metadataURL: metadataURL, credentialStore: credentials)
        let secret = "sk-admin-private"
        let account = try await store.create(
            provider: .openAIAPI,
            alias: "Production",
            credential: Data(secret.utf8)
        )
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
        try expect(!metadata.contains(secret))
        try expect(metadata.contains("Production"))
        var info = stat()
        try expect(lstat(metadataURL.path, &info) == 0)
        try expect(info.st_mode & 0o777 == 0o600)
        let storedSecret = await credentials.secret(for: account.credentialReference)
        try expect(storedSecret == Data(secret.utf8))

        _ = try await store.remove(accountID: account.id)
        let removedSecret = await credentials.secret(for: account.credentialReference)
        try expect(removedSecret == nil)
    }

    private static func openAIBillingUsesOfficialAccountWideMeasurement() async throws {
        let payload = Data(
            #"{"data":[{"results":[{"amount":{"value":12.34,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#.utf8
        )
        let transport = TestHTTPTransport(payload: payload, statusCode: 200)
        let service = OpenAIAdminCostService(transport: transport)
        let accountID = UUID()
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_777_593_600),
            end: Date(timeIntervalSince1970: 1_777_680_000)
        )
        let snapshot = try await service.fetchActualCosts(
            accountID: accountID,
            credential: Data("sk-admin".utf8),
            interval: interval
        )
        try expect(snapshot.accountID == accountID)
        try expect(snapshot.amount == Decimal(string: "12.34"))
        try expect(snapshot.currency == "USD")
        try expect(snapshot.measurement.kind == .actualBilled)
        try expect(snapshot.measurement.coverage == .accountWide)
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

    private actor TestCredentialStore: CredentialSecretStore {
        private var values: [CredentialReference: Data] = [:]

        func store(_ secret: Data, for reference: CredentialReference) {
            values[reference] = secret
        }

        func secret(for reference: CredentialReference) -> Data? {
            values[reference]
        }

        func deleteSecret(for reference: CredentialReference) {
            values.removeValue(forKey: reference)
        }
    }

    private struct TestHTTPTransport: HTTPDataTransport {
        let payload: Data
        let statusCode: Int

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-admin",
                  let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  )
            else { throw TestFailure(message: "invalid request") }
            return (payload, response)
        }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
