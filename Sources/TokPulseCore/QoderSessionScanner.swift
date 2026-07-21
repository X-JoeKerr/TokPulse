import Foundation

/// Reads Qoder CLI and Qoder Quest session JSONL without retaining prompts,
/// messages, or tool output.
///
/// Neither format reports token usage, so output tokens are estimated from the
/// generated text (ASCII characters / 4 plus one token per non-ASCII character)
/// and every sample is marked `.estimated`.
public final class QoderSessionScanner: @unchecked Sendable {
    public static let defaultFileRecencyLimit: TimeInterval = 3 * 60

    public static var defaultCLIRoots: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".qoder", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true),
        ]
    }

    public static var defaultQuestRoots: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Qoder", isDirectory: true)
                .appendingPathComponent("SharedClientCache/cli/projects", isDirectory: true),
        ]
    }

    public let cliRoots: [URL]
    public let questRoots: [URL]
    public let fileRecencyLimit: TimeInterval?

    private let lock = NSLock()
    private var cache: [String: CachedFile] = [:]

    public init(
        cliRoots: [URL] = QoderSessionScanner.defaultCLIRoots,
        questRoots: [URL] = QoderSessionScanner.defaultQuestRoots,
        fileRecencyLimit: TimeInterval? = QoderSessionScanner.defaultFileRecencyLimit
    ) {
        self.cliRoots = cliRoots
        self.questRoots = questRoots
        self.fileRecencyLimit = fileRecencyLimit
    }

    public func scan(at now: Date = Date()) -> SessionScanResult {
        lock.lock()
        defer { lock.unlock() }

        var diagnostics: [SessionDiagnostic] = []
        var files: [(url: URL, format: QoderFileFormat)] = []
        files += inventoryFiles(in: cliRoots, format: .cli, diagnostics: &diagnostics)
        files += inventoryFiles(in: questRoots, format: .quest, diagnostics: &diagnostics)

        var parsedFiles: [(fingerprint: FileFingerprint, parsed: ParsedQoderFile)] = []
        var retainedCachePaths = Set<String>()

        for (file, format) in files {
            let path = file.standardizedFileURL.path
            guard let fingerprint = fileFingerprint(file) else {
                diagnostics.append(
                    SessionDiagnostic(
                        code: .fileMetadataUnavailable,
                        filePath: file.path,
                        line: nil,
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
            let parsed: ParsedQoderFile
            if let cached = cache[path], cached.fingerprint == fingerprint {
                parsed = cached.parsed
            } else {
                parsed = QoderFileParser(file: file, format: format).parse()
                cache[path] = CachedFile(fingerprint: fingerprint, parsed: parsed)
            }
            parsedFiles.append((fingerprint, parsed))
        }

        cache = cache.filter { retainedCachePaths.contains($0.key) }

        var newestByAgentID: [String: (FileFingerprint, ParsedQoderFile)] = [:]
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
        let agents = selected.compactMap(\.agent).sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.id < rhs.id
        }
        let samples = selected.flatMap(\.samples).sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.id < rhs.id
        }
        let activities = selected.compactMap(\.activity).sorted { $0.agentID < $1.agentID }
        diagnostics.sort { lhs, rhs in
            if lhs.filePath != rhs.filePath {
                return lhs.filePath < rhs.filePath
            }
            if lhs.line != rhs.line {
                return (lhs.line ?? 0) < (rhs.line ?? 0)
            }
            return lhs.code.rawValue < rhs.code.rawValue
        }

        return SessionScanResult(
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

    private func inventoryFiles(
        in roots: [URL],
        format: QoderFileFormat,
        diagnostics: inout [SessionDiagnostic]
    ) -> [(URL, QoderFileFormat)] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var filesByPath: [String: URL] = [:]

        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                diagnostics.append(
                    SessionDiagnostic(
                        code: .rootUnavailable,
                        filePath: root.path,
                        line: nil,
                        message: "Configured Qoder session root does not exist."
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
                    SessionDiagnostic(
                        code: .rootUnavailable,
                        filePath: root.path,
                        line: nil,
                        message: "Could not enumerate configured Qoder session root."
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

        return filesByPath.values
            .sorted { $0.path < $1.path }
            .map { ($0, format) }
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

public enum QoderFileFormat: String, Sendable {
    case cli
    case quest
}

private struct FileFingerprint: Equatable {
    let modifiedAt: Date
    let size: Int64
}

private struct CachedFile {
    let fingerprint: FileFingerprint
    let parsed: ParsedQoderFile
}

private struct ParsedQoderFile {
    var agent: AgentDescriptor?
    var samples: [GenerationSample] = []
    var activity: AgentActivity?
    var diagnostics: [SessionDiagnostic] = []
}

private struct TokenEstimate {
    var outputTokens = 0
    var reasoningTokens = 0

    mutating func add(output text: String) {
        outputTokens += estimateTokens(text)
    }

    mutating func add(reasoning text: String) {
        let tokens = estimateTokens(text)
        outputTokens += tokens
        reasoningTokens += tokens
    }

    mutating func merge(_ other: TokenEstimate) {
        outputTokens += other.outputTokens
        reasoningTokens += other.reasoningTokens
    }
}

private struct ResponseGroup {
    var startedAt: Date
    var endedAt: Date
    var estimate = TokenEstimate()
    var hasOutstandingToolCall = false
}

private final class QoderFileParser {
    private let file: URL
    private let format: QoderFileFormat
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let wholeSecondDateFormatter: ISO8601DateFormatter

    private var result = ParsedQoderFile()

    private var sessionID: String?
    private var isSidechain = false
    private var subagentID: String?
    private var workingDirectory: String?
    private var configModel: String?
    private var messageModel: String?
    private var firstTimestamp: Date?

    private var pendingInputAt: Date?
    private var group: ResponseGroup?
    private var sampleOrdinal = 0

    init(file: URL, format: QoderFileFormat) {
        self.file = file
        self.format = format
        fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondDateFormatter = ISO8601DateFormatter()
        wholeSecondDateFormatter.formatOptions = [.withInternetDateTime]
    }

    func parse() -> ParsedQoderFile {
        do {
            try enumerateCompleteLines { [self] data, lineNumber in
                guard let record = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = record as? [String: Any]
                else {
                    result.diagnostics.append(
                        SessionDiagnostic(
                            code: .malformedJSON,
                            filePath: file.path,
                            line: lineNumber,
                            message: "Could not decode JSONL record."
                        )
                    )
                    return
                }
                switch format {
                case .cli:
                    consumeCLI(dictionary)
                case .quest:
                    consumeQuest(dictionary)
                }
            }
        } catch {
            result.diagnostics.append(
                SessionDiagnostic(
                    code: .fileReadFailed,
                    filePath: file.path,
                    line: nil,
                    message: "Could not read JSONL file."
                )
            )
        }

        switch format {
        case .cli:
            finishCLI()
        case .quest:
            finishQuest()
        }
        return result
    }

    // MARK: - Qoder CLI format

    private func consumeCLI(_ record: [String: Any]) {
        guard let type = record["type"] as? String else {
            return
        }

        if type == "runtime-config" {
            sessionID = sessionID ?? record["sessionId"] as? String
            configModel = record["model"] as? String ?? configModel
            if firstTimestamp == nil, let milliseconds = record["timestamp"] as? Double {
                firstTimestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            }
            return
        }

        guard type == "user" || type == "assistant",
              let timestampValue = record["timestamp"] as? String,
              let timestamp = parseDate(timestampValue)
        else {
            return
        }

        sessionID = sessionID ?? record["sessionId"] as? String
        workingDirectory = workingDirectory ?? record["cwd"] as? String
        if record["isSidechain"] as? Bool == true {
            isSidechain = true
        }
        subagentID = subagentID ?? record["agentId"] as? String
        if firstTimestamp == nil || timestamp < firstTimestamp! {
            firstTimestamp = timestamp
        }

        let message = record["message"] as? [String: Any]

        if type == "user" {
            flushGroup()
            pendingInputAt = timestamp
            return
        }

        messageModel = message?["model"] as? String ?? messageModel
        var estimate = TokenEstimate()
        var sawToolUse = false
        if let blocks = message?["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    estimate.add(output: block["text"] as? String ?? "")
                case "thinking":
                    estimate.add(reasoning: block["thinking"] as? String ?? "")
                case "tool_use":
                    sawToolUse = true
                    if let input = block["input"],
                       let data = try? JSONSerialization.data(
                           withJSONObject: input,
                           options: [.fragmentsAllowed]
                       ), let text = String(data: data, encoding: .utf8)
                    {
                        estimate.add(output: text)
                    }
                default:
                    break
                }
            }
        }
        extendGroup(to: timestamp, estimate: estimate, sawToolCall: sawToolUse)
    }

    private func finishCLI() {
        guard let sessionID else {
            result.diagnostics.append(
                SessionDiagnostic(
                    code: .missingSessionMetadata,
                    filePath: file.path,
                    line: nil,
                    message: "No record carried a Qoder sessionId."
                )
            )
            return
        }

        let isSubagent = isSidechain || subagentID != nil
        let agentID = subagentID ?? sessionID
        let name: String
        if isSubagent {
            name = subagentDisplayName(subagentID) ?? "Subagent"
        } else {
            name = "Main agent"
        }

        finish(
            agentID: agentID,
            sessionID: sessionID,
            parentAgentID: isSubagent ? sessionID : nil,
            kind: isSubagent ? .subagent : .root,
            source: .qoderCLI,
            name: name,
            model: messageModel ?? configModel,
            workingDirectory: workingDirectory
        )
    }

    // MARK: - Qoder Quest format

    private func consumeQuest(_ record: [String: Any]) {
        guard let role = record["role"] as? String,
              let milliseconds = record["created_at"] as? Double
        else {
            return
        }
        let timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)

        sessionID = sessionID ?? record["session_id"] as? String
        messageModel = messageModel ?? record["model"] as? String
        if firstTimestamp == nil || timestamp < firstTimestamp! {
            firstTimestamp = timestamp
        }

        let parts = record["parts"] as? [[String: Any]] ?? []

        if role == "user" || role == "tool" {
            flushGroup()
            pendingInputAt = timestamp
            return
        }
        guard role == "assistant" else {
            return
        }

        var estimate = TokenEstimate()
        var sawToolCall = false
        for part in parts {
            let data = part["data"] as? [String: Any]
            switch part["type"] as? String {
            case "text":
                estimate.add(output: data?["text"] as? String ?? "")
            case "reasoning":
                estimate.add(reasoning: data?["thinking"] as? String ?? "")
            case "tool_call":
                sawToolCall = true
                estimate.add(output: data?["input"] as? String ?? "")
            default:
                break
            }
        }
        extendGroup(to: timestamp, estimate: estimate, sawToolCall: sawToolCall)
    }

    private func finishQuest() {
        guard let sessionID = sessionID ?? questSessionIDFromFileName() else {
            result.diagnostics.append(
                SessionDiagnostic(
                    code: .missingSessionMetadata,
                    filePath: file.path,
                    line: nil,
                    message: "No record carried a Qoder Quest session_id."
                )
            )
            return
        }

        let companion = readQuestCompanion()
        finish(
            agentID: sessionID,
            sessionID: sessionID,
            parentAgentID: nil,
            kind: .root,
            source: .qoderQuest,
            name: companion?["title"] as? String ?? "Quest",
            model: messageModel,
            workingDirectory: companion?["working_dir"] as? String
        )
    }

    private func questSessionIDFromFileName() -> String? {
        let base = file.deletingPathExtension().lastPathComponent
        return base.isEmpty ? nil : base
    }

    private func readQuestCompanion() -> [String: Any]? {
        let base = file.deletingPathExtension().lastPathComponent
        let companion = file.deletingLastPathComponent()
            .appendingPathComponent("\(base)-session.json")
        guard let data = try? Data(contentsOf: companion),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return object as? [String: Any]
    }

    // MARK: - Shared assembly

    private func extendGroup(to timestamp: Date, estimate: TokenEstimate, sawToolCall: Bool) {
        if var group {
            group.endedAt = max(group.endedAt, timestamp)
            group.estimate.merge(estimate)
            group.hasOutstandingToolCall = group.hasOutstandingToolCall || sawToolCall
            self.group = group
        } else {
            var group = ResponseGroup(
                startedAt: pendingInputAt ?? timestamp,
                endedAt: timestamp
            )
            group.estimate = estimate
            group.hasOutstandingToolCall = sawToolCall
            self.group = group
        }
        pendingInputAt = nil
    }

    private func flushGroup() {
        guard let group else {
            return
        }
        self.group = nil
        appendSample(for: group)
    }

    private func appendSample(for group: ResponseGroup) {
        guard group.endedAt > group.startedAt, group.estimate.outputTokens > 0 else {
            return
        }
        sampleOrdinal += 1
        result.samples.append(
            GenerationSample(
                id: "\(file.lastPathComponent):\(sampleOrdinal)",
                agentID: "",
                startedAt: group.startedAt,
                endedAt: group.endedAt,
                outputTokens: group.estimate.outputTokens,
                reasoningTokens: min(
                    group.estimate.outputTokens,
                    group.estimate.reasoningTokens
                ),
                tokenQuality: .estimated,
                timingQuality: .inferred
            )
        )
    }

    private func finish(
        agentID: String,
        sessionID: String,
        parentAgentID: String?,
        kind: AgentKind,
        source: AgentSource,
        name: String,
        model: String?,
        workingDirectory: String?
    ) {
        let finalGroup = group
        flushGroup()

        result.agent = AgentDescriptor(
            id: agentID,
            sessionID: sessionID,
            parentAgentID: parentAgentID,
            kind: kind,
            source: source,
            name: name,
            model: model,
            workingDirectory: workingDirectory,
            startedAt: firstTimestamp ?? .distantPast
        )
        result.samples = result.samples.map { sample in
            GenerationSample(
                id: "\(agentID):\(sample.id)",
                agentID: agentID,
                startedAt: sample.startedAt,
                endedAt: sample.endedAt,
                outputTokens: sample.outputTokens,
                reasoningTokens: sample.reasoningTokens,
                tokenQuality: sample.tokenQuality,
                timingQuality: sample.timingQuality
            )
        }

        let state: AgentActivityState
        let since: Date?
        if let finalGroup, finalGroup.hasOutstandingToolCall {
            state = .waitingOnTool
            since = finalGroup.endedAt
        } else if let pendingInputAt {
            state = .answering
            since = pendingInputAt
        } else {
            state = .idle
            since = finalGroup?.endedAt ?? firstTimestamp
        }
        result.activity = AgentActivity(
            agentID: agentID,
            turnID: nil,
            state: state,
            since: since
        )
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

private func subagentDisplayName(_ agentID: String?) -> String? {
    guard let agentID, !agentID.isEmpty else {
        return nil
    }
    guard let lastDash = agentID.lastIndex(of: "-"), lastDash != agentID.startIndex else {
        return agentID
    }
    return String(agentID[..<lastDash])
}

private func estimateTokens(_ text: String) -> Int {
    guard !text.isEmpty else {
        return 0
    }
    var ascii = 0
    var other = 0
    for scalar in text.unicodeScalars {
        if scalar.value < 128 {
            ascii += 1
        } else {
            other += 1
        }
    }
    return (ascii + 3) / 4 + other
}
