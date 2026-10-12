import CoreServices
import Foundation

/// Watches folders recursively with FSEvents and reports changed paths (coalesced).
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "gemmafind.fsevents")
    private let handler: @Sendable ([String]) -> Void

    public init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    public func start(folders: [String], latency: TimeInterval = 2.0) {
        stop()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(paths, to: NSArray.self)
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                guard let p = cfPaths[i] as? String else { continue }
                // Ignore hidden files / folders anywhere in the path.
                if p.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                out.append(p)
            }
            _ = flags
            if !out.isEmpty { watcher.handler(out) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, folders as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
