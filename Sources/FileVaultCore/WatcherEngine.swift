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
        // FSEvents C calls happen OUTSIDE the lifecycle lock (they wait on the
        // stream queue; holding the lock here deadlocked the suite).
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
        ) else {
            // Creation failed: release the `started` claim so a later start can retry.
            lifecycleLock.lock()
            started = false
            lifecycleLock.unlock()
            Unmanaged<EventBox>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, streamQueue)
        let startedOK = FSEventStreamStart(stream)
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] stream started=\(startedOK) paths=\(paths)")
        }
        guard startedOK else {
            // Start failed: tear down cleanly and allow a retry (a stream that
            // failed to start must not be started again, only released).
            streamQueue.sync {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            lifecycleLock.lock()
            started = false
            lifecycleLock.unlock()
            return
        }
        self.stream = stream
    }

    public func stop() {
        // Capture + clear under the lock; the C teardown runs ON the stream
        // queue so it serializes against in-flight callbacks (releasing a
        // stream while its callback executes is a potential crash).
        lifecycleLock.lock()
        let stream = self.stream
        self.stream = nil
        started = false
        lifecycleLock.unlock()
        guard let stream else { return }
        streamQueue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Watches ONE managed root folder and reports activity anywhere inside it
/// (FR-03/04).
///
/// v4.0: there is no per-subfolder attribution anymore — any file event below
/// the root (including loose files directly in the root) means "this folder
/// has changes"; the debouncer coalesces a burst into one commit.
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

    public func start(onActivity: @escaping @Sendable () -> Void) {
        let root = realRoot
        source.start(paths: [root]) { eventPaths in
            var relevant = false
            for p in eventPaths {
                // Events for the root itself (attributes) carry no content change.
                guard p.hasPrefix(root + "/") else { continue }
                let rel = String(p.dropFirst((root + "/").count))
                let comps = rel.split(separator: "/", omittingEmptySubsequences: false)
                // Ignore .git internals at ANY depth (our own commits, the
                // user's own git tooling, nested repos) or the debounce would
                // retrigger itself forever.
                if comps.contains(where: { $0 == ".git" }) { continue }
                relevant = true
                break
            }
            if relevant { onActivity() }
        }
    }

    public func stop() {
        source.stop()
    }
}
