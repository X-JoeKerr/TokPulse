import Foundation

public enum CodexAgentActivityState: String, Hashable, Sendable {
    case answering
    case waitingOnTool
    case idle
    case unknown
}

public struct CodexAgentActivity: Hashable, Sendable {
    public let agentID: String
    public let turnID: String?
    public let state: CodexAgentActivityState
    public let since: Date?

    public var isAnswering: Bool {
        state == .answering
    }
}

public enum CodexSessionDiagnosticCode: String, Hashable, Sendable {
    case rootUnavailable
    case fileMetadataUnavailable
    case fileReadFailed
    case malformedJSON
    case missingSessionMetadata
    case missingThreadID
    case ambiguousTurnOwnership
    case overlappingTurns
    case unmatchedToolOutput
    case unresolvedToolCalls
    case duplicateTokenSnapshot
    case missingTokenUsage
    case missingModelInterval
    case nonMonotonicTokenTotal
}

public struct CodexSessionDiagnostic: Hashable, Sendable {
    public let code: CodexSessionDiagnosticCode
    public let filePath: String
    public let line: Int?
    public let message: String
}

public struct CodexSessionScanResult: Hashable, Sendable {
    public let generatedAt: Date
    public let agents: [AgentDescriptor]
    public let samples: [GenerationSample]
    public let activities: [CodexAgentActivity]
    public let diagnostics: [CodexSessionDiagnostic]

    public var answeringAgentIDs: Set<String> {
        Set(activities.lazy.filter(\.isAnswering).map(\.agentID))
    }
}

/// Reads Codex rollout JSONL without retaining prompts, messages, or tool output.
///
/// A scanner instance caches complete per-file parse results by modification date
/// and size. It intentionally does not watch the filesystem; callers can rescan on
/// a modest timer and unchanged files are cheap.
public final class CodexSessionScanner: @unchecked Sendable {
    public static let defaultFileRecencyLimit: TimeInterval = 3 * 60

    public static var defaultRoots: [URL] {
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        return [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    public let roots: [URL]
    public let fileRecencyLimit: TimeInterval?

    private let lock = NSLock()
    private var cache: [String: CachedFile] = [:]

    /// - Parameters:
    ///   - roots: JSONL files or directories containing Codex rollout files.
    ///   - fileRecencyLimit: Ignore files whose mtime is older than this many
    ///     seconds. The default keeps Main/Root Agent rows for up to three
    ///     minutes even though live rate samples expire sooner. Pass `nil` for a
    ///     full historical scan.
    public init(
        roots: [URL] = CodexSessionScanner.defaultRoots,
        fileRecencyLimit: TimeInterval? = CodexSessionScanner.defaultFileRecencyLimit
    ) {
        self.roots = roots
        self.fileRecencyLimit = fileRecencyLimit
    }

    public func scan(at now: Date = Date()) -> CodexSessionScanResult {
        lock.lock()
        defer { lock.unlock() }

        let inventory = inventoryFiles()
        var diagnostics = inventory.diagnostics
        var parsedFiles: [(fingerprint: FileFingerprint, parsed: ParsedSessionFile)] = []
        var retainedCachePaths = Set<String>()

        for file in inventory.files {
            let path = file.standardizedFileURL.path
            guard let fingerprint = fileFingerprint(file) else {
                diagnostics.append(
                    diagnostic(
                        .fileMetadataUnavailable,
                        file: file,
                        message: "Could not read file size or modification date."
                    )
                )
                continue
            }

            if let fileRecencyLimit,
               fingerprint.modifiedAt < now.addingTimeInterval(-fileRecencyLimit)
            {
                continue
            }

            retainedCachePaths.insert(path)
            let parsed: ParsedSessionFile
            if let cached = cache[path], cached.fingerprint == fingerprint {
                parsed = cached.parsed
            } else {
                parsed = SessionFileParser(file: file).parse()
                cache[path] = CachedFile(fingerprint: fingerprint, parsed: parsed)
            }
            parsedFiles.append((fingerprint, parsed))
        }

        cache = cache.filter { retainedCachePaths.contains($0.key) }

        // A rollout may briefly exist in both active and archived roots. Prefer
        // the newest copy instead of emitting the same agent and samples twice.
        var newestByAgentID: [String: (FileFingerprint, ParsedSessionFile)] = [:]
        for entry in parsedFiles {
            diagnostics.append(contentsOf: entry.parsed.diagnostics)
            guard let agentID = entry.parsed.agent?.id else {
                continue
            }
            if let current = newestByAgentID[agentID],
               current.0.modifiedAt >= entry.fingerprint.modifiedAt
            {
                continue
            }
            newestByAgentID[agentID] = entry
        }

        let selected = newestByAgentID.values.map(\.1)
        let agents = selected.compactMap(\.agent).sorted(by: agentSort)
        let samples = Dictionary(
            selected.flatMap(\.samples).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted(by: sampleSort)
        let activities = selected.compactMap(\.activity).sorted { $0.agentID < $1.agentID }

        diagnostics.sort(by: diagnosticSort)
        return CodexSessionScanResult(
            generatedAt: now,
            agents: agents,
            samples: samples,
            activities: activities,
            diagnostics: diagnostics
        )
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func inventoryFiles() -> (files: [URL], diagnostics: [CodexSessionDiagnostic]) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var filesByPath: [String: URL] = [:]
        var diagnostics: [CodexSessionDiagnostic] = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                diagnostics.append(
                    diagnostic(
                        .rootUnavailable,
                        file: root,
                        message: "Configured Codex session root does not exist."
                    )
                )
                continue
            }

            if !isDirectory.boolValue {
                if root.pathExtension.lowercased() == "jsonl" {
                    filesByPath[root.standardizedFileURL.path] = root
                }
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                diagnostics.append(
                    diagnostic(
                        .rootUnavailable,
                        file: root,
                        message: "Could not enumerate configured Codex session root."
                    )
                )
                continue
            }

            for case let file as URL in enumerator where file.pathExtension.lowercased() == "jsonl" {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else {
                    continue
                }
                filesByPath[file.standardizedFileURL.path] = file
            }
        }

        return (filesByPath.values.sorted { $0.path < $1.path }, diagnostics)
    }

    private func fileFingerprint(_ file: URL) -> FileFingerprint? {
        guard let values = try? file.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ), let modifiedAt = values.contentModificationDate,
              let size = values.fileSize
        else {
            return nil
        }
        return FileFingerprint(modifiedAt: modifiedAt, size: Int64(size))
    }
}

private struct FileFingerprint: Equatable {
    let modifiedAt: Date
    let size: Int64
}

private struct CachedFile {
    let fingerprint: FileFingerprint
    let parsed: ParsedSessionFile
}

private struct ParsedSessionFile {
    var agent: AgentDescriptor?
    var samples: [GenerationSample] = []
    var activity: CodexAgentActivity?
    var diagnostics: [CodexSessionDiagnostic] = []
}

private struct SessionMetadata {
    let id: String
    let sessionID: String
    let parentThreadID: String?
    let forkedFromID: String?
    let nickname: String?
    let agentPath: String?
    let model: String?
    let cwd: String?
    let createdAt: Date
    let createdAtMilliseconds: Double
    let isSubagent: Bool

    var mayContainInheritedHistory: Bool {
        isSubagent || forkedFromID != nil
    }
}

private struct ActiveTurn {
    let id: String
    let startedAt: Date
    var inputReadyAt: Date
    var model: String?
    var group: ModelGroup?
    var nextModelStartAt: Date?
    var sampleOrdinal = 0
}

private struct ModelGroup {
    var startedAt: Date
    var lastModelItemAt: Date?
    var hadToolCalls = false
    var outstandingCalls: [String: Date] = [:]
    var lastToolOutputAt: Date?
}

private final class SessionFileParser {
    private let file: URL
    private let decoder: JSONDecoder
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let wholeSecondDateFormatter: ISO8601DateFormatter

    private var result = ParsedSessionFile()
    private var metadata: SessionMetadata?
    private var activeTurn: ActiveTurn?
    private var lastActivity = CodexAgentActivityState.idle
    private var lastActivitySince: Date?
    private var lastTotalUsage: TokenUsageVector?
    private var observedModel: String?
    private var sawFirstSessionMetadata = false

    init(file: URL) {
        self.file = file
        decoder = JSONDecoder()
        fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondDateFormatter = ISO8601DateFormatter()
        wholeSecondDateFormatter.formatOptions = [.withInternetDateTime]
    }

    func parse() -> ParsedSessionFile {
        do {
            try enumerateCompleteLines { [self] data, lineNumber in
                do {
                    let record = try decoder.decode(CodexRecord.self, from: data)
                    consume(record, lineNumber: lineNumber)
                } catch {
                    result.diagnostics.append(
                        diagnostic(
                            .malformedJSON,
                            file: file,
                            line: lineNumber,
                            message: "Could not decode JSONL record."
                        )
                    )
                }
            }
        } catch {
            result.diagnostics.append(
                diagnostic(
                    .fileReadFailed,
                    file: file,
                    message: "Could not read JSONL file."
                )
            )
        }

        guard let metadata else {
            result.diagnostics.append(
                diagnostic(
                    .missingSessionMetadata,
                    file: file,
                    message: "The first session_meta record was not available."
                )
            )
            return result
        }

        let name: String
        if let nickname = metadata.nickname, !nickname.isEmpty {
            name = nickname
        } else if let agentPath = metadata.agentPath,
                  !URL(fileURLWithPath: agentPath).lastPathComponent.isEmpty
        {
            name = URL(fileURLWithPath: agentPath).lastPathComponent
        } else {
            name = metadata.isSubagent ? "Subagent" : "Main agent"
        }

        result.agent = AgentDescriptor(
            id: metadata.id,
            sessionID: metadata.sessionID,
            parentAgentID: metadata.parentThreadID,
            kind: metadata.isSubagent ? .subagent : .root,
            name: name,
            model: activeTurn?.model ?? observedModel ?? metadata.model,
            workingDirectory: metadata.cwd,
            startedAt: metadata.createdAt
        )

        if let activeTurn {
            let state: CodexAgentActivityState
            let since: Date?
            if let group = activeTurn.group, !group.outstandingCalls.isEmpty {
                state = .waitingOnTool
                since = group.outstandingCalls.values.max()
                result.diagnostics.append(
                    diagnostic(
                        .unresolvedToolCalls,
                        file: file,
                        message: "The active turn has tool calls without matching outputs."
                    )
                )
            } else {
                state = .answering
                since = activeTurn.nextModelStartAt
                    ?? activeTurn.group?.lastToolOutputAt
                    ?? activeTurn.inputReadyAt
            }
            result.activity = CodexAgentActivity(
                agentID: metadata.id,
                turnID: activeTurn.id,
                state: state,
                since: since
            )
        } else {
            result.activity = CodexAgentActivity(
                agentID: metadata.id,
                turnID: nil,
                state: lastActivity,
                since: lastActivitySince
            )
        }

        return result
    }

    private func consume(_ record: CodexRecord, lineNumber: Int) {
        guard let timestamp = parseDate(record.timestamp) else {
            return
        }

        if record.type == "session_meta" {
            consumeSessionMetadata(record.payload, recordTimestamp: timestamp, lineNumber: lineNumber)
            return
        }

        guard metadata != nil else {
            return
        }

        switch (record.type, record.payload.type) {
        case ("event_msg", "task_started"):
            consumeTaskStarted(record.payload, timestamp: timestamp, lineNumber: lineNumber)
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            consumeTaskEnded(record.payload, timestamp: timestamp, lineNumber: lineNumber)
        case ("event_msg", "token_count"):
            consumeTokenCount(record.payload, timestamp: timestamp, lineNumber: lineNumber)
        case ("event_msg", "user_message"):
            markInputReady(at: timestamp)
        case ("turn_context", _):
            guard activeTurn?.id == record.payload.turnID else {
                return
            }
            activeTurn?.model = record.payload.model ?? activeTurn?.model
            observedModel = record.payload.model ?? observedModel
            markInputReady(at: timestamp)
        case ("inter_agent_communication_metadata", _):
            markInputReady(at: timestamp)
        case ("response_item", "message"):
            consumeMessage(record.payload, timestamp: timestamp)
        case ("response_item", "agent_message"):
            if activeTurn?.group == nil {
                markInputReady(at: timestamp)
            }
        case ("response_item", "reasoning"):
            markModelItem(at: timestamp)
        case ("response_item", let type?) where isToolOutputType(type):
            consumeToolOutput(record.payload, timestamp: timestamp, lineNumber: lineNumber)
        case ("response_item", let type?) where isToolCallType(type):
            consumeToolCall(record.payload, timestamp: timestamp)
        default:
            break
        }
    }

    private func consumeSessionMetadata(
        _ payload: CodexPayload,
        recordTimestamp: Date,
        lineNumber: Int
    ) {
        // Legacy child rollouts copy the parent session_meta and history after
        // the child's own session_meta. Only the first metadata record owns the file.
        guard !sawFirstSessionMetadata else {
            return
        }
        sawFirstSessionMetadata = true

        guard let id = payload.id, !id.isEmpty else {
            result.diagnostics.append(
                diagnostic(
                    .missingThreadID,
                    file: file,
                    line: lineNumber,
                    message: "The owning session_meta record has no thread id."
                )
            )
            return
        }

        let source = payload.source
        let parentThreadID = payload.parentThreadID ?? source?.parentThreadID
        let isSubagent = parentThreadID != nil || source?.isSubagent == true
        let createdAt = payload.sessionTimestamp.flatMap(parseDate)
            ?? uuidV7Date(id)
            ?? recordTimestamp
        let sessionID = payload.sessionID
            ?? (isSubagent ? parentThreadID : nil)
            ?? id

        metadata = SessionMetadata(
            id: id,
            sessionID: sessionID,
            parentThreadID: parentThreadID,
            forkedFromID: payload.forkedFromID,
            nickname: payload.agentNickname ?? source?.nickname,
            agentPath: payload.agentPath ?? source?.agentPath,
            model: payload.model,
            cwd: payload.cwd,
            createdAt: createdAt,
            createdAtMilliseconds: createdAt.timeIntervalSince1970 * 1_000,
            isSubagent: isSubagent
        )
        lastActivitySince = createdAt
    }

    private func consumeTaskStarted(
        _ payload: CodexPayload,
        timestamp: Date,
        lineNumber: Int
    ) {
        guard let metadata,
              let turnID = payload.turnID,
              ownsTurn(payload, turnID: turnID, metadata: metadata, recordTimestamp: timestamp)
        else {
            return
        }

        if activeTurn != nil {
            result.diagnostics.append(
                diagnostic(
                    .overlappingTurns,
                    file: file,
                    line: lineNumber,
                    message: "A new owned turn started before the previous turn ended."
                )
            )
        }

        let startedAt = payload.startedAt.map { Date(timeIntervalSince1970: $0) }
            ?? uuidV7Date(turnID)
            ?? timestamp
        activeTurn = ActiveTurn(
            id: turnID,
            startedAt: startedAt,
            inputReadyAt: timestamp,
            model: payload.model
        )
        lastActivity = .answering
        lastActivitySince = timestamp
    }

    private func ownsTurn(
        _ payload: CodexPayload,
        turnID: String,
        metadata: SessionMetadata,
        recordTimestamp: Date
    ) -> Bool {
        if let turnMilliseconds = uuidV7Milliseconds(turnID) {
            return turnMilliseconds >= metadata.createdAtMilliseconds
        }

        if let startedAt = payload.startedAt {
            let lowerBound = startedAt * 1_000
            let upperBound = lowerBound + 999.999
            if upperBound < metadata.createdAtMilliseconds {
                return false
            }
            if lowerBound >= metadata.createdAtMilliseconds {
                return true
            }
            if metadata.mayContainInheritedHistory {
                result.diagnostics.append(
                    diagnostic(
                        .ambiguousTurnOwnership,
                        file: file,
                        message: "Skipped a copied-history turn whose second-resolution start is ambiguous."
                    )
                )
                return false
            }
            return true
        }

        if metadata.mayContainInheritedHistory {
            result.diagnostics.append(
                diagnostic(
                    .ambiguousTurnOwnership,
                    file: file,
                    message: "Skipped a copied-history turn without a UUIDv7 or started_at anchor."
                )
            )
            return false
        }
        return recordTimestamp >= metadata.createdAt
    }

    private func consumeTaskEnded(
        _ payload: CodexPayload,
        timestamp: Date,
        lineNumber: Int
    ) {
        guard let turnID = payload.turnID, activeTurn?.id == turnID else {
            return
        }

        if let group = activeTurn?.group {
            if !group.outstandingCalls.isEmpty {
                result.diagnostics.append(
                    diagnostic(
                        .unresolvedToolCalls,
                        file: file,
                        line: lineNumber,
                        message: "Turn ended with tool calls that have no matching output."
                    )
                )
            } else if group.lastModelItemAt != nil {
                result.diagnostics.append(
                    diagnostic(
                        .missingTokenUsage,
                        file: file,
                        line: lineNumber,
                        message: "Turn ended after model output without a token_count commit."
                    )
                )
            }
        }

        activeTurn = nil
        lastActivity = .idle
        lastActivitySince = timestamp
    }

    private func consumeMessage(_ payload: CodexPayload, timestamp: Date) {
        switch payload.role {
        case "assistant":
            markModelItem(at: timestamp)
        case "user", "developer", "system":
            markInputReady(at: timestamp)
        default:
            break
        }
    }

    private func markInputReady(at timestamp: Date) {
        guard var turn = activeTurn, turn.group == nil, turn.nextModelStartAt == nil else {
            return
        }
        turn.inputReadyAt = max(turn.inputReadyAt, timestamp)
        activeTurn = turn
    }

    private func markModelItem(at timestamp: Date) {
        guard var turn = activeTurn else {
            return
        }
        var group = turn.group ?? ModelGroup(
            startedAt: turn.nextModelStartAt ?? turn.inputReadyAt
        )
        group.lastModelItemAt = max(group.lastModelItemAt ?? timestamp, timestamp)
        turn.group = group
        turn.nextModelStartAt = nil
        activeTurn = turn
        lastActivity = .answering
    }

    private func consumeToolCall(_ payload: CodexPayload, timestamp: Date) {
        guard let callID = payload.callID, !callID.isEmpty else {
            markModelItem(at: timestamp)
            return
        }
        markModelItem(at: timestamp)
        guard var turn = activeTurn, var group = turn.group else {
            return
        }
        group.hadToolCalls = true
        group.outstandingCalls[callID] = timestamp
        turn.group = group
        activeTurn = turn
        lastActivity = .waitingOnTool
        lastActivitySince = timestamp
    }

    private func consumeToolOutput(
        _ payload: CodexPayload,
        timestamp: Date,
        lineNumber: Int
    ) {
        guard let callID = payload.callID,
              var turn = activeTurn,
              var group = turn.group,
              group.outstandingCalls.removeValue(forKey: callID) != nil
        else {
            result.diagnostics.append(
                diagnostic(
                    .unmatchedToolOutput,
                    file: file,
                    line: lineNumber,
                    message: "Tool output did not match an active model call_id."
                )
            )
            return
        }

        group.lastToolOutputAt = max(group.lastToolOutputAt ?? timestamp, timestamp)
        turn.group = group
        activeTurn = turn
        if group.outstandingCalls.isEmpty {
            lastActivity = .answering
            lastActivitySince = timestamp
        }
    }

    private func consumeTokenCount(
        _ payload: CodexPayload,
        timestamp: Date,
        lineNumber: Int
    ) {
        guard let total = payload.info?.totalTokenUsage,
              let last = payload.info?.lastTokenUsage
        else {
            result.diagnostics.append(
                diagnostic(
                    .missingTokenUsage,
                    file: file,
                    line: lineNumber,
                    message: "token_count did not include total and last usage vectors."
                )
            )
            return
        }

        if total == lastTotalUsage {
            result.diagnostics.append(
                diagnostic(
                    .duplicateTokenSnapshot,
                    file: file,
                    line: lineNumber,
                    message: "Skipped a token_count snapshot with an unchanged cumulative vector."
                )
            )
            return
        }
        if let previous = lastTotalUsage, !total.isMonotonic(after: previous), activeTurn != nil {
            result.diagnostics.append(
                diagnostic(
                    .nonMonotonicTokenTotal,
                    file: file,
                    line: lineNumber,
                    message: "Cumulative token usage moved backwards; last_token_usage was retained."
                )
            )
        }
        lastTotalUsage = total

        guard var turn = activeTurn else {
            // Copied parent history still advances the dedupe baseline but never
            // produces samples for the child that owns this file.
            return
        }
        guard let group = turn.group,
              let endedAt = group.lastModelItemAt,
              endedAt > group.startedAt
        else {
            result.diagnostics.append(
                diagnostic(
                    .missingModelInterval,
                    file: file,
                    line: lineNumber,
                    message: "Skipped token usage without trustworthy model start/end anchors."
                )
            )
            return
        }

        let outputTokens = clampedInt(last.outputTokens)
        let reasoningTokens = min(outputTokens, clampedInt(last.reasoningOutputTokens))
        turn.sampleOrdinal += 1
        result.samples.append(
            GenerationSample(
                id: "\(metadata?.id ?? "unknown"):\(turn.id):\(turn.sampleOrdinal)",
                agentID: metadata?.id ?? "unknown",
                startedAt: group.startedAt,
                endedAt: endedAt,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                tokenQuality: .reported,
                timingQuality: .inferred
            )
        )

        if group.hadToolCalls {
            if group.outstandingCalls.isEmpty, let outputAt = group.lastToolOutputAt {
                turn.nextModelStartAt = outputAt
                turn.inputReadyAt = outputAt
            } else {
                result.diagnostics.append(
                    diagnostic(
                        .unresolvedToolCalls,
                        file: file,
                        line: lineNumber,
                        message: "Token usage arrived before all tool outputs were paired."
                    )
                )
                turn.nextModelStartAt = nil
            }
        } else {
            turn.nextModelStartAt = nil
            turn.inputReadyAt = timestamp
        }
        turn.group = nil
        activeTurn = turn
    }

    private func enumerateCompleteLines(
        _ body: (Data, Int) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var buffer = Data()
        var lineNumber = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            var consumed = buffer.startIndex
            while let newline = buffer[consumed...].firstIndex(of: 0x0A) {
                var end = newline
                if end > consumed, buffer[buffer.index(before: end)] == 0x0D {
                    end = buffer.index(before: end)
                }
                lineNumber += 1
                if end > consumed {
                    try body(Data(buffer[consumed..<end]), lineNumber)
                }
                consumed = buffer.index(after: newline)
                if consumed == buffer.endIndex {
                    break
                }
            }
            if consumed > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<consumed)
            }
        }
        // A writer may be in the middle of appending the final JSON object.
        // Ignore an unterminated tail and retry it after the mtime/size changes.
    }

    private func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? wholeSecondDateFormatter.date(from: value)
    }
}

private struct CodexRecord: Decodable {
    let timestamp: String
    let type: String
    let payload: CodexPayload
}

private struct CodexPayload: Decodable {
    let type: String?
    let id: String?
    let sessionID: String?
    let parentThreadID: String?
    let forkedFromID: String?
    let sessionTimestamp: String?
    let source: CodexSource?
    let agentNickname: String?
    let agentPath: String?
    let cwd: String?
    let model: String?
    let turnID: String?
    let startedAt: TimeInterval?
    let completedAt: TimeInterval?
    let durationMilliseconds: Int64?
    let role: String?
    let callID: String?
    let name: String?
    let info: TokenCountInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case sessionID = "session_id"
        case parentThreadID = "parent_thread_id"
        case forkedFromID = "forked_from_id"
        case sessionTimestamp = "timestamp"
        case source
        case agentNickname = "agent_nickname"
        case agentPath = "agent_path"
        case cwd
        case model
        case turnID = "turn_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMilliseconds = "duration_ms"
        case role
        case callID = "call_id"
        case name
        case info
    }
}

private struct TokenCountInfo: Decodable {
    let totalTokenUsage: TokenUsageVector?
    let lastTokenUsage: TokenUsageVector?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
    }
}

private struct TokenUsageVector: Decodable, Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int64.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        reasoningOutputTokens = try container.decodeIfPresent(
            Int64.self,
            forKey: .reasoningOutputTokens
        ) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
    }

    func isMonotonic(after previous: Self) -> Bool {
        inputTokens >= previous.inputTokens
            && cachedInputTokens >= previous.cachedInputTokens
            && outputTokens >= previous.outputTokens
            && reasoningOutputTokens >= previous.reasoningOutputTokens
            && totalTokens >= previous.totalTokens
    }
}

private struct CodexSource: Decodable {
    let isSubagent: Bool
    let parentThreadID: String?
    let nickname: String?
    let agentPath: String?

    init(from decoder: Decoder) throws {
        if let scalar = try? decoder.singleValueContainer().decode(String.self) {
            isSubagent = scalar.lowercased().contains("subagent")
            parentThreadID = nil
            nickname = nil
            agentPath = nil
            return
        }

        let container = try decoder.container(keyedBy: SourceCodingKey.self)
        let nested = try container.decodeIfPresent(
            CodexSubagentSource.self,
            forKey: .subagent
        ) ?? (try container.decodeIfPresent(CodexSubagentSource.self, forKey: .subAgent))
        isSubagent = nested != nil
        parentThreadID = nested?.threadSpawn?.parentThreadID
        nickname = nested?.threadSpawn?.nickname
        agentPath = nested?.threadSpawn?.agentPath
    }

    private enum SourceCodingKey: String, CodingKey {
        case subagent
        case subAgent
    }
}

private struct CodexSubagentSource: Decodable {
    let threadSpawn: CodexThreadSpawn?

    init(from decoder: Decoder) throws {
        if (try? decoder.singleValueContainer().decode(String.self)) != nil {
            threadSpawn = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadSpawn = try container.decodeIfPresent(CodexThreadSpawn.self, forKey: .threadSpawn)
            ?? (try container.decodeIfPresent(CodexThreadSpawn.self, forKey: .threadSpawnCamel))
    }

    private enum CodingKeys: String, CodingKey {
        case threadSpawn = "thread_spawn"
        case threadSpawnCamel = "threadSpawn"
    }
}

private struct CodexThreadSpawn: Decodable {
    let parentThreadID: String?
    let nickname: String?
    let agentPath: String?

    enum CodingKeys: String, CodingKey {
        case parentThreadID = "parent_thread_id"
        case nickname = "agent_nickname"
        case agentPath = "agent_path"
    }
}

private func isToolCallType(_ type: String) -> Bool {
    type == "function_call" || type == "custom_tool_call" || type.hasSuffix("_call")
}

private func isToolOutputType(_ type: String) -> Bool {
    type == "function_call_output"
        || type == "custom_tool_call_output"
        || type.hasSuffix("_call_output")
}

private func uuidV7Milliseconds(_ value: String) -> Double? {
    let hex = value.replacingOccurrences(of: "-", with: "")
    guard hex.count == 32,
          hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
          let milliseconds = UInt64(hex.prefix(12), radix: 16)
    else {
        return nil
    }
    return Double(milliseconds)
}

private func uuidV7Date(_ value: String) -> Date? {
    uuidV7Milliseconds(value).map { Date(timeIntervalSince1970: $0 / 1_000) }
}

private func clampedInt(_ value: Int64) -> Int {
    if value <= 0 {
        return 0
    }
    return Int(min(value, Int64(Int.max)))
}

private func diagnostic(
    _ code: CodexSessionDiagnosticCode,
    file: URL,
    line: Int? = nil,
    message: String
) -> CodexSessionDiagnostic {
    CodexSessionDiagnostic(code: code, filePath: file.path, line: line, message: message)
}

private func agentSort(_ lhs: AgentDescriptor, _ rhs: AgentDescriptor) -> Bool {
    if lhs.startedAt != rhs.startedAt {
        return lhs.startedAt < rhs.startedAt
    }
    return lhs.id < rhs.id
}

private func sampleSort(_ lhs: GenerationSample, _ rhs: GenerationSample) -> Bool {
    if lhs.startedAt != rhs.startedAt {
        return lhs.startedAt < rhs.startedAt
    }
    return lhs.id < rhs.id
}

private func diagnosticSort(_ lhs: CodexSessionDiagnostic, _ rhs: CodexSessionDiagnostic) -> Bool {
    if lhs.filePath != rhs.filePath {
        return lhs.filePath < rhs.filePath
    }
    if lhs.line != rhs.line {
        return (lhs.line ?? 0) < (rhs.line ?? 0)
    }
    return lhs.code.rawValue < rhs.code.rawValue
}
