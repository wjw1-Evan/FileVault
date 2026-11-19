import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 5: cancelling a DispatchSourceTimer does not stop
/// an event handler GCD has ALREADY queued. The stale handler used to wipe
/// the NEXT schedule's state (firstTouch anchor restart + premature fire).
/// The token guard makes a stale handler a no-op; these tests pin the
/// observable contract. (Forcing the exact queued-but-unrun interleave
/// deterministically would need an injectable timer queue — the harm was
/// bounded (≤ one quiet window of extra commit delay), so Debouncer keeps
/// its production queue.)
final class DebouncerStaleHandlerTests: XCTestCase {

    private final class FireLog: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date] = []
        func record() { lock.lock(); times.append(Date()); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
        var first: Date? { lock.lock(); defer { lock.unlock() }; return times.first }
        var last: Date? { lock.lock(); defer { lock.unlock() }; return times.last }
    }

    /// Rapid rescheduling must never fire while the touches keep coming:
    /// under the old code an already-queued stale handler could fire
    /// mid-stream and wipe the new schedule's state. With the token guard
    /// the green here is stable — the guard makes stale handlers no-ops.
    func testRapidReschedulingNeverFiresPrematurely() {
        let base = TestSupport.makeTempDir("deb-stale")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let log = FireLog()
        let deb = Debouncer(quietInterval: 0.8, maxWait: 5, onFired: { _ in log.record() })

        for _ in 0..<200 {
            deb.touch("k")
        }
        XCTAssertEqual(log.count, 0,
                       "200 rapid reschedules must not let a stale queued handler fire early")
        XCTAssertNil(log.first)
        deb.cancel(key: "k")
    }

    /// The stale-handler race's real harm was wiping firstTouch, which
    /// re-anchored the maxWait window. After cancel the state must be fully
    /// clear so the next stream starts a fresh window (not a leaked one).
    func testCancelClearsAllScheduleState() {
        let log = FireLog()
        let deb = Debouncer(quietInterval: 0.05, maxWait: 1, onFired: { _ in log.record() })
        deb.touch("k")
        deb.cancel(key: "k")
        // Re-touch right away: a clean slate means this fires on ITS OWN
        // schedule ~0.05s later — not instantly, and not never.
        let start = Date()
        deb.touch("k")
        // Wait for the fire without spinning the test runner hot.
        let exp = expectation(description: "fired")
        DispatchQueue.global().async {
            while log.count == 0 && Date().timeIntervalSince(start) < 3 { usleep(20_000) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(log.count, 1)
        if let first = log.first {
            XCTAssertGreaterThanOrEqual(first.timeIntervalSince(start), 0.03,
                                         "the fresh schedule owns its own quiet window")
        }
    }

    /// maxWait must still cap a stream that never goes quiet (the invariant
    /// the firstTouch anchor exists to enforce).
    func testMaxWaitStillCapsAContinuousStream() {
        let log = FireLog()
        let deb = Debouncer(quietInterval: 0.15, maxWait: 0.6, onFired: { _ in log.record() })
        let start = Date()
        let exp = expectation(description: "fired")
        DispatchQueue.global().async {
            while log.count == 0 && Date().timeIntervalSince(start) < 5 { usleep(50_000) }
            exp.fulfill()
        }
        for _ in 0..<40 {
            deb.touch("k")
            usleep(60_000)   // 60 ms < quiet 150 ms → never quiet
        }
        wait(for: [exp], timeout: 6)
        XCTAssertNotNil(log.first)
        if let first = log.first {
            XCTAssertLessThanOrEqual(first.timeIntervalSince(start), 1.2,
                                     "maxWait 0.6 + quiet 0.15 + scheduling slack")
        }
        deb.cancel(key: "k")
    }
}
