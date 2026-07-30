import CoreServices
import Foundation

struct RecursiveFileEventBatch {
    var changedFiles: [URL]
    var requiresFullReconcile: Bool
}

private final class RecursiveFileWatcherState: @unchecked Sendable {
    private let lock = NSLock()
    private var changedPaths = Set<String>()
    private var requiresFullReconcile = false

    func record(
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<count {
            changedPaths.insert(paths[index])
            let eventFlags = flags[index]
            let reconcileFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
            )
            if eventFlags & reconcileFlags != 0 {
                requiresFullReconcile = true
            }
        }
    }

    func drain() -> RecursiveFileEventBatch {
        lock.lock()
        defer { lock.unlock() }
        let batch = RecursiveFileEventBatch(
            changedFiles: changedPaths.sorted().map(URL.init(fileURLWithPath:)),
            requiresFullReconcile: requiresFullReconcile
        )
        changedPaths.removeAll(keepingCapacity: true)
        requiresFullReconcile = false
        return batch
    }
}

final class RecursiveFileWatcher: @unchecked Sendable {
    private let state = RecursiveFileWatcherState()
    private let queue = DispatchQueue(
        label: "com.x-joekerr.TokPulse.session-file-events",
        qos: .utility
    )
    private var stream: FSEventStreamRef?

    init(roots: [URL]) {
        let watchedPaths = Set(roots.compactMap(Self.nearestExistingDirectory))
            .map(\.standardizedFileURL.path)
            .sorted()
        guard !watchedPaths.isEmpty else {
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(state).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = {
            _, contextInfo, eventCount, eventPaths, eventFlags, _ in
            guard let contextInfo else {
                return
            }
            let state = Unmanaged<RecursiveFileWatcherState>
                .fromOpaque(contextInfo)
                .takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            state.record(paths: paths, flags: eventFlags, count: eventCount)
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            createFlags
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return
        }
    }

    deinit {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func drain() -> RecursiveFileEventBatch {
        state.drain()
    }

    private static func nearestExistingDirectory(_ root: URL) -> URL? {
        var candidate = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ) || !isDirectory.boolValue {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                return nil
            }
            candidate = parent
        }
        return candidate
    }
}
