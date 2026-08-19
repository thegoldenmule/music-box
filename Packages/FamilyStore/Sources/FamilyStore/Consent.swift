import Foundation

/// A value, not the `@Model` — the rule below deserves tests with no store.
public struct RecordedConsent: Sendable, Equatable {
    public let scope: ConsentScope
    public let kidIDs: Set<UUID>

    public init(scope: ConsentScope, kidIDs: Set<UUID>) {
        self.scope = scope
        self.kidIDs = kidIDs
    }
}

extension ConsentRecord {
    /// `nil` on an unreadable scope — fails closed rather than guessing one.
    public var recorded: RecordedConsent? {
        guard let scope else { return nil }
        return RecordedConsent(scope: scope, kidIDs: Set(kidIDs))
    }
}

// MARK: -

/// A parental gate is not consent (5.1.4) — coverage is per child, not per family.
public enum Consent {
    /// `shareHousehold` exposes every child; `childAccountParticipates` exposes one.
    public static func kidsExposed(
        by scope: ConsentScope,
        householdKids: [UUID],
        subject: UUID? = nil
    ) -> Set<UUID> {
        switch scope {
        case .shareHousehold:
            return Set(householdKids)
        case .childAccountParticipates:
            // Not in this household means nothing to grant, so nothing to consent to.
            guard let subject, householdKids.contains(subject) else { return [] }
            return [subject]
        }
    }

    /// Empty means the invitation may go; non-empty must be named on screen.
    public static func kidsNotCovered(
        scope: ConsentScope,
        householdKids: [UUID],
        subject: UUID? = nil,
        recorded: [RecordedConsent]
    ) -> Set<UUID> {
        let exposed = kidsExposed(by: scope, householdKids: householdKids, subject: subject)

        // Matched on scope, never across it — the two are different-sized asks.
        let covered = recorded
            .filter { $0.scope == scope }
            .reduce(into: Set<UUID>()) { $0.formUnion($1.kidIDs) }

        return exposed.subtracting(covered)
    }

    /// A childless household needs nothing — falls out of the set arithmetic.
    public static func isGiven(
        scope: ConsentScope,
        householdKids: [UUID],
        subject: UUID? = nil,
        recorded: [RecordedConsent]
    ) -> Bool {
        kidsNotCovered(
            scope: scope, householdKids: householdKids, subject: subject, recorded: recorded
        ).isEmpty
    }
}
