// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Combine
import Foundation

@MainActor
final class CodexUsageManager: ObservableObject {
    static let shared = CodexUsageManager()

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let service: any CodexUsageFetching
    private var periodicTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastActivityRefresh = Date.distantPast

    init(service: any CodexUsageFetching = CodexUsageService()) {
        self.service = service
    }

    func start() {
        guard periodicTask == nil else { return }
        refresh()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        snapshot = nil
        errorMessage = nil
    }

    func refreshAfterActivity(now: Date = Date()) {
        guard now.timeIntervalSince(lastActivityRefresh) >= 30 else { return }
        lastActivityRefresh = now
        refresh()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await service.fetchUsage()
                guard !Task.isCancelled else { return }
                snapshot = next
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
            refreshTask = nil
        }
    }
}
