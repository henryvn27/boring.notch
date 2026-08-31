// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Combine
import Defaults
import Foundation

@MainActor
final class CodexCostManager: ObservableObject {
    static let shared = CodexCostManager()

    @Published private(set) var estimate: LocalCodexCostEstimate?
    @Published private(set) var estimateError: String?
    @Published private(set) var forecast: ResetForecast?
    @Published private(set) var forecastError: String?
    @Published private(set) var isRefreshing = false

    private let estimator: any LocalCodexCostEstimating
    private let forecastService: any ResetForecastFetching
    private var periodicTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(
        estimator: any LocalCodexCostEstimating = LocalCodexCostService(),
        forecastService: any ResetForecastFetching = ResetForecastService()
    ) {
        self.estimator = estimator
        self.forecastService = forecastService
    }

    var selectedWindow: APICostWindow {
        APICostWindow(rawValue: Defaults[.codexCostWindow]) ?? .today
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
        estimate = nil
        estimateError = nil
        forecast = nil
        forecastError = nil
    }

    func refresh() {
        guard refreshTask == nil else { return }
        let shouldEstimate = Defaults[.codexLocalCostEstimate]
        let shouldForecast = Defaults[.codexResetForecast]
        guard shouldEstimate || shouldForecast else {
            estimate = nil
            estimateError = nil
            forecast = nil
            forecastError = nil
            return
        }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if shouldEstimate {
                do {
                    estimate = try await estimator.estimate(
                        interval: selectedWindow.interval(endingAt: Date())
                    )
                    estimateError = nil
                } catch {
                    estimateError = error.localizedDescription
                }
            } else {
                estimate = nil
                estimateError = nil
            }

            if shouldForecast {
                do {
                    forecast = try await forecastService.fetchForecast()
                    forecastError = nil
                } catch {
                    forecastError = error.localizedDescription
                }
            } else {
                forecast = nil
                forecastError = nil
            }
            guard !Task.isCancelled else { return }
            isRefreshing = false
            refreshTask = nil
        }
    }

    func resetLocalCache() {
        Task {
            await estimator.resetCache()
            estimate = nil
            refresh()
        }
    }
}
