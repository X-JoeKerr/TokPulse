import Darwin
import Foundation
import TokPulseCore
import TokPulseProtocol

@main
struct TokPulseCLI {
    static func main() {
        do {
            let command = try TelemetryCLICommand.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            switch command {
            case .help:
                try writeText(TelemetryCLICommand.usage, to: .standardOutput)
            case .snapshot(let prettyPrinted):
                let output = TelemetryBackend().snapshot()
                try write(
                    output,
                    prettyPrinted: prettyPrinted,
                    to: .standardOutput
                )
            case .stream(let interval):
                try stream(interval: interval)
            }
        } catch let error as TelemetryCLIError {
            writeError(error)
            exit(EX_USAGE)
        } catch {
            try? writeText(
                "tokpulse-cli failed: \(error)\n",
                to: .standardError
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func stream(interval: TimeInterval) throws {
        let backend = TelemetryBackend()
        while true {
            try write(
                backend.snapshot(),
                prettyPrinted: false,
                to: .standardOutput
            )
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private static func write(
        _ output: TelemetryOutput,
        prettyPrinted: Bool,
        to handle: FileHandle
    ) throws {
        var data = try TelemetryJSON.encode(
            output,
            prettyPrinted: prettyPrinted
        )
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func writeText(
        _ text: String,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func writeError(_ error: TelemetryCLIError) {
        let message: String
        switch error {
        case .invalidArguments(let detail):
            message = "\(detail)\n\(TelemetryCLICommand.usage)"
        }
        try? writeText(message, to: .standardError)
    }
}
