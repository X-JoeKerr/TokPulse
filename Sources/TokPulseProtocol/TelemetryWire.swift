import Foundation

public struct TelemetryOutput: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let metrics: DashboardMetrics
    public let dailyMetrics: DailyMetrics
    public let answeringAgentCount: Int
    public let diagnosticCount: Int

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        metrics: DashboardMetrics,
        dailyMetrics: DailyMetrics,
        answeringAgentCount: Int,
        diagnosticCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.metrics = metrics
        self.dailyMetrics = dailyMetrics
        self.answeringAgentCount = answeringAgentCount
        self.diagnosticCount = diagnosticCount
    }
}

public enum TelemetryJSON {
    public static func encode(
        _ output: TelemetryOutput,
        prettyPrinted: Bool
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(output)
    }

    public static func decode(_ data: Data) throws -> TelemetryOutput {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TelemetryOutput.self, from: data)
    }
}

public enum TelemetryStreamEvent: Hashable, Sendable {
    case output(TelemetryOutput)
    case malformedLine
}

/// Frames arbitrary stdout chunks into independent CLI JSON Lines records.
public final class TelemetryOutputStreamDecoder {
    private static let maximumBufferedBytes = 5 * 1_024 * 1_024

    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [TelemetryStreamEvent] {
        guard !data.isEmpty else {
            return []
        }
        buffer.append(data)
        var events: [TelemetryStreamEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var end = newline
            if end > buffer.startIndex,
               buffer[buffer.index(before: end)] == 0x0D
            {
                end = buffer.index(before: end)
            }
            let line = Data(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else {
                continue
            }
            if let output = try? TelemetryJSON.decode(line) {
                events.append(.output(output))
            } else {
                events.append(.malformedLine)
            }
        }

        if buffer.count > Self.maximumBufferedBytes {
            buffer.removeAll(keepingCapacity: true)
            events.append(.malformedLine)
        }
        return events
    }
}

public enum TelemetryCLICommand: Equatable, Sendable {
    case snapshot(prettyPrinted: Bool)
    case stream(interval: TimeInterval)
    case help

    public static let usage = """
    Usage:
      tokpulse-cli snapshot --json [--pretty]
      tokpulse-cli stream --json-lines [--interval SECONDS]
      tokpulse-cli --help
    """

    public static func parse(_ arguments: [String]) throws -> Self {
        guard let command = arguments.first else {
            return .help
        }
        switch command {
        case "--help", "-h", "help":
            guard arguments.count == 1 else {
                throw TelemetryCLIError.invalidArguments("Help takes no arguments.")
            }
            return .help
        case "snapshot":
            let options = Array(arguments.dropFirst())
            guard options.contains("--json") else {
                throw TelemetryCLIError.invalidArguments(
                    "snapshot requires --json."
                )
            }
            let allowed = Set(["--json", "--pretty"])
            guard options.allSatisfy(allowed.contains) else {
                throw TelemetryCLIError.invalidArguments(
                    "snapshot received an unknown option."
                )
            }
            return .snapshot(prettyPrinted: options.contains("--pretty"))
        case "stream":
            return try parseStream(Array(arguments.dropFirst()))
        default:
            throw TelemetryCLIError.invalidArguments(
                "Unknown command: \(command)"
            )
        }
    }

    private static func parseStream(_ options: [String]) throws -> Self {
        guard options.contains("--json-lines") else {
            throw TelemetryCLIError.invalidArguments(
                "stream requires --json-lines."
            )
        }

        var interval: TimeInterval = 2
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--json-lines":
                index += 1
            case "--interval":
                guard index + 1 < options.count,
                      let value = TimeInterval(options[index + 1]),
                      value >= 0.25
                else {
                    throw TelemetryCLIError.invalidArguments(
                        "--interval must be at least 0.25 seconds."
                    )
                }
                interval = value
                index += 2
            default:
                throw TelemetryCLIError.invalidArguments(
                    "stream received an unknown option."
                )
            }
        }
        return .stream(interval: interval)
    }
}

public enum TelemetryCLIError: Error, Equatable, Sendable {
    case invalidArguments(String)
}
