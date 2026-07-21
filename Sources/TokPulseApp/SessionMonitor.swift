import Combine
import Foundation
import TokPulseCore

@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var metrics: DashboardMetrics
    @Published private(set) var answeringAgentCount = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var diagnosticCount = 0

    private let codexScanner: CodexSessionScanner
    private let qoderScanner: QoderSessionScanner
    private let engine: MetricEngine
    private let refreshInterval: Duration
    private var refreshLoop: Task<Void, Never>?

    init(
        codexScanner: CodexSessionScanner = CodexSessionScanner(),
        qoderScanner: QoderSessionScanner = QoderSessionScanner(),
        engine: MetricEngine = MetricEngine(),
        refreshInterval: Duration = .seconds(2)
    ) {
        self.codexScanner = codexScanner
        self.qoderScanner = qoderScanner
        self.engine = engine
        self.refreshInterval = refreshInterval
        self.metrics = .empty(at: Date(), windowSeconds: engine.window)
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
        let engine = self.engine
        let now = Date()
        let output = await Task.detached(priority: .utility) {
            let scan = SessionScanResult.merged(
                generatedAt: now,
                [codexScanner.scan(at: now), qoderScanner.scan(at: now)]
            )
            let metrics = engine.calculate(at: now, agents: scan.agents, samples: scan.samples)
            return (scan, metrics)
        }.value

        guard !Task.isCancelled else {
            isRefreshing = false
            return
        }
        metrics = output.1
        answeringAgentCount = output.0.answeringAgentIDs.count
        diagnosticCount = output.0.diagnostics.count
        isRefreshing = false
    }
}
