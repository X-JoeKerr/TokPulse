import Foundation

public enum AgentKind: String, Codable, Sendable {
    case root
    case subagent
}

public enum AgentSource: String, Codable, Sendable {
    case codex
    case qoderCLI
    case qoderQuest

    public var isQoder: Bool {
        self != .codex
    }
}

public struct AgentDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let parentAgentID: String?
    public let kind: AgentKind
    public let source: AgentSource
    public let name: String
    public let model: String?
    public let workingDirectory: String?
    public let startedAt: Date

    public init(
        id: String,
        sessionID: String,
        parentAgentID: String? = nil,
        kind: AgentKind,
        source: AgentSource = .codex,
        name: String,
        model: String? = nil,
        workingDirectory: String? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentAgentID = parentAgentID
        self.kind = kind
        self.source = source
        self.name = name
        self.model = model
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
    }
}

public struct AgentMetrics: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let descriptor: AgentDescriptor
    public let outputTokens: Double
    public let reasoningTokens: Double
    public let activeSeconds: TimeInterval
    public let averageTPS: Double
    public let sampleCount: Int
    public let isEstimated: Bool

    public init(
        id: String,
        descriptor: AgentDescriptor,
        outputTokens: Double,
        reasoningTokens: Double,
        activeSeconds: TimeInterval,
        averageTPS: Double,
        sampleCount: Int,
        isEstimated: Bool
    ) {
        self.id = id
        self.descriptor = descriptor
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.activeSeconds = activeSeconds
        self.averageTPS = averageTPS
        self.sampleCount = sampleCount
        self.isEstimated = isEstimated
    }

    public var hasFreshSample: Bool {
        sampleCount > 0
    }
}

public struct SessionMetrics: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let agents: [AgentMetrics]
    public let averageTPS: Double
    public let totalTPS: Double
    public let outputTokens: Double
    public let activeSeconds: TimeInterval
    public let isEstimated: Bool

    public init(
        id: String,
        agents: [AgentMetrics],
        averageTPS: Double,
        totalTPS: Double,
        outputTokens: Double,
        activeSeconds: TimeInterval,
        isEstimated: Bool
    ) {
        self.id = id
        self.agents = agents
        self.averageTPS = averageTPS
        self.totalTPS = totalTPS
        self.outputTokens = outputTokens
        self.activeSeconds = activeSeconds
        self.isEstimated = isEstimated
    }

    public var activeAgentCount: Int {
        agents.lazy.filter(\.hasFreshSample).count
    }
}

public struct DashboardMetrics: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let windowSeconds: TimeInterval
    public let sessions: [SessionMetrics]
    public let averageTPS: Double
    public let totalTPS: Double
    public let outputTokens: Double
    public let activeSeconds: TimeInterval
    public let activeAgentCount: Int
    public let isEstimated: Bool

    public init(
        generatedAt: Date,
        windowSeconds: TimeInterval,
        sessions: [SessionMetrics],
        averageTPS: Double,
        totalTPS: Double,
        outputTokens: Double,
        activeSeconds: TimeInterval,
        activeAgentCount: Int,
        isEstimated: Bool
    ) {
        self.generatedAt = generatedAt
        self.windowSeconds = windowSeconds
        self.sessions = sessions
        self.averageTPS = averageTPS
        self.totalTPS = totalTPS
        self.outputTokens = outputTokens
        self.activeSeconds = activeSeconds
        self.activeAgentCount = activeAgentCount
        self.isEstimated = isEstimated
    }

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

public struct DailyMetrics: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let dayStartedAt: Date
    public let outputTokens: Double
    public let activeSeconds: TimeInterval
    public let tokensPerSecond: Double

    public init(
        generatedAt: Date,
        dayStartedAt: Date,
        outputTokens: Double,
        activeSeconds: TimeInterval,
        tokensPerSecond: Double
    ) {
        self.generatedAt = generatedAt
        self.dayStartedAt = dayStartedAt
        self.outputTokens = outputTokens
        self.activeSeconds = activeSeconds
        self.tokensPerSecond = tokensPerSecond
    }
}

public enum StatusBarMetric: String, CaseIterable, Hashable, Sendable {
    case average
    case combined
    case activeTime
    case todayRate
}

public struct StatusBarMetricSelection: Equatable, Sendable {
    public static let `default` = Self(enabled: [.average, .combined])

    private var enabled: Set<StatusBarMetric>

    public init(enabled: Set<StatusBarMetric>) {
        self.enabled = enabled
    }

    public init(rawValues: [String]) {
        self.enabled = Set(rawValues.compactMap(StatusBarMetric.init(rawValue:)))
    }

    public var isEmpty: Bool {
        enabled.isEmpty
    }

    public var rawValues: [String] {
        StatusBarMetric.allCases
            .filter(enabled.contains)
            .map(\.rawValue)
    }

    public func contains(_ metric: StatusBarMetric) -> Bool {
        enabled.contains(metric)
    }

    public mutating func toggle(_ metric: StatusBarMetric) {
        if enabled.contains(metric) {
            enabled.remove(metric)
        } else {
            enabled.insert(metric)
        }
    }
}
