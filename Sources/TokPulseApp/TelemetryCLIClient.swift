import Foundation
import TokPulseProtocol

final class TelemetryCLIClient: @unchecked Sendable {
    enum Event: Sendable {
        case output(TelemetryOutput)
        case malformedOutput
        case disconnected
    }

    private let executableURL: URL
    private let queue = DispatchQueue(
        label: "com.tokpulse.telemetry-cli",
        qos: .utility
    )
    private let restartSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var process: Process?
    private var isStarted = false
    private var isStopped = false

    init(executableURL: URL = TelemetryCLIClient.bundledExecutableURL) {
        self.executableURL = executableURL
    }

    func start(
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        isStopped = false
        lock.unlock()

        queue.async { [weak self] in
            self?.run(onEvent: onEvent)
        }
    }

    func stop() {
        lock.lock()
        isStopped = true
        let activeProcess = process
        lock.unlock()

        restartSignal.signal()
        if activeProcess?.isRunning == true {
            activeProcess?.terminate()
        }
    }

    private func run(
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        var restartDelay: TimeInterval = 1
        while !stopped {
            let emittedOutput = runOnce(onEvent: onEvent)
            guard !stopped else { return }

            onEvent(.disconnected)
            restartDelay = emittedOutput
                ? 1
                : min(restartDelay * 2, 30)
            _ = restartSignal.wait(
                timeout: .now() + restartDelay
            )
        }
    }

    private func runOnce(
        onEvent: @escaping @Sendable (Event) -> Void
    ) -> Bool {
        let child = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.executableURL = executableURL
        child.arguments = ["stream", "--json-lines"]
        child.standardOutput = standardOutput
        child.standardError = standardError

        standardError.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        lock.lock()
        guard !isStopped else {
            lock.unlock()
            standardError.fileHandleForReading.readabilityHandler = nil
            return false
        }
        process = child
        lock.unlock()

        do {
            try child.run()
        } catch {
            clear(child)
            standardError.fileHandleForReading.readabilityHandler = nil
            return false
        }

        let decoder = TelemetryOutputStreamDecoder()
        var emittedOutput = false
        while !stopped {
            do {
                guard let data = try standardOutput.fileHandleForReading
                    .read(upToCount: 64 * 1_024),
                    !data.isEmpty
                else {
                    break
                }
                for event in decoder.append(data) {
                    switch event {
                    case .output(let output):
                        emittedOutput = true
                        onEvent(.output(output))
                    case .malformedLine:
                        onEvent(.malformedOutput)
                    }
                }
            } catch {
                break
            }
        }

        if child.isRunning {
            child.terminate()
        }
        child.waitUntilExit()
        standardError.fileHandleForReading.readabilityHandler = nil
        clear(child)
        return emittedOutput
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func clear(_ child: Process) {
        lock.lock()
        if process === child {
            process = nil
        }
        lock.unlock()
    }

    private static var bundledExecutableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("tokpulse-cli", isDirectory: false)
    }
}
