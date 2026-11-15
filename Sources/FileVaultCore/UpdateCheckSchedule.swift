import Foundation

/// Recurring update-check cadence (FR-20).
///
/// Extracted from `AppState` so the scheduling rules can be unit-tested without
/// waiting on real timers. v3.1.4: a tick that found auto-checking DISABLED used
/// to `return` without rescheduling, which permanently killed the chain until
/// the next app launch — re-enabling the toggle appeared to do nothing.
public enum UpdateCheckSchedule {
    /// First (silent) check shortly after launch.
    public static let launchDelay: TimeInterval = 20
    /// Healthy cadence once a check has succeeded (v4.0.1: hourly instead of daily).
    public static let successInterval: TimeInterval = 3600
    /// Retry cadence while checks keep failing (flaky networks must not starve updates).
    public static let failureInterval: TimeInterval = 600
    /// Idle poll cadence while auto-checking is switched off. The timer keeps
    /// running so a re-enabled toggle (or a hand-edited config) recovers on its
    /// own; the UI toggle additionally resumes checking immediately.
    public static let disabledInterval: TimeInterval = 3600

    /// Whether a tick should hit the network.
    public static func shouldCheck(autoCheckEnabled: Bool) -> Bool {
        autoCheckEnabled
    }

    /// Delay before the next tick. Never returns a value that stops the chain.
    public static func nextDelay(afterFailed: Bool, autoCheckEnabled: Bool) -> TimeInterval {
        guard autoCheckEnabled else { return disabledInterval }
        return afterFailed ? failureInterval : successInterval
    }
}
