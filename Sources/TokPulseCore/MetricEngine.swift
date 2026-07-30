import Foundation
import TokPulseProtocol

public struct MetricEngine: Sendable {
    public static let defaultWindow: TimeInterval = 60

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
        var latestSamples: [String: GenerationSample] = [:]

        for sample in samples {
            guard descriptorsByID[sample.agentID] != nil,
                  sample.outputTokens >= 0,
                  sample.reasoningTokens >= 0,
                  sample.endedAt > sample.startedAt,
                  sample.endedAt >= cutoff,
                  sample.endedAt <= now
            else {
                continue
            }

            if let current = latestSamples[sample.agentID], !isLater(sample, than: current) {
                continue
            }
            latestSamples[sample.agentID] = sample
        }

        let agentMetrics = descriptorsByID.compactMap { agentID, descriptor -> AgentMetrics? in
            guard let sample = latestSamples[agentID] else {
                guard descriptor.kind == .root else { return nil }
                return AgentMetrics(
                    id: agentID,
                    descriptor: descriptor,
                    outputTokens: 0,
                    reasoningTokens: 0,
                    activeSeconds: 0,
                    averageTPS: 0,
                    sampleCount: 0,
                    isEstimated: false
                )
            }
            let activeSeconds = sample.endedAt.timeIntervalSince(sample.startedAt)
            return AgentMetrics(
                id: agentID,
                descriptor: descriptor,
                outputTokens: Double(sample.outputTokens),
                reasoningTokens: Double(sample.reasoningTokens),
                activeSeconds: activeSeconds,
                averageTPS: Double(sample.outputTokens) / activeSeconds,
                sampleCount: 1,
                isEstimated: sample.tokenQuality == .estimated || sample.timingQuality == .inferred
            )
        }

        let grouped = Dictionary(grouping: agentMetrics, by: { $0.descriptor.sessionID })
        let sessions = grouped.map { sessionID, metrics in
            let sortedAgents = metrics.sorted(by: agentSort)
            let freshMetrics = sortedAgents.filter(\.hasFreshSample)
            let outputTokens = freshMetrics.reduce(0) { $0 + $1.outputTokens }
            let activeSeconds = freshMetrics.reduce(0) { $0 + $1.activeSeconds }
            let totalTPS = freshMetrics.reduce(0) { $0 + $1.averageTPS }
            return SessionMetrics(
                id: sessionID,
                agents: sortedAgents,
                averageTPS: freshMetrics.isEmpty ? 0 : totalTPS / Double(freshMetrics.count),
                totalTPS: totalTPS,
                outputTokens: outputTokens,
                activeSeconds: activeSeconds,
                isEstimated: freshMetrics.contains(where: \.isEstimated)
            )
        }
        .sorted(by: sessionSort)

        guard !agentMetrics.isEmpty else {
            return .empty(at: now, windowSeconds: window)
        }

        let freshAgentMetrics = agentMetrics.filter(\.hasFreshSample)
        let outputTokens = freshAgentMetrics.reduce(0) { $0 + $1.outputTokens }
        let activeSeconds = freshAgentMetrics.reduce(0) { $0 + $1.activeSeconds }
        let totalTPS = sessions.reduce(0) { $0 + $1.totalTPS }
        return DashboardMetrics(
            generatedAt: now,
            windowSeconds: window,
            sessions: sessions,
            averageTPS: freshAgentMetrics.isEmpty ? 0 : totalTPS / Double(freshAgentMetrics.count),
            totalTPS: totalTPS,
            outputTokens: outputTokens,
            activeSeconds: activeSeconds,
            activeAgentCount: freshAgentMetrics.count,
            isEstimated: freshAgentMetrics.contains(where: \.isEstimated)
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

    private func isLater(_ candidate: GenerationSample, than current: GenerationSample) -> Bool {
        if candidate.endedAt != current.endedAt {
            return candidate.endedAt > current.endedAt
        }
        if candidate.startedAt != current.startedAt {
            return candidate.startedAt > current.startedAt
        }
        return candidate.id > current.id
    }
}
