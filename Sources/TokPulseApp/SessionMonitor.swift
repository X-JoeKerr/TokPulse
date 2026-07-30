import Combine
import Foundation
import TokPulseProtocol

@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var metrics: DashboardMetrics
    @Published private(set) var dailyMetrics: DailyMetrics
    @Published private(set) var answeringAgentCount = 0
    @Published private(set) var diagnosticCount = 0

    private let client: TelemetryCLIClient

    init(
        client: TelemetryCLIClient = TelemetryCLIClient()
    ) {
        let now = Date()
        self.client = client
        self.metrics = .empty(at: now, windowSeconds: 60)
        self.dailyMetrics = DailyMetrics(
            generatedAt: now,
            dayStartedAt: Calendar.autoupdatingCurrent.startOfDay(for: now),
            outputTokens: 0,
            activeSeconds: 0,
            tokensPerSecond: 0
        )
        start()
    }

    func stop() {
        client.stop()
    }

    private func start() {
        client.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event)
            }
        }
    }

    private func consume(_ event: TelemetryCLIClient.Event) {
        guard case .output(let output) = event,
              output.schemaVersion == TelemetryOutput.currentSchemaVersion
        else {
            return
        }
        metrics = output.metrics
        dailyMetrics = output.dailyMetrics
        answeringAgentCount = output.answeringAgentCount
        diagnosticCount = output.diagnosticCount
    }
}
