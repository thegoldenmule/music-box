import Foundation

/// Caller-supplied clock: backoff/expiry are testable without waiting.
public struct AdminGate: Sendable, Equatable {
    /// How long a session survives without being touched. The spec's ~300s.
    public static let idleTimeout: TimeInterval = 300

    /// Wrong guesses free before backoff — mistyping twice shouldn't be punished.
    public static let freeAttempts = 3

    /// First wait after the free attempts run out. Doubles per failure.
    public static let baseDelay: TimeInterval = 5

    /// Ceiling on the wait — unbounded doubling bricks the app before it deters a kid.
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

    /// How long until another attempt is allowed, or `nil` if one is allowed now.
    public func retryDelay(at now: Date) -> TimeInterval? {
        guard let blockedUntil, now < blockedUntil else { return nil }
        return blockedUntil.timeIntervalSince(now)
    }

    public func isAcceptingAttempts(at now: Date) -> Bool {
        retryDelay(at: now) == nil
    }

    // MARK: - Writing

    /// Correct passcode clears the backoff: proven identity resets prior failures.
    public mutating func succeeded(at now: Date) {
        failedAttempts = 0
        blockedUntil = nil
        expiresAt = now + Self.idleTimeout
    }

    /// Never says why it was wrong; no reset — one a kid could drive isn't a gate.
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

    /// No-op on a closed session, so activity can't nudge a stale gate back open.
    public mutating func touch(at now: Date) {
        guard isOpen(at: now) else { return }
        expiresAt = now + Self.idleTimeout
    }

    /// Doesn't clear backoff — backgrounding after failures keeps it.
    public mutating func close() {
        expiresAt = nil
    }
}
