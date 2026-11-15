import XCTest
import CoreServices
@testable import FileVaultCore

final class WatcherEngineTests: XCTestCase {
    /// Real FSEvents -> activity callback fires for a first-level subfolder event.
    func testFSEventsDeliversActivityForSubfolderEvent() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-test-fsevents-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sub = base.appendingPathComponent("sub1")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let exp = expectation(description: "activity fired")
        let onceLock = NSLock()
        var fulfilled = false
        engine.start(onActivity: { name in
            // FSEvents may deliver several batches; fulfill only once.
            onceLock.lock()
            let first = !fulfilled
            fulfilled = true
            onceLock.unlock()
            if first { exp.fulfill() }
        }, onRootStructureChanged: {
        })
        defer { engine.stop() }
        // Give the stream a moment to establish.
        try await Task.sleep(nanoseconds: 500_000_000)
        try "hello".write(toFile: sub.appendingPathComponent("note.txt").path, atomically: true, encoding: .utf8)
        // Wait up to 10s for the event.
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
        // plus the rename); fulfill only once — like the sibling test above.
        let onceLock = NSLock()
        var fulfilled = false
        let fulfillOnce = {
            onceLock.lock()
            let first = !fulfilled
            fulfilled = true
            onceLock.unlock()
            if first { exp.fulfill() }
        }
        engine.start(onActivity: { _ in fulfillOnce() }, onRootStructureChanged: {})
        try await Task.sleep(nanoseconds: 400_000_000)
        engine.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        engine.start(onActivity: { _ in fulfillOnce() }, onRootStructureChanged: {})
        try await Task.sleep(nanoseconds: 400_000_000)
        try "again".write(toFile: base.appendingPathComponent("sub/z.txt").path, atomically: true, encoding: .utf8)
        await fulfillment(of: [exp], timeout: 10)
        engine.stop()
    }
}
