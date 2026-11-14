import Foundation

/// Global + per-root pause flags (FR-13).
public final class PauseController: @unchecked Sendable {
    private let lock = NSLock()
    private var globalPaused = false
    private var pausedRoots: Set<String> = []

    public init() {}

    public var isGloballyPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return globalPaused
    }

    public func setGlobalPaused(_ p: Bool) {
        lock.lock(); defer { lock.unlock() }
        globalPaused = p
    }

    public func setPaused(_ p: Bool, forRoot root: String) {
        lock.lock(); defer { lock.unlock() }
        if p {
            pausedRoots.insert(root)
        } else {
            pausedRoots.remove(root)
        }
    }

    public func isPaused(root: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return globalPaused || pausedRoots.contains(root)
    }
}
