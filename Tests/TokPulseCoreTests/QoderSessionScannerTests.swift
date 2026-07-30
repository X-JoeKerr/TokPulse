import Foundation
import Testing
@testable import TokPulseCore
import TokPulseProtocol

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
func qoderScannerDoesNotCommitCLIResponseUntilTerminalBlockArrives() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("TokPulseQoderIncrementalTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let file = directory.appendingPathComponent("incremental.jsonl")
    let prefix = """
    {"type":"runtime-config","sessionId":"s-incremental","model":"gpt-q","timestamp":1784601500000}
    {"type":"user","timestamp":"2026-07-21T03:00:00.000Z","message":{"role":"user","content":"hello"},"isSidechain":false,"cwd":"/tmp/proj","sessionId":"s-incremental"}
    {"type":"assistant","timestamp":"2026-07-21T03:00:05.000Z","message":{"role":"assistant","model":"gpt-q","content":[{"type":"thinking","thinking":"tttttttt"}]},"isSidechain":false,"cwd":"/tmp/proj","sessionId":"s-incremental"}
    """ + "\n"
    try Data(prefix.utf8).write(to: file)

    let scanner = QoderSessionScanner(
        cliRoots: [directory],
        questRoots: [],
        fileRecencyLimit: nil
    )
    let incomplete = scanner.scan()

    #expect(incomplete.samples.isEmpty)
    #expect(incomplete.activities.first?.state == .answering)

    let terminal = """
    {"type":"assistant","timestamp":"2026-07-21T03:00:07.000Z","message":{"role":"assistant","model":"gpt-q","content":[{"type":"text","text":"aaaabbbb"}]},"isSidechain":false,"cwd":"/tmp/proj","sessionId":"s-incremental"}
    """ + "\n"
    try Data((prefix + terminal).utf8).write(to: file)

    let complete = scanner.scan()

    // Existing estimator: 8 ASCII thinking chars (2) + 8 ASCII text chars (2).
    #expect(complete.samples.map(\.outputTokens) == [4])
    #expect(complete.samples.map(\.reasoningTokens) == [2])
    #expect(complete.activities.first?.state == .idle)
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

@Test
func qoderScannerReadsOnlyAppendedBytesAndMatchesAColdParse() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("TokPulseQoderAppendParityTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let source = try Data(contentsOf: qoderFixtureURL("qoder-cli-main.jsonl"))
    let split = source.index(after: source[..<(source.count / 2)].lastIndex(of: 0x0A)!)
    let file = directory.appendingPathComponent("qoder-cli-main.jsonl")
    try Data(source[..<split]).write(to: file)

    let scanner = QoderSessionScanner(
        cliRoots: [directory],
        questRoots: [],
        fileRecencyLimit: nil
    )
    _ = scanner.scan()
    try appendQoderData(Data(source[split...]), to: file)
    let incremental = scanner.refresh(changedFiles: [file])
    let cold = scanQoderCLIFixture("qoder-cli-main.jsonl")

    #expect(incremental.agents == cold.agents)
    #expect(incremental.samples == cold.samples)
    #expect(incremental.activities == cold.activities)
    #expect(incremental.diagnostics.map(\.code) == cold.diagnostics.map(\.code))
    #expect(scanner.statistics.bytesRead == Int64(source.count))
    #expect(scanner.statistics.inventoryPasses == 1)
}

@Test
func qoderScannerResetsParserAfterTruncation() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("TokPulseQoderTruncationTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let original = try Data(contentsOf: qoderFixtureURL("qoder-cli-main.jsonl"))
    let replacement = try Data(contentsOf: qoderFixtureURL("qoder-cli-subagent.jsonl"))
    let file = directory.appendingPathComponent("reused.jsonl")
    try original.write(to: file)
    let scanner = QoderSessionScanner(
        cliRoots: [directory],
        questRoots: [],
        fileRecencyLimit: nil
    )
    _ = scanner.scan()

    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: replacement)
    try handle.close()

    let refreshed = scanner.refresh(changedFiles: [file])
    #expect(refreshed.agents.map(\.id) == ["aExplore-abc123"])
    #expect(scanner.statistics.parserResets == 1)
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

private func appendQoderData(_ data: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
}
