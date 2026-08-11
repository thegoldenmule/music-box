import Foundation

/// One agreement, as the rule below needs it.
///
/// A value rather than the `@Model`, for the reason `BindingResolver` takes
/// `AccountState` instead of asking CloudKit: the decision is the part worth
/// exhausting in tests, and it should not need a store to reach.
public struct RecordedConsent: Sendable, Equatable {
    public let scope: ConsentScope
    public let kidIDs: Set<UUID>

    public init(scope: ConsentScope, kidIDs: Set<UUID>) {
        self.scope = scope
        self.kidIDs = kidIDs
    }
}

extension ConsentRecord {
    /// This row as the rule sees it, or `nil` when the stored scope does not read
    /// back.
    ///
    /// **A row whose scope is unreadable covers nothing** — the same fail-closed
    /// direction every other defensive read in this store takes, because guessing a
    /// scope would let an agreement about one thing stand in for a larger one.
    ///
    /// **Defence in depth, and unreachable today**, which is worth saying rather
    /// than leaving as an implied hazard: the local writer takes a typed
    /// `ConsentScope`, and `SyncApply.applyConsent` *defers* an arriving record
    /// whose `scopeRaw` does not read back instead of storing it. So no path
    /// currently puts such a row on disk, and there is no test here that
    /// constructs one, because it cannot be constructed. It stays because the
    /// cost is a `guard` and the thing on the other side of it is consent.
    public var recorded: RecordedConsent? {
        guard let scope else { return nil }
        return RecordedConsent(scope: scope, kidIDs: Set(kidIDs))
    }
}

// MARK: -

/// Whether an invitation may be offered yet.
///
/// **Guideline 5.1.4 is explicit that a parental gate is not parental consent**,
/// so the passcode a parent has already entered does not answer this. What answers
/// it is a row — see ``ConsentRecord`` — and what this decides is whether the row
/// that exists actually covers the invitation about to be sent.
///
/// **Pure, and beside the record rather than inside the screen.** The interesting
/// case is not the first invitation, it is the second: consent given when a family
/// had one child says nothing about the child added next month, and a screen that
/// remembers "they already agreed" would hand out a second child's search history
/// on the strength of an agreement about their sibling. That is a rule worth
/// testing exhaustively, and there is no app test target.
public enum Consent {
    /// Which children an invitation of this scope would expose.
    ///
    /// The asymmetry is the design. `shareHousehold` exposes **every** child,
    /// because there is no per-adult scoping anywhere in this design — a
    /// participant holds the household zone and both zones of every kid.
    /// `childAccountParticipates` exposes exactly one, because that is the whole
    /// point of the per-kid zone pair.
    public static func kidsExposed(
        by scope: ConsentScope,
        householdKids: [UUID],
        subject: UUID? = nil
    ) -> Set<UUID> {
        switch scope {
        case .shareHousehold:
            return Set(householdKids)
        case .childAccountParticipates:
            // A child who is not in this household is not exposed by anything —
            // `SharePlan.grants` returns nothing for them, so no invitation
            // exists to consent to.
            guard let subject, householdKids.contains(subject) else { return [] }
            return [subject]
        }
    }

    /// The children this invitation would expose that no agreement covers.
    ///
    /// Empty means the invitation may go. Non-empty is the list a consent screen
    /// has to name out loud — "everything about Robin **and Sam**" is a different
    /// sentence from the one the parent agreed to.
    public static func kidsNotCovered(
        scope: ConsentScope,
        householdKids: [UUID],
        subject: UUID? = nil,
        recorded: [RecordedConsent]
    ) -> Set<UUID> {
        let exposed = kidsExposed(by: scope, householdKids: householdKids, subject: subject)

        // **Matched on scope and never across it.** The two scopes are different
        // asks and the child-account one is the larger — it makes a minor's own
        // Apple Account a share participant. Letting either stand in for the other
        // is the one shortcut that would make the row meaningless.
        let covered = recorded
            .filter { $0.scope == scope }
            .reduce(into: Set<UUID>()) { $0.formUnion($1.kidIDs) }

        return exposed.subtracting(covered)
    }

    /// Whether this invitation is covered.
    ///
    /// **A household with no children is covered by nothing and needs nothing.**
    /// There is no child data to agree about yet, so an invitation is a household
    /// with a roster in it — and the moment a child is added, the next invitation
    /// asks. That falls out of the set arithmetic rather than being a case.
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
