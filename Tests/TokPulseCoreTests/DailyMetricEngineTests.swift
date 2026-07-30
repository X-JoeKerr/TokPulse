import Foundation
import Testing
@testable import TokPulseCore
import TokPulseProtocol

private let dailyNow = Date(timeIntervalSince1970: 10_000)

@Test
func mergesConcurrentDailyActivityAndTotalsCompletedTokens() {
    let metrics = dailyEngine().calculate(
        at: dailyNow,
        samples: [
            dailySample("first", start: -120, duration: 60, tokens: 600),
            dailySample("overlapping", start: -90, duration: 60, tokens: 900),
            dailySample("separate", start: -20, duration: 10, tokens: 100),
        ],
        activities: []
    )

    #expect(metrics.outputTokens == 1_600)
    #expect(metrics.activeSeconds == 100)
    #expect(metrics.tokensPerSecond == 16)
}

@Test
func clipsActivityAtLocalMidnightAndIncludesCurrentAnsweringTime() {
    let metrics = dailyEngine().calculate(
        at: dailyNow,
        samples: [
            dailySample("cross-midnight", start: -10_020, duration: 40, tokens: 200),
            dailySample("completed", start: -50, duration: 30, tokens: 500),
        ],
        activities: [
            AgentActivity(
                agentID: "answering",
                turnID: "turn",
                state: .answering,
                since: dailyNow.addingTimeInterval(-25)
            ),
            AgentActivity(
                agentID: "waiting",
                turnID: "turn",
                state: .waitingOnTool,
                since: dailyNow.addingTimeInterval(-1_000)
            ),
        ]
    )

    #expect(metrics.dayStartedAt == Date(timeIntervalSince1970: 0))
    #expect(metrics.outputTokens == 700)
    #expect(metrics.activeSeconds == 70)
    #expect(metrics.tokensPerSecond == 10)
}

@Test
func ignoresInvalidAndFutureSamplesAndNonAnsweringActivities() {
    let metrics = dailyEngine().calculate(
        at: dailyNow,
        samples: [
            dailySample("zero-duration", start: -10, duration: 0, tokens: 100),
            dailySample("negative-tokens", start: -10, duration: 5, tokens: -1),
            dailySample("future", start: -1, duration: 2, tokens: 100),
        ],
        activities: [
            AgentActivity(
                agentID: "future",
                turnID: nil,
                state: .answering,
                since: dailyNow.addingTimeInterval(1)
            ),
            AgentActivity(
                agentID: "idle",
                turnID: nil,
                state: .idle,
                since: dailyNow.addingTimeInterval(-100)
            ),
        ]
    )

    #expect(metrics.outputTokens == 0)
    #expect(metrics.activeSeconds == 0)
    #expect(metrics.tokensPerSecond == 0)
}

private func dailyEngine() -> DailyMetricEngine {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return DailyMetricEngine(calendar: calendar)
}

private func dailySample(
    _ id: String,
    start: TimeInterval,
    duration: TimeInterval,
    tokens: Int
) -> GenerationSample {
    GenerationSample(
        id: id,
        agentID: id,
        startedAt: dailyNow.addingTimeInterval(start),
        endedAt: dailyNow.addingTimeInterval(start + duration),
        outputTokens: tokens,
        timingQuality: .observed
    )
}
