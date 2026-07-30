import Foundation
import TokPulseProtocol

public enum AgentActivityState: String, Hashable, Sendable {
    case answering
    case waitingOnTool
    case idle
    case unknown
}

public struct AgentActivity: Hashable, Sendable {
    public let agentID: String
    public let turnID: String?
    public let state: AgentActivityState
    public let since: Date?

    public var isAnswering: Bool {
        state == .answering
    }
}

public enum SessionDiagnosticCode: String, Hashable, Sendable {
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

public struct SessionDiagnostic: Hashable, Sendable {
    public let code: SessionDiagnosticCode
    public let filePath: String
    public let line: Int?
    public let message: String
}

public struct SessionScanResult: Hashable, Sendable {
    public let generatedAt: Date
    public let agents: [AgentDescriptor]
    public let samples: [GenerationSample]
    public let activities: [AgentActivity]
    public let diagnostics: [SessionDiagnostic]

    public var answeringAgentIDs: Set<String> {
        Set(activities.lazy.filter(\.isAnswering).map(\.agentID))
    }

    public static func merged(generatedAt: Date, _ results: [SessionScanResult]) -> SessionScanResult {
        SessionScanResult(
            generatedAt: generatedAt,
            agents: results.flatMap(\.agents),
            samples: results.flatMap(\.samples),
            activities: results.flatMap(\.activities),
            diagnostics: results.flatMap(\.diagnostics)
        )
    }
}

public struct SessionScannerStatistics: Hashable, Sendable {
    public internal(set) var bytesRead: Int64 = 0
    public internal(set) var inventoryPasses = 0
    public internal(set) var parserResets = 0

    public init() {}
}
