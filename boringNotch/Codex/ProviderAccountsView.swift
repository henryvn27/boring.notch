// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import SwiftUI

struct ProviderAccountsSettingsSection: View {
    @ObservedObject private var manager = ProviderAccountsManager.shared
    @State private var editor: ProviderAccountEditor.Purpose?
    @State private var pendingRemoval: ProviderAccount?

    var body: some View {
        Section {
            if manager.accounts.isEmpty {
                Text("No API billing accounts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.accounts) { account in
                    accountRow(account)
                }
            }
            Button {
                editor = .add
            } label: {
                Label("Add API Billing Account", systemImage: "plus")
            }
            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Provider billing accounts")
        } footer: {
            Text("OpenAI amounts are official organization month-to-date API charges. Anthropic amounts are partial because its official report excludes Priority Tier usage. Admin keys are stored only in macOS Keychain and accounts are never combined into a misleading total.")
        }
        .task {
            await manager.load()
            await manager.refreshAll()
        }
        .sheet(item: $editor) { purpose in
            ProviderAccountEditor(purpose: purpose)
        }
        .confirmationDialog(
            "Remove billing account?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { account in
            Button("Remove \(account.alias)", role: .destructive) {
                Task {
                    try? await manager.remove(account)
                    pendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("This removes \(account.alias) and its Keychain credential from boring.notch. It does not change the provider account.")
        }
    }

    private func accountRow(_ account: ProviderAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "building.2")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.alias).fontWeight(.medium)
                Text(account.provider.billingAccountName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            billingStatus(account)
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await manager.refresh(account) }
                }
                Button("Rename…", systemImage: "pencil") {
                    editor = .rename(account)
                }
                Button("Replace Admin Key…", systemImage: "key") {
                    editor = .replaceCredential(account)
                }
                Divider()
                Button("Remove…", systemImage: "trash", role: .destructive) {
                    pendingRemoval = account
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func billingStatus(_ account: ProviderAccount) -> some View {
        if manager.refreshingAccountIDs.contains(account.id) {
            ProgressView().controlSize(.small)
        } else if let snapshot = manager.snapshots[account.id] {
            VStack(alignment: .trailing, spacing: 1) {
                Text(
                    NSDecimalNumber(decimal: snapshot.amount).doubleValue,
                    format: .currency(code: snapshot.currency)
                )
                .monospacedDigit()
                Text(snapshot.provider == .anthropicAPI ? "partial month to date" : "month to date")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let error = manager.errors[account.id] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: 170, alignment: .trailing)
        } else {
            Text("Not refreshed").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProviderAccountEditor: View {
    enum Purpose: Identifiable {
        case add
        case rename(ProviderAccount)
        case replaceCredential(ProviderAccount)

        var id: String {
            switch self {
            case .add: "add"
            case .rename(let account): "rename-\(account.id)"
            case .replaceCredential(let account): "credential-\(account.id)"
            }
        }
    }

    let purpose: Purpose
    @Environment(\.dismiss) private var dismiss
    @State private var provider: UsageProvider
    @State private var alias: String
    @State private var credential = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(purpose: Purpose) {
        self.purpose = purpose
        switch purpose {
        case .add:
            _provider = State(initialValue: .openAIAPI)
            _alias = State(initialValue: "")
        case .rename(let account), .replaceCredential(let account):
            _provider = State(initialValue: account.provider)
            _alias = State(initialValue: account.alias)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if case .add = purpose {
                    Picker("Provider", selection: $provider) {
                        ForEach(UsageProvider.supportedBillingAccounts, id: \.self) {
                            Text($0.billingAccountName ?? "").tag($0)
                        }
                    }
                }
                if !isReplacingCredential {
                    TextField("Account name", text: $alias)
                }
                if needsCredential {
                    SecureField("Admin API key", text: $credential)
                    Text("The key is stored in macOS Keychain, used only for the provider's official organization billing endpoint, and never displayed again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(isSaving ? "Saving…" : saveTitle) {
                    Task { await save() }
                }
                .disabled(!canSave || isSaving)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 440, height: needsCredential ? 300 : 220)
        .onDisappear { credential = "" }
    }

    private var needsCredential: Bool {
        switch purpose {
        case .add, .replaceCredential: true
        case .rename: false
        }
    }

    private var isReplacingCredential: Bool {
        if case .replaceCredential = purpose { return true }
        return false
    }

    private var canSave: Bool {
        let validAlias = !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && alias.count <= 64
        let validCredential = !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (isReplacingCredential || validAlias) && (!needsCredential || validCredential)
    }

    private var saveTitle: String {
        switch purpose {
        case .add: "Add Account"
        case .rename: "Rename"
        case .replaceCredential: "Replace Key"
        }
    }

    private func save() async {
        isSaving = true
        defer {
            isSaving = false
            credential = ""
        }
        do {
            let manager = ProviderAccountsManager.shared
            switch purpose {
            case .add:
                _ = try await manager.add(
                    provider: provider,
                    alias: alias,
                    credential: credential
                )
            case .rename(let account):
                try await manager.rename(account, alias: alias)
            case .replaceCredential(let account):
                try await manager.replaceCredential(account, credential: credential)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
