import Combine
import Foundation
import TokPulseCore

@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var metrics: DashboardMetrics
    @Published private(set) var dailyMetrics: DailyMetrics
    @Published private(set) var answeringAgentCount = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var diagnosticCount = 0

    private let telemetryStore: SessionTelemetryStore
    private let engine: MetricEngine
    private let dailyEngine: DailyMetricEngine
    private let refreshInterval: Duration
    private let dailyRefreshInterval: TimeInterval
    private var refreshLoop: Task<Void, Never>?
    private var lastDailyRefreshAt: Date?

    init(
        telemetryStore: SessionTelemetryStore = SessionTelemetryStore(),
        engine: MetricEngine = MetricEngine(),
        dailyEngine: DailyMetricEngine = DailyMetricEngine(),
        refreshInterval: Duration = .seconds(2),
        dailyRefreshInterval: TimeInterval = 60
    ) {
        self.telemetryStore = telemetryStore
        self.engine = engine
        self.dailyEngine = dailyEngine
        self.refreshInterval = refreshInterval
        self.dailyRefreshInterval = dailyRefreshInterval
        self.metrics = .empty(at: Date(), windowSeconds: engine.window)
        self.dailyMetrics = dailyEngine.empty(at: Date())
        start()
    }

    deinit {
        refreshLoop?.cancel()
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        Task { await refresh() }
    }

    private func start() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do {
                    try await Task.sleep(for: self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let telemetryStore = self.telemetryStore
        let engine = self.engine
        let dailyEngine = self.dailyEngine
        let now = Date()
        let shouldRefreshDaily = lastDailyRefreshAt.map {
            now.timeIntervalSince($0) >= dailyRefreshInterval
        } ?? true
        let output = await Task.detached(priority: .utility) {
            let telemetry = telemetryStore.refresh(
                at: now,
                includeRolling: shouldRefreshDaily
            )
            let live = telemetry.live
            let metrics = engine.calculate(
                at: now,
                agents: live.agents,
                samples: live.samples
            )
            guard shouldRefreshDaily, let rolling = telemetry.rolling else {
                return (live, metrics, nil as DailyMetrics?)
            }

            let dailyMetrics = dailyEngine.calculate(
                at: now,
                samples: rolling.samples,
                activities: live.activities
            )
            return (live, metrics, dailyMetrics)
        }.value

        guard !Task.isCancelled else {
            isRefreshing = false
            return
        }
        metrics = output.1
        answeringAgentCount = output.0.answeringAgentIDs.count
        diagnosticCount = output.0.diagnostics.count
        if let refreshedDailyMetrics = output.2 {
            dailyMetrics = refreshedDailyMetrics
            lastDailyRefreshAt = now
        }
        isRefreshing = false
    }
}
