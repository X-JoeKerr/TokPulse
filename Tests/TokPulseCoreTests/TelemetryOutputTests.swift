import Foundation
import Testing
@testable import TokPulseCore
@testable import TokPulseProtocol

@Test
func telemetryBackendBuildsTheCompleteCLIViewModel() throws {
    let now = Date(timeIntervalSince1970: 1_785_400_000)
    let agent = AgentDescriptor(
        id: "agent-1",
        sessionID: "session-1",
        kind: .root,
        name: "Main agent",
        startedAt: now.addingTimeInterval(-10)
    )
    let sample = GenerationSample(
        id: "sample-1",
        agentID: agent.id,
        startedAt: now.addingTimeInterval(-3),
        endedAt: now.addingTimeInterval(-1),
        outputTokens: 120
    )
    let activity = AgentActivity(
        agentID: agent.id,
        turnID: "turn-1",
        state: .answering,
        since: now.addingTimeInterval(-1)
    )
    let live = SessionScanResult(
        generatedAt: now,
        agents: [agent],
        samples: [sample],
        activities: [activity],
        diagnostics: []
    )
    let telemetry = SessionTelemetrySnapshot(live: live, rolling: live)
    let backend = TelemetryBackend { _, _ in telemetry }

    let output = backend.snapshot(at: now)

    #expect(output.schemaVersion == 1)
    #expect(output.metrics.activeAgentCount == 1)
    #expect(output.metrics.averageTPS == 60)
    #expect(output.dailyMetrics.outputTokens == 120)
    #expect(output.dailyMetrics.activeSeconds == 3)
    #expect(output.dailyMetrics.tokensPerSecond == 40)
    #expect(output.answeringAgentCount == 1)
    #expect(output.diagnosticCount == 0)

    let encoded = try TelemetryJSON.encode(output, prettyPrinted: false)
    #expect(try TelemetryJSON.decode(encoded) == output)
}

@Test
func telemetryOutputStreamDecoderHandlesChunksAndMalformedLines() throws {
    let now = Date(timeIntervalSince1970: 1_785_400_000)
    let output = TelemetryOutput(
        metrics: .empty(at: now, windowSeconds: 60),
        dailyMetrics: DailyMetricEngine().empty(at: now),
        answeringAgentCount: 0,
        diagnosticCount: 2
    )
    let line = try TelemetryJSON.encode(output, prettyPrinted: false) + Data([0x0A])
    let split = line.count / 2
    let decoder = TelemetryOutputStreamDecoder()

    #expect(decoder.append(Data(line[..<split])).isEmpty)
    #expect(decoder.append(Data(line[split...])) == [.output(output)])

    let malformedThenValid = Data("not-json\n".utf8) + line
    #expect(
        decoder.append(malformedThenValid)
            == [.malformedLine, .output(output)]
    )
}

@Test
func telemetryCLICommandParsesStableMachineReadableModes() throws {
    #expect(
        try TelemetryCLICommand.parse(["snapshot", "--json"])
            == .snapshot(prettyPrinted: false)
    )
    #expect(
        try TelemetryCLICommand.parse(["snapshot", "--json", "--pretty"])
            == .snapshot(prettyPrinted: true)
    )
    #expect(
        try TelemetryCLICommand.parse([
            "stream", "--json-lines", "--interval", "2",
        ]) == .stream(interval: 2)
    )
    #expect(throws: TelemetryCLIError.self) {
        try TelemetryCLICommand.parse(["stream", "--json-lines", "--interval", "0"])
    }
}
