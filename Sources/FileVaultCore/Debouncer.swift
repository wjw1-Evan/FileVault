import Foundation

/// Trailing-edge debounce with a max-wait cap (FR-04).
public final class Debouncer: @unchecked Sendable {
    /// Mutable at runtime (settings can change the quiet window).
    public private(set) var quietInterval: TimeInterval
    private let maxWait: TimeInterval
    private let intervalLock = NSLock()
    private let onFired: @Sendable (String) -> Void
    private let lock = NSLock()
    private var timers: [String: DispatchSourceTimer] = [:]
    private var firstTouch: [String: Date] = [:]

    public init(quietInterval: TimeInterval, maxWait: TimeInterval, onFired: @escaping @Sendable (String) -> Void) {
        self.quietInterval = quietInterval
        self.maxWait = maxWait
        self.onFired = onFired
    }

    /// Update the quiet window at runtime; applies to subsequent touches.
    public func setQuietInterval(_ interval: TimeInterval) {
        intervalLock.lock()
        quietInterval = max(0.1, interval)
        intervalLock.unlock()
    }

    public var currentQuietInterval: TimeInterval {
        intervalLock.lock()
        defer { intervalLock.unlock() }
        return quietInterval
    }

    public func touch(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if firstTouch[key] == nil { firstTouch[key] = now }
        let elapsed = now.timeIntervalSince(firstTouch[key]!)
        let remaining = maxWait - elapsed
        if remaining <= 0 {
            if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) maxwait fireNow key=\(key) elapsed=\(elapsed)")
            }
            // We are already holding the lock: fire without re-acquiring
            // (the public fireNow would deadlock here — audit v2.2.2).
            fireNowLocked(key: key)
            return
        }
        timers[key]?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + min(currentQuietInterval, remaining))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timers[key] = nil
            self.firstTouch[key] = nil
            self.lock.unlock()
            if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) timer fired key=\(key)")
            }
            self.onFired(key)
        }
        timers[key] = t
        t.resume()
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) debounced key=\(key) quiet=\(quietInterval)")
        }
    }

    /// Fire immediately for a key (manual flush). Acquires the lock itself.
    public func fireNow(key: String) {
        lock.lock()
        fireNowLocked(key: key)
        lock.unlock()
    }

    /// Callers already holding `lock` must use this variant (non-reentrant NSLock).
    private func fireNowLocked(key: String) {
        timers[key]?.cancel()
        timers[key] = nil
        firstTouch[key] = nil
        onFired(key)
    }

    /// Drop all pending timers (e.g. root removed).
    public func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        for t in timers.values { t.cancel() }
        timers.removeAll()
        firstTouch.removeAll()
    }
}
