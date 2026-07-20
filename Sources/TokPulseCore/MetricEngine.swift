import Foundation

public struct MetricEngine: Sendable {
    public static let defaultWindow: TimeInterval = 10 * 60

    public let window: TimeInterval

    public init(window: TimeInterval = Self.defaultWindow) {
        self.window = window
    }

    public func calculate(
        at now: Date,
        agents: [AgentDescriptor],
        samples: [GenerationSample]
    ) -> DashboardMetrics {
        guard window > 0 else {
            return .empty(at: now, windowSeconds: window)
        }

        let descriptorsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let cutoff = now.addingTimeInterval(-window)
        var accumulators: [String: AgentAccumulator] = [:]

        for sample in samples {
            guard descriptorsByID[sample.agentID] != nil,
                  sample.outputTokens >= 0,
                  sample.reasoningTokens >= 0,
                  sample.endedAt > sample.startedAt
            else {
                continue
            }

            let overlapStart = max(sample.startedAt, cutoff)
            let overlapEnd = min(sample.endedAt, now)
            guard overlapEnd > overlapStart else {
                continue
            }

            let fullDuration = sample.endedAt.timeIntervalSince(sample.startedAt)
            let overlapDuration = overlapEnd.timeIntervalSince(overlapStart)
            let overlapRatio = overlapDuration / fullDuration
            var accumulator = accumulators[sample.agentID, default: AgentAccumulator()]
            accumulator.outputTokens += Double(sample.outputTokens) * overlapRatio
            accumulator.reasoningTokens += Double(sample.reasoningTokens) * overlapRatio
            accumulator.intervals.append(DateInterval(start: overlapStart, end: overlapEnd))
            accumulator.sampleCount += 1
            accumulator.isEstimated = accumulator.isEstimated
                || sample.tokenQuality == .estimated
                || sample.timingQuality == .inferred
                || overlapRatio < 1
            accumulators[sample.agentID] = accumulator
        }

        let agentMetrics = accumulators.compactMap { agentID, accumulator -> AgentMetrics? in
            let activeSeconds = unionDuration(accumulator.intervals)
            guard let descriptor = descriptorsByID[agentID], activeSeconds > 0 else {
                return nil
            }
            return AgentMetrics(
                id: agentID,
                descriptor: descriptor,
                outputTokens: accumulator.outputTokens,
                reasoningTokens: accumulator.reasoningTokens,
                activeSeconds: activeSeconds,
                averageTPS: accumulator.outputTokens / activeSeconds,
                sampleCount: accumulator.sampleCount,
                isEstimated: accumulator.isEstimated
            )
        }

        let grouped = Dictionary(grouping: agentMetrics, by: { $0.descriptor.sessionID })
        let sessions = grouped.map { sessionID, metrics in
            let sortedAgents = metrics.sorted(by: agentSort)
            let outputTokens = metrics.reduce(0) { $0 + $1.outputTokens }
            let activeSeconds = metrics.reduce(0) { $0 + $1.activeSeconds }
            let wallActiveSeconds = unionDuration(
                metrics.flatMap { accumulators[$0.id]?.intervals ?? [] }
            )
            return SessionMetrics(
                id: sessionID,
                agents: sortedAgents,
                averageTPS: outputTokens / activeSeconds,
                totalTPS: outputTokens / wallActiveSeconds,
                outputTokens: outputTokens,
                activeSeconds: activeSeconds,
                isEstimated: metrics.contains(where: \.isEstimated)
            )
        }
        .sorted(by: sessionSort)

        guard !agentMetrics.isEmpty else {
            return .empty(at: now, windowSeconds: window)
        }

        let outputTokens = agentMetrics.reduce(0) { $0 + $1.outputTokens }
        let activeSeconds = agentMetrics.reduce(0) { $0 + $1.activeSeconds }
        let wallActiveSeconds = unionDuration(accumulators.values.flatMap(\.intervals))
        return DashboardMetrics(
            generatedAt: now,
            windowSeconds: window,
            sessions: sessions,
            averageTPS: outputTokens / activeSeconds,
            totalTPS: outputTokens / wallActiveSeconds,
            outputTokens: outputTokens,
            activeSeconds: activeSeconds,
            activeAgentCount: agentMetrics.count,
            isEstimated: agentMetrics.contains(where: \.isEstimated)
        )
    }

    private func agentSort(_ lhs: AgentMetrics, _ rhs: AgentMetrics) -> Bool {
        if lhs.descriptor.kind != rhs.descriptor.kind {
            return lhs.descriptor.kind == .root
        }
        if lhs.descriptor.startedAt != rhs.descriptor.startedAt {
            return lhs.descriptor.startedAt < rhs.descriptor.startedAt
        }
        return lhs.id < rhs.id
    }

    private func sessionSort(_ lhs: SessionMetrics, _ rhs: SessionMetrics) -> Bool {
        let lhsStart = lhs.agents.map(\.descriptor.startedAt).min() ?? .distantPast
        let rhsStart = rhs.agents.map(\.descriptor.startedAt).min() ?? .distantPast
        if lhsStart != rhsStart {
            return lhsStart > rhsStart
        }
        return lhs.id < rhs.id
    }

    private func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else {
            return 0
        }

        var duration: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                duration += current.duration
                current = interval
            }
        }
        return duration + current.duration
    }
}

private struct AgentAccumulator {
    var outputTokens: Double = 0
    var reasoningTokens: Double = 0
    var intervals: [DateInterval] = []
    var sampleCount = 0
    var isEstimated = false
}
