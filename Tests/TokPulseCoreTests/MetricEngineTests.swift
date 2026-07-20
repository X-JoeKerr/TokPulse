import Foundation
import Testing
@testable import TokPulseCore

private let now = Date(timeIntervalSince1970: 10_000)

@Test
func excludesIdleTimeBetweenModelResponses() {
    let agent = rootAgent("root")
    let samples = [
        sample("a", agent: agent.id, start: -550, duration: 2, tokens: 20),
        sample("b", agent: agent.id, start: -10, duration: 2, tokens: 30),
    ]

    let metrics = MetricEngine().calculate(at: now, agents: [agent], samples: samples)

    #expect(metrics.sessions[0].agents[0].activeSeconds == 4)
    #expect(metrics.sessions[0].agents[0].averageTPS == 12.5)
}

@Test
func excludesSamplesOutsideTenMinuteWindow() {
    let agent = rootAgent("root")
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [sample("old", agent: agent.id, start: -700, duration: 10, tokens: 100)]
    )

    #expect(metrics.activeAgentCount == 0)
    #expect(metrics.sessions.isEmpty)
}

@Test
func proratesSampleThatCrossesWindowBoundary() {
    let agent = rootAgent("root")
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [sample("crossing", agent: agent.id, start: -610, duration: 20, tokens: 200)]
    )

    let agentMetrics = metrics.sessions[0].agents[0]
    #expect(agentMetrics.outputTokens == 100)
    #expect(agentMetrics.activeSeconds == 10)
    #expect(agentMetrics.averageTPS == 10)
    #expect(agentMetrics.isEstimated)
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
}

@Test
func averageIsActivityWeightedAndTotalUsesWallClockUnion() {
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

    #expect(abs(metrics.averageTPS - (200.0 / 11.0)) < 0.000_001)
    #expect(metrics.totalTPS == 20)
}

@Test
func ignoresInvalidAndUnknownSamples() {
    let agent = rootAgent("root")
    let metrics = MetricEngine().calculate(
        at: now,
        agents: [agent],
        samples: [
            sample("zero", agent: agent.id, start: -10, duration: 0, tokens: 100),
            sample("unknown", agent: "missing", start: -10, duration: 1, tokens: 100),
        ]
    )

    #expect(metrics.activeAgentCount == 0)
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
