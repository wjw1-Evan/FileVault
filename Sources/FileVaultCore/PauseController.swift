import Foundation

/// Per-root pause flags (FR-13).
///
/// v4.2.22: the global "pause auto-commit" switch is gone — auto-commit is an
/// always-on promise, not a setting. A single folder can still be paused (for
/// example while an external disk is being moved), but the app itself never
/// stops watching everything.
public final class PauseController: @unchecked Sendable {
    private let lock = NSLock()
    private var pausedRoots: Set<String> = []

    public init() {}

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
        return pausedRoots.contains(root)
    }
}
