// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Combine
import Foundation

@MainActor
final class ProviderAccountsManager: ObservableObject {
    static let shared = ProviderAccountsManager()

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var snapshots: [UUID: ActualBilledSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshingAccountIDs = Set<UUID>()
    @Published private(set) var errorMessage: String?

    private let accountStore: ProviderAccountStore
    private let credentialStore: any CredentialSecretStore
    private let openAIService: any ProviderCostFetching
    private let anthropicService: any ProviderCostFetching

    init(
        accountStore: ProviderAccountStore = ProviderAccountStore(),
        credentialStore: any CredentialSecretStore = KeychainCredentialSecretStore(),
        openAIService: any ProviderCostFetching = OpenAIAdminCostService(),
        anthropicService: any ProviderCostFetching = AnthropicAdminCostService()
    ) {
        self.accountStore = accountStore
        self.credentialStore = credentialStore
        self.openAIService = openAIService
        self.anthropicService = anthropicService
    }

    func load() async {
        do {
            accounts = try await accountStore.accounts()
            errorMessage = nil
        } catch {
            errorMessage = Self.sanitized(error.localizedDescription)
        }
    }

    @discardableResult
    func add(provider: UsageProvider, alias: String, credential: String) async throws
        -> ProviderAccount
    {
        let account = try await accountStore.create(
            provider: provider,
            alias: alias,
            credential: Data(credential.utf8)
        )
        await load()
        await refresh(account)
        return account
    }

    func rename(_ account: ProviderAccount, alias: String) async throws {
        try await accountStore.rename(accountID: account.id, alias: alias)
        await load()
    }

    func replaceCredential(_ account: ProviderAccount, credential: String) async throws {
        try await accountStore.replaceCredential(
            accountID: account.id,
            credential: Data(credential.utf8)
        )
        snapshots.removeValue(forKey: account.id)
        await refresh(account)
    }

    func remove(_ account: ProviderAccount) async throws {
        _ = try await accountStore.remove(accountID: account.id)
        snapshots.removeValue(forKey: account.id)
        errors.removeValue(forKey: account.id)
        await load()
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account) }
            }
        }
    }

    func refresh(_ account: ProviderAccount) async {
        guard !refreshingAccountIDs.contains(account.id) else { return }
        refreshingAccountIDs.insert(account.id)
        defer { refreshingAccountIDs.remove(account.id) }
        do {
            guard let credential = try await credentialStore.secret(
                for: account.credentialReference
            ) else {
                throw ProviderAccountsManagerError.missingCredential
            }
            let service: any ProviderCostFetching =
                account.provider == .openAIAPI ? openAIService : anthropicService
            let snapshot = try await service.fetchActualCosts(
                accountID: account.id,
                credential: credential,
                interval: Self.monthToDateInterval(endingAt: Date())
            )
            guard snapshot.accountID == account.id, snapshot.provider == account.provider else {
                throw ProviderAccountsManagerError.mismatchedResponse
            }
            snapshots[account.id] = snapshot
            errors.removeValue(forKey: account.id)
        } catch {
            errors[account.id] = Self.sanitized(error.localizedDescription)
        }
    }

    static func monthToDateInterval(endingAt date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        return DateInterval(start: start, end: max(date, start.addingTimeInterval(1)))
    }

    private static func sanitized(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return String(
            value.replacingOccurrences(of: home, with: "~")
                .unicodeScalars
                .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
                .joined()
                .prefix(240)
        )
    }
}

private enum ProviderAccountsManagerError: LocalizedError {
    case missingCredential
    case mismatchedResponse

    var errorDescription: String? {
        switch self {
        case .missingCredential: "The Keychain credential is missing."
        case .mismatchedResponse: "The billing response did not match this account."
        }
    }
}
