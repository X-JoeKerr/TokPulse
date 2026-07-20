import Foundation

public enum AgentKind: String, Codable, Sendable {
    case root
    case subagent
}

public enum TokenCountQuality: String, Codable, Sendable {
    case reported
    case estimated
}

public enum TimingQuality: String, Codable, Sendable {
    case observed
    case inferred
}

public struct AgentDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let parentAgentID: String?
    public let kind: AgentKind
    public let name: String
    public let model: String?
    public let workingDirectory: String?
    public let startedAt: Date

    public init(
        id: String,
        sessionID: String,
        parentAgentID: String? = nil,
        kind: AgentKind,
        name: String,
        model: String? = nil,
        workingDirectory: String? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentAgentID = parentAgentID
        self.kind = kind
        self.name = name
        self.model = model
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
    }
}

public struct GenerationSample: Identifiable, Hashable, Sendable {
    public let id: String
    public let agentID: String
    public let startedAt: Date
    public let endedAt: Date
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let tokenQuality: TokenCountQuality
    public let timingQuality: TimingQuality

    public init(
        id: String,
        agentID: String,
        startedAt: Date,
        endedAt: Date,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        tokenQuality: TokenCountQuality = .reported,
        timingQuality: TimingQuality = .inferred
    ) {
        self.id = id
        self.agentID = agentID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.tokenQuality = tokenQuality
        self.timingQuality = timingQuality
    }
}

public struct AgentMetrics: Identifiable, Hashable, Sendable {
    public let id: String
    public let descriptor: AgentDescriptor
    public let outputTokens: Double
    public let reasoningTokens: Double
    public let activeSeconds: TimeInterval
    public let averageTPS: Double
    public let sampleCount: Int
    public let isEstimated: Bool
}

public struct SessionMetrics: Identifiable, Hashable, Sendable {
    public let id: String
    public let agents: [AgentMetrics]
    public let averageTPS: Double
    public let totalTPS: Double
    public let outputTokens: Double
    public let activeSeconds: TimeInterval
    public let isEstimated: Bool
}

public struct DashboardMetrics: Hashable, Sendable {
    public let generatedAt: Date
    public let windowSeconds: TimeInterval
    public let sessions: [SessionMetrics]
    public let averageTPS: Double
    public let totalTPS: Double
    public let outputTokens: Double
    public let activeSeconds: TimeInterval
    public let activeAgentCount: Int
    public let isEstimated: Bool

    public static func empty(at date: Date, windowSeconds: TimeInterval) -> Self {
        Self(
            generatedAt: date,
            windowSeconds: windowSeconds,
            sessions: [],
            averageTPS: 0,
            totalTPS: 0,
            outputTokens: 0,
            activeSeconds: 0,
            activeAgentCount: 0,
            isEstimated: false
        )
    }
}

