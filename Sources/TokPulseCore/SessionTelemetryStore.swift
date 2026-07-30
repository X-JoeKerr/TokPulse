import Foundation

public struct SessionTelemetrySnapshot: Hashable, Sendable {
    public let live: SessionScanResult
    public let rolling: SessionScanResult?
}

public struct SessionTelemetryStatistics: Hashable, Sendable {
    public let codex: SessionScannerStatistics
    public let qoder: SessionScannerStatistics
}

/// Owns discovery and parser state for all supported session providers.
///
/// The first refresh inventories recent files once. Later refreshes drain
/// recursive file events and read only changed JSONL tails. Live and daily
/// callers receive different time projections of this one in-memory cache.
public final class SessionTelemetryStore: @unchecked Sendable {
    public static let rollingWindow: TimeInterval = 26 * 60 * 60
    public static let liveFileRecencyLimit: TimeInterval = 3 * 60

    private let lock = NSLock()
    private let codexScanner: CodexSessionScanner
    private let qoderScanner: QoderSessionScanner
    private let watcher: RecursiveFileWatcher
    private let codexRoots: [URL]
    private let qoderCLIRoots: [URL]
    private let qoderQuestRoots: [URL]
    private var isInitialized = false

    public init(
        codexRoots: [URL] = CodexSessionScanner.defaultRoots,
        qoderCLIRoots: [URL] = QoderSessionScanner.defaultCLIRoots,
        qoderQuestRoots: [URL] = QoderSessionScanner.defaultQuestRoots
    ) {
        self.codexRoots = codexRoots
        self.qoderCLIRoots = qoderCLIRoots
        self.qoderQuestRoots = qoderQuestRoots
        watcher = RecursiveFileWatcher(
            roots: codexRoots + qoderCLIRoots + qoderQuestRoots
        )
        codexScanner = CodexSessionScanner(
            roots: codexRoots,
            fileRecencyLimit: Self.rollingWindow
        )
        qoderScanner = QoderSessionScanner(
            cliRoots: qoderCLIRoots,
            questRoots: qoderQuestRoots,
            fileRecencyLimit: Self.rollingWindow
        )
    }

    public func refresh(
        at now: Date = Date(),
        includeRolling: Bool = true
    ) -> SessionTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }

        if !isInitialized {
            _ = codexScanner.scan(at: now)
            _ = qoderScanner.scan(at: now)
            isInitialized = true
            apply(watcher.drain(), at: now)
        } else {
            apply(watcher.drain(), at: now)
        }

        let live = SessionScanResult.merged(
            generatedAt: now,
            [
                codexScanner.snapshot(
                    at: now,
                    fileRecencyLimit: Self.liveFileRecencyLimit
                ),
                qoderScanner.snapshot(
                    at: now,
                    fileRecencyLimit: Self.liveFileRecencyLimit
                ),
            ]
        )
        let rolling: SessionScanResult? = includeRolling
            ? SessionScanResult.merged(
                generatedAt: now,
                [
                    codexScanner.snapshot(
                        at: now,
                        fileRecencyLimit: Self.rollingWindow
                    ),
                    qoderScanner.snapshot(
                        at: now,
                        fileRecencyLimit: Self.rollingWindow
                    ),
                ]
            )
            : nil
        return SessionTelemetrySnapshot(live: live, rolling: rolling)
    }

    public var statistics: SessionTelemetryStatistics {
        lock.lock()
        defer { lock.unlock() }
        return SessionTelemetryStatistics(
            codex: codexScanner.statistics,
            qoder: qoderScanner.statistics
        )
    }

    private func apply(_ batch: RecursiveFileEventBatch, at now: Date) {
        if batch.requiresFullReconcile {
            _ = codexScanner.scan(at: now)
            _ = qoderScanner.scan(at: now)
            return
        }

        var codexFiles = Set<URL>()
        var qoderFiles = Set<URL>()
        for file in batch.changedFiles {
            if file.pathExtension.lowercased() == "jsonl" {
                if contains(file, in: codexRoots) {
                    codexFiles.insert(file)
                } else if contains(file, in: qoderCLIRoots)
                    || contains(file, in: qoderQuestRoots)
                {
                    qoderFiles.insert(file)
                }
            } else if file.lastPathComponent.hasSuffix("-session.json"),
                      contains(file, in: qoderQuestRoots)
            {
                let jsonlName = String(
                    file.lastPathComponent.dropLast("-session.json".count)
                ) + ".jsonl"
                qoderFiles.insert(
                    file.deletingLastPathComponent()
                        .appendingPathComponent(jsonlName)
                )
            }
        }
        if !codexFiles.isEmpty {
            _ = codexScanner.refresh(changedFiles: Array(codexFiles), at: now)
        }
        if !qoderFiles.isEmpty {
            _ = qoderScanner.refresh(changedFiles: Array(qoderFiles), at: now)
        }
    }

    private func contains(_ file: URL, in roots: [URL]) -> Bool {
        let path = file.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }
}
