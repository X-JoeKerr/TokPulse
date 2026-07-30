import Testing
@testable import TokPulseProtocol

@Test
func statusBarSelectionDefaultsToAverageAndCombined() {
    let selection = StatusBarMetricSelection.default

    #expect(selection.contains(.average))
    #expect(selection.contains(.combined))
    #expect(!selection.contains(.activeTime))
    #expect(!selection.contains(.todayRate))
    #expect(selection.rawValues == ["average", "combined"])
}

@Test
func statusBarSelectionPreservesAnExplicitEmptySelection() {
    let selection = StatusBarMetricSelection(rawValues: [])

    #expect(selection.isEmpty)
    #expect(selection.rawValues.isEmpty)
}

@Test
func statusBarSelectionIgnoresUnknownValuesAndUsesStableOrder() {
    let selection = StatusBarMetricSelection(
        rawValues: ["todayRate", "unknown", "average", "activeTime"]
    )

    #expect(selection.rawValues == ["average", "activeTime", "todayRate"])
}

@Test
func statusBarSelectionTogglesMetricsIndependently() {
    var selection = StatusBarMetricSelection.default

    selection.toggle(.average)
    selection.toggle(.activeTime)

    #expect(!selection.contains(.average))
    #expect(selection.contains(.combined))
    #expect(selection.contains(.activeTime))
    #expect(selection.rawValues == ["combined", "activeTime"])
}
