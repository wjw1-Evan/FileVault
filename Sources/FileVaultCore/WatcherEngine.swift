import Foundation
import CoreServices

/// Injectable event source protocol.
public protocol ChangeSource: AnyObject {
    func start(paths: [String], onEvent: @escaping @Sendable ([String]) -> Void)
    func stop()
}

/// Callback holder for the C callback context pointer.
final class EventBox {
    let handler: @Sendable ([String]) -> Void
    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }
}

/// FSEvents-based ChangeSource (FR-04).
public final class FSEventsChangeSource: ChangeSource {
    private var stream: FSEventStreamRef?
    private let streamQueue = DispatchQueue(label: "fv.fsnews.queue")
    private var started = false
    private let lifecycleLock = NSLock()

    public init() {}

    public func start(paths: [String], onEvent: @escaping @Sendable ([String] ) -> Void) {
        lifecycleLock.lock()
        guard !started else {
            lifecycleLock.unlock()
            return
        }
        started = true
        lifecycleLock.unlock()
        let box = EventBox(handler: onEvent)
        let info = Unmanaged.passRetained(box).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { pointer in
                if let pointer {
                    Unmanaged<EventBox>.fromOpaque(pointer).release()
                }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _stream, info, numEvents, eventPaths, _flags, _ids in
            guard let info else { return }
            let box = Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue()
            var list: [String] = []
            // SDK declares eventPaths as void*; without UseCFTypes it points to
            // a C array of char* paths.
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            for i in 0..<numEvents {
                if let p = cPaths[i] {
                    list.append(String(cString: p))
                }
            }
            if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                print("[FV_DEBUG] raw events: \(list)")
            }
            box.handler(list)
        }
        let flags: UInt32 = UInt32(kFSEventStreamCreateFlagFileEvents) | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, streamQueue)
        let startedOK = FSEventStreamStart(stream)
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] stream started=\(startedOK) paths=\(paths)")
        }
        self.stream = stream
    }

    public func stop() {
        lifecycleLock.lock()
        guard let stream else {
            lifecycleLock.unlock()
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        started = false
        lifecycleLock.unlock()
    }
}

/// Maps raw FSEvents paths to the owning first-level subfolder (FR-03/04).
public final class WatcherEngine {
    public let rootPath: String
    private let source: ChangeSource

    public private(set) var realRoot: String = ""

    public init(rootPath: String, source: ChangeSource) {
        self.rootPath = rootPath
        // FSEvents reports canonical /private/... paths; resolve via realpath().
        var buf = [CChar](repeating: 0, count: 4096)
        if realpath(rootPath, &buf) != nil {
            self.realRoot = String(cString: buf)
        } else {
            self.realRoot = rootPath
        }
        self.source = source
    }

    public func start(onActivity: @escaping @Sendable (String) -> Void,
                      onRootStructureChanged: @escaping @Sendable () -> Void) {
        let root = realRoot
        source.start(paths: [root]) { eventPaths in
            for p in eventPaths {
                guard p.hasPrefix(root + "/") else {
                    if p == root {
                        onRootStructureChanged()
                    }
                    continue
                }
                let rel = String(p.dropFirst((root + "/").count))
                let comps = rel.split(separator: "/", omittingEmptySubsequences: false)
                // Ignore our own/other tools' .git internals (index refresh etc.)
                // or the debounce would self-trigger forever.
                if comps.count >= 2 && comps[1] == ".git" {
                    continue
                }
                if comps.count >= 2 {
                    onActivity(String(comps[0]))
                } else {
                    // First-level item created/removed/renamed: rescan structure.
                    onRootStructureChanged()
                }
            }
        }
    }

    public func stop() {
        source.stop()
    }
}
