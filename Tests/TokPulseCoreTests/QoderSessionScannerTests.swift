import Foundation
import Testing
@testable import TokPulseCore

@Test
func qoderScannerParsesMainCLISessionWithEstimatedTokens() {
    let result = scanQoderCLIFixture("qoder-cli-main.jsonl")

    let agent = result.agents.first
    #expect(result.agents.count == 1)
    #expect(agent?.id == "s-main")
    #expect(agent?.sessionID == "s-main")
    #expect(agent?.parentAgentID == nil)
    #expect(agent?.kind == .root)
    #expect(agent?.source == .qoderCLI)
    #expect(agent?.name == "Main agent")
    #expect(agent?.model == "gpt-q")
    #expect(agent?.workingDirectory == "/tmp/proj")

    // Sample 1: thinking "tttttttt" (2) + tool_use input {"command":"ls -la"} (5).
    // Sample 2: text of 16 ASCII characters (4) + two CJK characters (2).
    #expect(result.samples.map(\.outputTokens) == [7, 6])
    #expect(result.samples.map(\.reasoningTokens) == [2, 0])
    #expect(result.samples.allSatisfy { $0.tokenQuality == .estimated })

    let first = result.samples[0]
    let second = result.samples[1]
    #expect(abs(first.startedAt.timeIntervalSince(isoDate("2026-07-21T03:00:00.000Z"))) < 0.001)
    #expect(abs(first.endedAt.timeIntervalSince(isoDate("2026-07-21T03:00:10.000Z"))) < 0.001)
    #expect(abs(second.startedAt.timeIntervalSince(isoDate("2026-07-21T03:00:15.000Z"))) < 0.001)
    #expect(abs(second.endedAt.timeIntervalSince(isoDate("2026-07-21T03:00:19.000Z"))) < 0.001)

    #expect(result.activities.first?.state == .idle)
    #expect(result.answeringAgentIDs.isEmpty)
}

@Test
func qoderScannerReportsSubagentAwaitingNextResponseAsAnswering() {
    let result = scanQoderCLIFixture("qoder-cli-subagent.jsonl")

    let agent = result.agents.first
    #expect(agent?.id == "aExplore-abc123")
    #expect(agent?.sessionID == "s-parent")
    #expect(agent?.parentAgentID == "s-parent")
    #expect(agent?.kind == .subagent)
    #expect(agent?.source == .qoderCLI)
    #expect(agent?.name == "aExplore")

    // tool_use input {"p":"x"} is nine ASCII characters.
    #expect(result.samples.map(\.outputTokens) == [3])
    #expect(result.activities.first?.state == .answering)
    #expect(result.answeringAgentIDs == ["aExplore-abc123"])
}

@Test
func qoderScannerParsesQuestSessionWithCompanionMetadata() {
    let result = scanQoderQuestFixture("task-fixture.session.execution.jsonl")

    let agent = result.agents.first
    #expect(result.agents.count == 1)
    #expect(agent?.id == "task-fixture.session.execution")
    #expect(agent?.kind == .root)
    #expect(agent?.source == .qoderQuest)
    #expect(agent?.name == "Fixture quest")
    #expect(agent?.model == "auto")
    #expect(agent?.workingDirectory == "/tmp/quest")

    // Sample 1: reasoning "rrrrrrrr" (2) + tool_call input {"file":"a"} (3).
    // Sample 2: text of 12 ASCII characters (3).
    #expect(result.samples.map(\.outputTokens) == [5, 3])
    #expect(result.samples.map(\.reasoningTokens) == [2, 0])

    let first = result.samples[0]
    let second = result.samples[1]
    #expect(abs(first.startedAt.timeIntervalSince1970 - 1_784_610_000) < 0.001)
    #expect(abs(first.endedAt.timeIntervalSince1970 - 1_784_610_008) < 0.001)
    #expect(abs(second.startedAt.timeIntervalSince1970 - 1_784_610_009) < 0.001)
    #expect(abs(second.endedAt.timeIntervalSince1970 - 1_784_610_013) < 0.001)

    #expect(result.activities.first?.state == .idle)
}

@Test
func qoderScannerReportsUnresolvedQuestToolCallAsWaiting() {
    let result = scanQoderQuestFixture("task-waiting.session.execution.jsonl")

    #expect(result.agents.first?.name == "Quest")
    #expect(result.agents.first?.workingDirectory == nil)
    #expect(result.activities.first?.state == .waitingOnTool)
    #expect(result.samples.count == 1)
}

@Test
func qoderScannerDefaultInventoryExpiresFilesAfterThreeMinutes() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("TokPulseQoderScannerTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let scanNow = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let recent = directory.appendingPathComponent("recent.jsonl")
    let stale = directory.appendingPathComponent("stale.jsonl")
    try fileManager.copyItem(at: qoderFixtureURL("qoder-cli-main.jsonl"), to: recent)
    try fileManager.copyItem(at: qoderFixtureURL("qoder-cli-subagent.jsonl"), to: stale)
    try fileManager.setAttributes(
        [.modificationDate: scanNow.addingTimeInterval(-180)],
        ofItemAtPath: recent.path)
    try fileManager.setAttributes(
        [.modificationDate: scanNow.addingTimeInterval(-181)],
        ofItemAtPath: stale.path)

    #expect(QoderSessionScanner.defaultFileRecencyLimit == 3 * 60)
    let result = QoderSessionScanner(cliRoots: [directory], questRoots: []).scan(at: scanNow)
    #expect(result.agents.map(\.id) == ["s-main"])
}

private func scanQoderCLIFixture(_ name: String) -> SessionScanResult {
    QoderSessionScanner(
        cliRoots: [qoderFixtureURL(name)],
        questRoots: [],
        fileRecencyLimit: nil
    ).scan()
}

private func scanQoderQuestFixture(_ name: String) -> SessionScanResult {
    QoderSessionScanner(
        cliRoots: [],
        questRoots: [qoderFixtureURL(name)],
        fileRecencyLimit: nil
    ).scan()
}

private func qoderFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}
