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
