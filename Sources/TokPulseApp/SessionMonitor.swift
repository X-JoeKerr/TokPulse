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

    private let codexScanner: CodexSessionScanner
    private let qoderScanner: QoderSessionScanner
    private let dailyCodexScanner: CodexSessionScanner
    private let dailyQoderScanner: QoderSessionScanner
    private let engine: MetricEngine
    private let dailyEngine: DailyMetricEngine
    private let refreshInterval: Duration
    private let dailyRefreshInterval: TimeInterval
    private var refreshLoop: Task<Void, Never>?
    private var lastDailyRefreshAt: Date?

    init(
        codexScanner: CodexSessionScanner = CodexSessionScanner(),
        qoderScanner: QoderSessionScanner = QoderSessionScanner(),
        // Covers the longest local calendar day plus activity crossing midnight.
        dailyCodexScanner: CodexSessionScanner = CodexSessionScanner(
            fileRecencyLimit: 26 * 60 * 60
        ),
        dailyQoderScanner: QoderSessionScanner = QoderSessionScanner(
            fileRecencyLimit: 26 * 60 * 60
        ),
        engine: MetricEngine = MetricEngine(),
        dailyEngine: DailyMetricEngine = DailyMetricEngine(),
        refreshInterval: Duration = .seconds(2),
        dailyRefreshInterval: TimeInterval = 60
    ) {
        self.codexScanner = codexScanner
        self.qoderScanner = qoderScanner
        self.dailyCodexScanner = dailyCodexScanner
        self.dailyQoderScanner = dailyQoderScanner
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

        let codexScanner = self.codexScanner
        let qoderScanner = self.qoderScanner
        let dailyCodexScanner = self.dailyCodexScanner
        let dailyQoderScanner = self.dailyQoderScanner
        let engine = self.engine
        let dailyEngine = self.dailyEngine
        let now = Date()
        let shouldRefreshDaily = lastDailyRefreshAt.map {
            now.timeIntervalSince($0) >= dailyRefreshInterval
        } ?? true
        let output = await Task.detached(priority: .utility) {
            let scan = SessionScanResult.merged(
                generatedAt: now,
                [codexScanner.scan(at: now), qoderScanner.scan(at: now)]
            )
            let metrics = engine.calculate(at: now, agents: scan.agents, samples: scan.samples)
            guard shouldRefreshDaily else {
                return (scan, metrics, nil as DailyMetrics?)
            }

            let dailyScan = SessionScanResult.merged(
                generatedAt: now,
                [dailyCodexScanner.scan(at: now), dailyQoderScanner.scan(at: now)]
            )
            let dailyMetrics = dailyEngine.calculate(
                at: now,
                samples: dailyScan.samples,
                activities: scan.activities
            )
            return (scan, metrics, dailyMetrics)
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
