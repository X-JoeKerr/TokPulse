import Foundation
import Testing
@testable import TokPulseCore
import TokPulseProtocol

private let now = Date(timeIntervalSince1970: 10_000)

@Test
func usesLatestCompletedSampleWithinOneMinute() {
    let agent = rootAgent("root")
    let samples = [
        sample("older", agent: agent.id, start: -50, duration: 10, tokens: 200),
        sample("latest", agent: agent.id, start: -35, duration: 30, tokens: 1_000),
    ]

    let metrics = MetricEngine().calculate(at: now, agents: [agent], samples: samples)

    let agentMetrics = metrics.sessions[0].agents[0]
    #expect(metrics.windowSeconds == 60)
    #expect(agentMetrics.outputTokens == 1_000)
    #expect(agentMetrics.activeSeconds == 30)
    #expect(agentMetrics.averageTPS == 1_000.0 / 30.0)
    #expect(agentMetrics.sampleCount == 1)
}

@Test
func keepsRootAgentUnavailableWhenItHasNoSampleWithinOneMinute() {
    let agent = rootAgent("root")
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [sample("old", agent: agent.id, start: -71, duration: 10, tokens: 100)]
    )

    #expect(metrics.activeAgentCount == 0)
    #expect(metrics.sessions.count == 1)
    #expect(metrics.sessions[0].agents.count == 1)
    #expect(!metrics.sessions[0].agents[0].hasFreshSample)
    #expect(metrics.sessions[0].agents[0].sampleCount == 0)
    #expect(metrics.averageTPS == 0)
    #expect(metrics.totalTPS == 0)
}

@Test
func includesSubagentSampleEndingExactlyOneMinuteAgo() {
    let agent = AgentDescriptor(
        id: "child",
        sessionID: "session",
        parentAgentID: "root",
        kind: .subagent,
        name: "explorer",
        startedAt: now.addingTimeInterval(-100)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [sample("boundary", agent: agent.id, start: -70, duration: 10, tokens: 100)]
    )

    #expect(metrics.activeAgentCount == 1)
    #expect(metrics.sessions[0].agents[0].averageTPS == 10)
}

@Test
func doesNotProrateSampleThatStartsBeforeOneMinuteBoundary() {
    let agent = rootAgent("root")
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [sample("crossing", agent: agent.id, start: -90, duration: 40, tokens: 200)]
    )

    let agentMetrics = metrics.sessions[0].agents[0]
    #expect(agentMetrics.outputTokens == 200)
    #expect(agentMetrics.activeSeconds == 40)
    #expect(agentMetrics.averageTPS == 5)
    #expect(!agentMetrics.isEstimated)
}

@Test
func includesSubagentsInSessionAndGlobalMetrics() {
    let root = rootAgent("root")
    let child = AgentDescriptor(
        id: "child",
        sessionID: root.sessionID,
        parentAgentID: root.id,
        kind: .subagent,
        name: "explorer",
        startedAt: now.addingTimeInterval(-100)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [root, child],
        samples: [
            sample("root-sample", agent: root.id, start: -20, duration: 2, tokens: 20),
            sample("child-sample", agent: child.id, start: -20, duration: 2, tokens: 40),
        ]
    )

    #expect(metrics.sessions.count == 1)
    #expect(metrics.sessions[0].agents.map(\.descriptor.kind) == [.root, .subagent])
    #expect(metrics.averageTPS == 15)
    #expect(metrics.totalTPS == 30)
}

@Test
func keepsUnavailableRootAlongsideFreshSubagent() {
    let root = rootAgent("root")
    let child = AgentDescriptor(
        id: "child",
        sessionID: root.sessionID,
        parentAgentID: root.id,
        kind: .subagent,
        name: "explorer",
        startedAt: now.addingTimeInterval(-100)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [root, child],
        samples: [sample("child-sample", agent: child.id, start: -20, duration: 2, tokens: 40)]
    )

    #expect(metrics.sessions[0].agents.map(\.id) == [root.id, child.id])
    #expect(metrics.sessions[0].agents[0].hasFreshSample == false)
    #expect(metrics.sessions[0].agents[1].hasFreshSample)
    #expect(metrics.activeAgentCount == 1)
    #expect(metrics.averageTPS == 20)
    #expect(metrics.totalTPS == 20)
    #expect(metrics.sessions[0].averageTPS == 20)
    #expect(metrics.sessions[0].totalTPS == 20)
}

@Test
func removesUnavailableSubagentWithoutChangingAggregates() {
    let root = rootAgent("root")
    let child = AgentDescriptor(
        id: "child",
        sessionID: root.sessionID,
        parentAgentID: root.id,
        kind: .subagent,
        name: "explorer",
        startedAt: now.addingTimeInterval(-100)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [root, child],
        samples: [sample("root-sample", agent: root.id, start: -20, duration: 2, tokens: 20)]
    )

    #expect(metrics.activeAgentCount == 1)
    #expect(metrics.sessions[0].activeAgentCount == 1)
    #expect(metrics.sessions[0].agents.map(\.id) == [root.id])
    #expect(metrics.averageTPS == 10)
    #expect(metrics.totalTPS == 10)
    #expect(metrics.sessions[0].averageTPS == 10)
    #expect(metrics.sessions[0].totalTPS == 10)
}

@Test
func removesSessionWhenItsOnlySubagentHasNoFreshSample() {
    let child = AgentDescriptor(
        id: "child",
        sessionID: "session",
        parentAgentID: "root",
        kind: .subagent,
        name: "explorer",
        startedAt: now.addingTimeInterval(-100)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [child],
        samples: [sample("old-child", agent: child.id, start: -71, duration: 10, tokens: 100)]
    )

    #expect(metrics.activeAgentCount == 0)
    #expect(metrics.sessions.isEmpty)
}

@Test
func groupsIndependentRootSessions() {
    let first = rootAgent("first")
    let second = AgentDescriptor(
        id: "second",
        sessionID: "second-session",
        kind: .root,
        name: "Main agent",
        startedAt: now.addingTimeInterval(-50)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [first, second],
        samples: [
            sample("first-sample", agent: first.id, start: -10, duration: 1, tokens: 8),
            sample("second-sample", agent: second.id, start: -10, duration: 1, tokens: 12),
        ]
    )

    #expect(metrics.sessions.count == 2)
    #expect(metrics.averageTPS == 10)
    #expect(metrics.totalTPS == 20)
    #expect(metrics.sessions.reduce(0) { $0 + $1.totalTPS } == metrics.totalTPS)
}

@Test
func averageIsArithmeticMeanAndTotalIsSumOfLatestAgentRates() {
    let slow = rootAgent("slow")
    let fast = AgentDescriptor(
        id: "fast",
        sessionID: "fast-session",
        kind: .root,
        name: "Main agent",
        startedAt: now.addingTimeInterval(-50)
    )
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [slow, fast],
        samples: [
            sample("slow-sample", agent: slow.id, start: -20, duration: 10, tokens: 100),
            sample("fast-sample", agent: fast.id, start: -15, duration: 1, tokens: 100),
        ]
    )

    #expect(metrics.averageTPS == 55)
    #expect(metrics.totalTPS == 110)
}

@Test
func ignoresInvalidUnknownAndFutureSamples() {
    let agent = rootAgent("root")
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [
            sample("zero", agent: agent.id, start: -10, duration: 0, tokens: 100),
            sample("negative", agent: agent.id, start: -10, duration: 1, tokens: -1),
            sample("future", agent: agent.id, start: 1, duration: 1, tokens: 100),
            sample("unknown", agent: "missing", start: -10, duration: 1, tokens: 100),
        ]
    )

    #expect(metrics.activeAgentCount == 0)
    #expect(metrics.sessions[0].agents[0].hasFreshSample == false)
}

private func rootAgent(_ id: String) -> AgentDescriptor {
    AgentDescriptor(
        id: id,
        sessionID: "session",
        kind: .root,
        name: "Main agent",
        startedAt: now.addingTimeInterval(-500)
    )
}

private func sample(
    _ id: String,
    agent: String,
    start: TimeInterval,
    duration: TimeInterval,
    tokens: Int
) -> GenerationSample {
    GenerationSample(
        id: id,
        agentID: agent,
        startedAt: now.addingTimeInterval(start),
        endedAt: now.addingTimeInterval(start + duration),
        outputTokens: tokens,
        timingQuality: .observed
    )
}
