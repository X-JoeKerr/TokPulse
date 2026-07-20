import Foundation
import Testing
@testable import TokPulseCore

@Test
func scannerRejectsCopiedParentHistoryAndKeepsChildMetadata() {
    let result = scanFixture("copied-parent-child.jsonl")

    #expect(result.agents.count == 1)
    #expect(result.agents.first?.id == "019f7ee9-16f5-7ec1-b6e1-9562a4a2a952")
    #expect(result.agents.first?.sessionID == "019f7edc-ae93-7303-9d74-79c2ccee74db")
    #expect(result.agents.first?.parentAgentID == "019f7edc-ae93-7303-9d74-79c2ccee74db")
    #expect(result.agents.first?.kind == .subagent)
    #expect(result.agents.first?.name == "Maxwell")
    #expect(result.agents.first?.model == "gpt-test")
    #expect(result.samples.map(\.outputTokens) == [30, 40])
    #expect(result.samples.map(\.reasoningTokens) == [10, 5])
    #expect(result.activities.first?.state == .idle)
    #expect(result.diagnostics.contains { $0.code == .duplicateTokenSnapshot })

    let first = result.samples[0]
    let second = result.samples[1]
    #expect(abs(first.startedAt.timeIntervalSince(date("2026-07-20T09:44:30.994Z"))) < 0.001)
    #expect(abs(first.endedAt.timeIntervalSince(date("2026-07-20T09:44:40.274Z"))) < 0.001)
    #expect(abs(second.startedAt.timeIntervalSince(date("2026-07-20T09:44:41.000Z"))) < 0.001)
    #expect(abs(second.endedAt.timeIntervalSince(date("2026-07-20T09:44:45.000Z"))) < 0.001)
}

@Test
func scannerExcludesParallelToolWaitFromModelTime() {
    let result = scanFixture("parallel-tools.jsonl")

    #expect(result.samples.map(\.outputTokens) == [90, 60])
    #expect(result.samples.map(\.reasoningTokens) == [30, 10])
    #expect(abs(result.samples[0].endedAt.timeIntervalSince(result.samples[0].startedAt) - 4.07) < 0.001)
    #expect(abs(result.samples[1].endedAt.timeIntervalSince(result.samples[1].startedAt) - 4.0) < 0.001)
    #expect(abs(result.samples[1].startedAt.timeIntervalSince(date("2026-07-20T10:00:07.000Z"))) < 0.001)
    #expect(result.activities.first?.state == .idle)
}

@Test
func scannerReportsAnOpenModelTurnAsAnswering() {
    let result = scanFixture("active-answering.jsonl")
    let agentID = "019f7f57-ee00-7000-8000-000000000001"

    #expect(result.samples.isEmpty)
    #expect(result.activities.first?.state == .answering)
    #expect(result.answeringAgentIDs == [agentID])
}

@Test
func scannerDefaultInventoryExpiresFilesAfterThreeMinutes() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("TokPulseScannerTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let scanNow = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let recent = directory.appendingPathComponent("recent.jsonl")
    let stale = directory.appendingPathComponent("stale.jsonl")
    try fileManager.copyItem(at: fixtureURL("active-answering.jsonl"), to: recent)
    try fileManager.copyItem(at: fixtureURL("copied-parent-child.jsonl"), to: stale)
    try fileManager.setAttributes(
        [.modificationDate: scanNow.addingTimeInterval(-180)],
        ofItemAtPath: recent.path)
    try fileManager.setAttributes(
        [.modificationDate: scanNow.addingTimeInterval(-181)],
        ofItemAtPath: stale.path)

    #expect(CodexSessionScanner.defaultFileRecencyLimit == 3 * 60)
    let recentResult = CodexSessionScanner(roots: [directory]).scan(at: scanNow)
    #expect(recentResult.agents.map(\.id) == ["019f7f57-ee00-7000-8000-000000000001"])

    try fileManager.setAttributes(
        [.modificationDate: scanNow.addingTimeInterval(-181)],
        ofItemAtPath: recent.path)
    let expiredResult = CodexSessionScanner(roots: [directory]).scan(at: scanNow)
    #expect(expiredResult.agents.isEmpty)
}

private func scanFixture(_ name: String) -> CodexSessionScanResult {
    CodexSessionScanner(roots: [fixtureURL(name)], fileRecencyLimit: nil).scan()
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}
