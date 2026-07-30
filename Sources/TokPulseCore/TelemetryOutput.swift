import Foundation
import TokPulseProtocol

/// Owns the telemetry cache and all metric calculation used by CLI commands.
public final class TelemetryBackend: @unchecked Sendable {
    public static let defaultDailyRefreshInterval: TimeInterval = 60

    private let lock = NSLock()
    private let refreshTelemetry: @Sendable (
        _ now: Date,
        _ includeRolling: Bool
    ) -> SessionTelemetrySnapshot
    private let metricEngine: MetricEngine
    private let dailyMetricEngine: DailyMetricEngine
    private let dailyRefreshInterval: TimeInterval
    private var cachedDailyMetrics: DailyMetrics?
    private var lastDailyRefreshAt: Date?

    public convenience init(
        store: SessionTelemetryStore = SessionTelemetryStore(),
        metricEngine: MetricEngine = MetricEngine(),
        dailyMetricEngine: DailyMetricEngine = DailyMetricEngine(),
        dailyRefreshInterval: TimeInterval = TelemetryBackend.defaultDailyRefreshInterval
    ) {
        self.init(
            refreshTelemetry: { now, includeRolling in
                store.refresh(at: now, includeRolling: includeRolling)
            },
            metricEngine: metricEngine,
            dailyMetricEngine: dailyMetricEngine,
            dailyRefreshInterval: dailyRefreshInterval
        )
    }

    init(
        refreshTelemetry: @escaping @Sendable (
            _ now: Date,
            _ includeRolling: Bool
        ) -> SessionTelemetrySnapshot,
        metricEngine: MetricEngine = MetricEngine(),
        dailyMetricEngine: DailyMetricEngine = DailyMetricEngine(),
        dailyRefreshInterval: TimeInterval = TelemetryBackend.defaultDailyRefreshInterval
    ) {
        self.refreshTelemetry = refreshTelemetry
        self.metricEngine = metricEngine
        self.dailyMetricEngine = dailyMetricEngine
        self.dailyRefreshInterval = dailyRefreshInterval
    }

    public func snapshot(at now: Date = Date()) -> TelemetryOutput {
        lock.lock()
        defer { lock.unlock() }

        let shouldRefreshDaily = lastDailyRefreshAt.map {
            now.timeIntervalSince($0) >= dailyRefreshInterval
        } ?? true
        let telemetry = refreshTelemetry(now, shouldRefreshDaily)
        let live = telemetry.live
        let metrics = metricEngine.calculate(
            at: now,
            agents: live.agents,
            samples: live.samples
        )

        if shouldRefreshDaily, let rolling = telemetry.rolling {
            cachedDailyMetrics = dailyMetricEngine.calculate(
                at: now,
                samples: rolling.samples,
                activities: live.activities
            )
            lastDailyRefreshAt = now
        }
        let dailyMetrics = cachedDailyMetrics ?? dailyMetricEngine.empty(at: now)
        return TelemetryOutput(
            metrics: metrics,
            dailyMetrics: dailyMetrics,
            answeringAgentCount: live.answeringAgentIDs.count,
            diagnosticCount: live.diagnostics.count
        )
    }
}
