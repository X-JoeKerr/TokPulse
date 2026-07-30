import Combine
import Foundation
import TokPulseProtocol

@MainActor
final class StatusBarPreferences: ObservableObject {
    static let defaultsKey = "statusBarMetrics"

    @Published private(set) var selection: StatusBarMetricSelection

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.defaultsKey) == nil {
            self.selection = .default
        } else {
            self.selection = StatusBarMetricSelection(
                rawValues: defaults.stringArray(forKey: Self.defaultsKey) ?? []
            )
        }
    }

    func toggle(_ metric: StatusBarMetric) {
        selection.toggle(metric)
        defaults.set(selection.rawValues, forKey: Self.defaultsKey)
    }
}
