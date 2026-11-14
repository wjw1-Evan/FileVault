import XCTest
@testable import FileVaultCore

final class Counter {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class DebouncerTests: XCTestCase {
    func testTrailingFireAfterQuiet() {
        let exp = expectation(description: "fired after quiet")
        let c = Counter()
        let d = Debouncer(quietInterval: 0.2, maxWait: 5) { _ in
            c.inc()
            exp.fulfill()
        }
        d.touch("k")
        d.touch("k")
        d.touch("k")
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(c.value(), 1)
        d.cancelAll()
    }

    func testRepeatedTouchReschedules() {
        let exp = expectation(description: "fires once despite repeats")
        let c = Counter()
        let d = Debouncer(quietInterval: 0.2, maxWait: 10) { _ in
            c.inc()
            exp.fulfill()
        }
        for i in 0..<7 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.1) {
                d.touch("r")
            }
        }
        wait(for: [exp], timeout: 4)
        XCTAssertEqual(c.value(), 1)
        d.cancelAll()
    }

    func testMaxWaitCap() {
        let exp = expectation(description: "maxwait cap fires in time")
        let start = Date()
        let d = Debouncer(quietInterval: 1.0, maxWait: 0.3) { _ in
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 1.0)
            exp.fulfill()
        }
        d.touch("m")
        wait(for: [exp], timeout: 2)
        d.cancelAll()
    }

    func testFireNowImmediate() {
        let exp = expectation(description: "fireNow immediate")
        let d = Debouncer(quietInterval: 5, maxWait: 60) { _ in
            exp.fulfill()
        }
        d.touch("f")
        d.fireNow(key: "f")
        wait(for: [exp], timeout: 1)
        d.cancelAll()
    }
}
