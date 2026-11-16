import XCTest
import CoreServices
@testable import FileVaultCore

/// Deterministic ChangeSource: the test drives exactly the paths FSEvents would
/// deliver, so the watcher's filtering rules are asserted without timing flake.
final class FakeChangeSource: ChangeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([String]) -> Void)?
    private(set) var startedPaths: [String] = []
    private(set) var stopCount = 0

    /// Set to false to simulate FSEventStreamCreate/Start failing.
    var startSucceeds = true

    @discardableResult
    func start(paths: [String], onEvent: @escaping @Sendable ([String]) -> Void) -> Bool {
        lock.lock()
        startedPaths = paths
        handler = onEvent
        let ok = startSucceeds
        lock.unlock()
        return ok
    }

    func stop() {
        lock.lock()
        stopCount += 1
        handler = nil
        lock.unlock()
    }

    func emit(_ paths: [String]) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(paths)
    }
}

/// Thread-safe one-shot flag for @Sendable activity callbacks.
final class ActivityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe holder for the changed paths delivered to the activity callback.
final class ActivityPathsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func set(_ paths: [String]) { lock.lock(); stored = paths; lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class WatcherEngineTests: XCTestCase {
    private func makeTempBase(_ name: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Deterministic filter semantics (v4.0)

    /// A loose file directly in the managed root is versioned content, so it
    /// MUST trigger activity (old watcher only counted first-level folders).
    func testRootLevelFileEventFiresActivity() throws {
        let base = try makeTempBase("wroot")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = FakeChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        let flag = ActivityFlag()
        engine.start(onActivity: { flag.mark() })
        defer { engine.stop() }
        XCTAssertEqual(source.startedPaths, [engine.realRoot], "watches the root itself")
        source.emit([engine.realRoot + "/top.txt"])
        XCTAssertTrue(flag.fired, "root-level file event must trigger activity")
    }

    func testNestedFileEventFiresActivity() throws {
        let base = try makeTempBase("wnested")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = FakeChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        let flag = ActivityFlag()
        engine.start(onActivity: { flag.mark() })
        defer { engine.stop() }
        source.emit([engine.realRoot + "/nested/deeper/deep.md"])
        XCTAssertTrue(flag.fired, "nested file event must trigger activity")
    }

    /// Our own commits write into .git; treating those as activity would loop
    /// forever. ".git" at ANY depth must be filtered out.
    func testGitDirectoryEventsAreIgnoredAtAnyDepth() throws {
        let base = try makeTempBase("wdotgit")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = FakeChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        let flag = ActivityFlag()
        engine.start(onActivity: { flag.mark() })
        defer { engine.stop() }

        source.emit([engine.realRoot + "/.git/index",
                     engine.realRoot + "/.git/refs/heads/main"])
        source.emit([engine.realRoot + "/nested/.git/objects/ab/cdef"])
        XCTAssertFalse(flag.fired, ".git internals must never map to activity")

        // Sanity check: the very same callback DOES fire for real content, so
        // the assertion above is meaningful (not a dead handler).
        source.emit([engine.realRoot + "/real.md"])
        XCTAssertTrue(flag.fired)
    }

    func testEventOnRootItselfDoesNotFire() throws {
        let base = try makeTempBase("wself")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = FakeChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        let flag = ActivityFlag()
        engine.start(onActivity: { flag.mark() })
        defer { engine.stop() }
        source.emit([engine.realRoot])
        XCTAssertFalse(flag.fired, "attribute events on the root itself carry no content change")
    }


    /// The activity callback reports the changed paths (relative to the root)
    /// with .git internals filtered out — the commit pipeline uses them to
    /// detect brand-new empty folders.
    func testActivityCarriesChangedRelativePaths() throws {
        let base = try makeTempBase("wpaths")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = FakeChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        let box = ActivityPathsFlag()
        engine.start(onActivityPaths: { box.set($0) })
        defer { engine.stop() }
        source.emit([engine.realRoot + "/new-folder",
                     engine.realRoot + "/.git/index",
                     engine.realRoot + "/docs/a.md",
                     engine.realRoot + "/new-folder"])
        XCTAssertEqual(box.paths, ["new-folder", "docs/a.md"],
                       "relative, de-duplicated, .git filtered")
    }

    // MARK: - Real FSEvents end-to-end

    func testFSEventsDeliversActivityForSubfolderEvent() async throws {
        let base = try makeTempBase("fsevents")
        defer { try? FileManager.default.removeItem(at: base) }
        let sub = base.appendingPathComponent("sub1")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let exp = expectation(description: "activity fired")
        let onceLock = NSLock()
        var fulfilled = false
        engine.start(onActivity: {
            // FSEvents may deliver several batches; fulfill only once.
            onceLock.lock()
            let first = !fulfilled
            fulfilled = true
            onceLock.unlock()
            if first { exp.fulfill() }
        })
        defer { engine.stop() }
        // Give the stream a moment to establish.
        try await Task.sleep(nanoseconds: 500_000_000)
        try "hello".write(toFile: sub.appendingPathComponent("note.txt").path, atomically: true, encoding: .utf8)
        // Wait up to 10s for the event.
        await fulfillment(of: [exp], timeout: 10)
        engine.stop()
    }

    /// Required v4.0 coverage: a change to a file at the root level is activity.
    func testFSEventsDeliversActivityForRootLevelFile() async throws {
        let base = try makeTempBase("fsevents-root")
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let exp = expectation(description: "root-level activity fired")
        let onceLock = NSLock()
        var fulfilled = false
        engine.start(onActivity: {
            onceLock.lock()
            let first = !fulfilled
            fulfilled = true
            onceLock.unlock()
            if first { exp.fulfill() }
        })
        defer { engine.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        try "top".write(toFile: base.appendingPathComponent("top.txt").path, atomically: true, encoding: .utf8)
        await fulfillment(of: [exp], timeout: 10)
        engine.stop()
    }
}

final class WatcherLifecycleTests: XCTestCase {
    /// Audit v2.2.2: stop/start lifecycle must be safe to reuse a source.
    func testStartStopStartDeliversAgain() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-lifecycle-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let source = FSEventsChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        let exp = expectation(description: "second lifecycle delivers")
        // One atomic write can deliver SEVERAL file events (the .sb-* temp file
        // plus the rename); fulfill only once — like the sibling tests above.
        let onceLock = NSLock()
        var fulfilled = false
        let fulfillOnce = {
            onceLock.lock()
            let first = !fulfilled
            fulfilled = true
            onceLock.unlock()
            if first { exp.fulfill() }
        }
        engine.start(onActivity: { fulfillOnce() })
        try await Task.sleep(nanoseconds: 400_000_000)
        engine.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        engine.start(onActivity: { fulfillOnce() })
        try await Task.sleep(nanoseconds: 400_000_000)
        try "again".write(toFile: base.appendingPathComponent("sub/z.txt").path, atomically: true, encoding: .utf8)
        await fulfillment(of: [exp], timeout: 10)
        engine.stop()
    }

    /// Stop must reach the underlying change source.
    func testStopForwardsToSource() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-lifecycle-stop-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = FakeChangeSource()
        let engine = WatcherEngine(rootPath: base.path, source: source)
        engine.start(onActivity: {})
        XCTAssertEqual(source.startedPaths, [engine.realRoot])
        engine.stop()
        XCTAssertEqual(source.stopCount, 1)
    }
}
