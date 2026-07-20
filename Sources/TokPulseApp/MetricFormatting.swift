import Foundation

enum MetricFormatting {
    static func tps(_ value: Double, available: Bool = true) -> String {
        guard available, value.isFinite, value >= 0 else { return "—" }

        let decimals = if value >= 100 {
            0
        } else if value >= 10 {
            1
        } else {
            2
        }
        return String(format: "%.*f", decimals, value)
    }

    static func tokenCount(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }

        switch value {
        case 1_000_000_000...:
            return compact(value / 1_000_000_000, suffix: "B")
        case 1_000_000...:
            return compact(value / 1_000_000, suffix: "M")
        case 1_000...:
            return compact(value / 1_000, suffix: "K")
        default:
            return String(Int(value.rounded()))
        }
    }

    static func activeTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        if seconds < 1 { return "<1s" }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainder = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        return "\(remainder)s"
    }

    static func window(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "No window" }

        let roundedSeconds = Int(seconds.rounded())
        if roundedSeconds.isMultiple(of: 3_600) {
            let hours = roundedSeconds / 3_600
            return hours == 1 ? "1 hr" : "\(hours) hr"
        }
        if roundedSeconds.isMultiple(of: 60) {
            return "\(roundedSeconds / 60) min"
        }
        return "\(roundedSeconds) sec"
    }

    static func updatedTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func shortenedID(_ id: String) -> String {
        guard id.count > 10 else { return id }
        return String(id.prefix(8))
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let decimals = value >= 100 ? 0 : 1
        return String(format: "%.*f%@", decimals, value, suffix)
    }
}
