import Foundation

public struct DailyMetrics: Hashable, Sendable {
    public let generatedAt: Date
    public let dayStartedAt: Date
    public let outputTokens: Double
    public let activeSeconds: TimeInterval
    public let tokensPerSecond: Double
}

public struct DailyMetricEngine: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func empty(at now: Date) -> DailyMetrics {
        DailyMetrics(
            generatedAt: now,
            dayStartedAt: calendar.startOfDay(for: now),
            outputTokens: 0,
            activeSeconds: 0,
            tokensPerSecond: 0
        )
    }

    public func calculate(
        at now: Date,
        samples: [GenerationSample],
        activities: [AgentActivity]
    ) -> DailyMetrics {
        guard let day = calendar.dateInterval(of: .day, for: now) else {
            return empty(at: now)
        }

        var outputTokens = 0.0
        var activeIntervals: [DateInterval] = []

        for sample in samples {
            guard sample.outputTokens >= 0,
                  sample.reasoningTokens >= 0,
                  sample.endedAt > sample.startedAt,
                  sample.endedAt <= now
            else {
                continue
            }

            if day.contains(sample.endedAt) {
                outputTokens += Double(sample.outputTokens)
            }

            let startedAt = max(sample.startedAt, day.start)
            let endedAt = min(sample.endedAt, now)
            if endedAt > startedAt {
                activeIntervals.append(DateInterval(start: startedAt, end: endedAt))
            }
        }

        for activity in activities where activity.isAnswering {
            guard let since = activity.since, since < now else {
                continue
            }
            let startedAt = max(since, day.start)
            if now > startedAt {
                activeIntervals.append(DateInterval(start: startedAt, end: now))
            }
        }

        let activeSeconds = unionDuration(activeIntervals)
        return DailyMetrics(
            generatedAt: now,
            dayStartedAt: day.start,
            outputTokens: outputTokens,
            activeSeconds: activeSeconds,
            tokensPerSecond: activeSeconds > 0 ? outputTokens / activeSeconds : 0
        )
    }

    private func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted {
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            return $0.end < $1.end
        }
        guard var current = sorted.first else {
            return 0
        }

        var total: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }
}
