import Foundation
import TokPulseProtocol

public enum TokenCountQuality: String, Codable, Sendable {
    case reported
    case estimated
}

public enum TimingQuality: String, Codable, Sendable {
    case observed
    case inferred
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
