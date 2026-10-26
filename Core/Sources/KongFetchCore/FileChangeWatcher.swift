#if canImport(CoreServices)
import CoreServices
import Foundation

/// FSEvents watcher that can resume from a saved event id, so changes made while
/// KongFetch was not running are replayed at the next launch instead of
/// requiring a rescan (3.2 always started from "now").
public final class FileChangeWatcher {
    public struct Batch: Sendable {
        public var changes: [IndexChange] = []
        /// Highest event id in this batch; store it as `NameIndex.lastEventID` after applying.
        public var lastEventID: UInt64 = 0
        /// Event ids wrapped or a watched root moved/was deleted: rebuild the index.
        public var requiresFullRebuild = false
        /// The replay of past events is finished; later batches are live.
        public var historyDone = false
    }

    private let paths: [String]
    private let since: UInt64?
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: (Batch) -> Void
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - since: resume after this event id (`NameIndex.lastEventID`); nil starts from now.
    ///   - handler: called on `queue` with each batch.
    public init(paths: [String], since: UInt64? = nil, latency: TimeInterval = 0.3, queue: DispatchQueue = .main, handler: @escaping (Batch) -> Void) {
        self.paths = paths
        self.since = since
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let watcher = Unmanaged<FileChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var batch = Batch()
            let rebuildFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            for i in 0..<count {
                let flag = rawFlags[i]
                batch.lastEventID = max(batch.lastEventID, rawIDs[i])
                if flag & historyDone != 0 {
                    batch.historyDone = true
                    continue
                }
                if flag & rebuildFlags != 0 { batch.requiresFullRebuild = true }
                batch.changes.append(IndexChange(path: String(cString: cPaths[i]), rescanSubtree: flag & rescanFlags != 0))
            }
            watcher.handler(batch)
        }
        let startID = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray, startID, latency, createFlags) else { return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) {
            stop()
            return false
        }
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The newest event id on this Mac; record it right before a full build.
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Identity of the FSEvents database for the volume holding `path`.
    /// If it differs from the one saved with the index, old event ids are meaningless.
    public static func eventDatabaseUUID(forPath path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev)?.takeRetainedValue() else { return nil }
        guard let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return text as String
    }
}
#endif
