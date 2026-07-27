import Foundation

/// Whether the admin is open, and what a wrong passcode costs.
///
/// A value type with the clock supplied by the caller: no timers, no `Date()`
/// inside, so every backoff and expiry rule is testable without waiting. The
/// app holds one of these and advances it.
///
/// **Absent means locked.** There is no partially-unlocked state — a session is
/// open or it is not, and closing it is always safe.
public struct AdminGate: Sendable, Equatable {
    /// How long a session survives without being touched. The spec's ~300s.
    public static let idleTimeout: TimeInterval = 300

    /// Wrong guesses allowed before waiting starts. The first few are honest
    /// mistakes; a parent mistyping twice should not be punished.
    public static let freeAttempts = 3

    /// First wait after the free attempts run out. Doubles per failure.
    public static let baseDelay: TimeInterval = 5

    /// Ceiling on the wait. Unbounded doubling turns a forgotten passcode into
    /// a bricked app faster than it deters a kid, and the kid has all
    /// afternoon either way.
    public static let maxDelay: TimeInterval = 300

    public private(set) var failedAttempts = 0
    public private(set) var blockedUntil: Date?
    public private(set) var expiresAt: Date?

    public init() {}

    // MARK: - Reading

    public func isOpen(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now < expiresAt
    }

    /// How long until another attempt is allowed, or `nil` when one is allowed
    /// now.
    public func retryDelay(at now: Date) -> TimeInterval? {
        guard let blockedUntil, now < blockedUntil else { return nil }
        return blockedUntil.timeIntervalSince(now)
    }

    public func isAcceptingAttempts(at now: Date) -> Bool {
        retryDelay(at: now) == nil
    }

    // MARK: - Writing

    /// A correct passcode. Clears the backoff — the parent proved they are the
    /// parent, so previous failures stop counting.
    public mutating func succeeded(at now: Date) {
        failedAttempts = 0
        blockedUntil = nil
        expiresAt = now + Self.idleTimeout
    }

    /// A wrong passcode. Returns how long the caller must now wait, if at all.
    ///
    /// Deliberately says nothing about *why* it was wrong — no length hint, no
    /// "first digit correct". And there is no reset path here at all: a reset a
    /// kid could drive is not a gate. Losing the passcode is a dead end, which
    /// is the argument for offering biometrics early rather than a back door.
    @discardableResult
    public mutating func failed(at now: Date) -> TimeInterval? {
        failedAttempts += 1
        expiresAt = nil

        let over = failedAttempts - Self.freeAttempts
        guard over > 0 else { return nil }

        let delay = min(Self.baseDelay * pow(2, Double(over - 1)), Self.maxDelay)
        blockedUntil = now + delay
        return delay
    }

    /// Extends the session — called on activity inside the admin.
    ///
    /// Does nothing to a closed session. Otherwise a stale gate could be nudged
    /// back open without anyone entering anything.
    public mutating func touch(at now: Date) {
        guard isOpen(at: now) else { return }
        expiresAt = now + Self.idleTimeout
    }

    /// Closes the session. Called on background, and on leaving the admin.
    ///
    /// Does not clear the backoff: someone who just failed five times and sent
    /// the app to the background should not come back to a clean slate.
    public mutating func close() {
        expiresAt = nil
    }
}
