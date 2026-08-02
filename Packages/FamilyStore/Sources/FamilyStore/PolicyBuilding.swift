import Foundation
import PolicyEngine

/// A policy read out of storage, plus whatever could not be read.
///
/// Two values rather than one because the failure is not silent: an unreadable
/// row is something the admin should be able to show a parent, not something
/// the engine quietly works around.
public struct PolicyBuild: Sendable {
    public let policy: Policy

    /// Entry rows whose stored strings did not read back cleanly. Empty in
    /// every normal case — these strings are written by our own code from typed
    /// enums, so a row lands here only through corruption or a schema we did
    /// not anticipate.
    public let unreadableEntryIDs: [UUID]

    /// Suggestion rows that did not read back cleanly.
    ///
    /// A separate field rather than more UUIDs in the one above, because the
    /// admin resolves those against `kid.entries` and a suggestion's id would
    /// look up to nothing there. Two namespaces, two lists.
    public let unreadableSuggestionIDs: [UUID]

    public var hasUnreadableEntries: Bool { !unreadableEntryIDs.isEmpty }

    public var hasUnreadableSuggestions: Bool { !unreadableSuggestionIDs.isEmpty }

    public init(
        policy: Policy,
        unreadableEntryIDs: [UUID] = [],
        unreadableSuggestionIDs: [UUID] = []
    ) {
        self.policy = policy
        self.unreadableEntryIDs = unreadableEntryIDs
        self.unreadableSuggestionIDs = unreadableSuggestionIDs
    }
}

extension Kid {
    /// Builds this kid's policy from stored values.
    ///
    /// The one read on the hot path. Both `mode` and `unratedBehavior` are used
    /// exactly as stored; no default is substituted here or anywhere below.
    ///
    /// **Unreadable rows fail closed.** A row whose `kind` is unreadable but
    /// whose identifier still parses is used as a *deny*, not dropped. The
    /// asymmetry is deliberate: a phantom deny hides one item a parent meant to
    /// allow, which is visible and fixable, while dropping a real deny silently
    /// unblocks something a parent explicitly refused. A row whose `itemKind`
    /// is unreadable cannot be turned into a `CatalogID` at all and is dropped
    /// — that one is reported and nothing else can be done with it.
    ///
    /// **Live suggestions are folded in as allows.** That is what makes a
    /// suggested item reachable at every level, and it happens here rather than
    /// in the engine so that ``PolicyEngine`` stays a pure function of a
    /// ``Policy`` with one kind of entry in it. Three properties matter and all
    /// three are the engine's, not this function's:
    ///
    /// - A **deny still wins**. `evaluate` checks the deny set before it looks at
    ///   the mode, so nothing added here can outrank a parent's refusal — a
    ///   suggestion cannot be used to walk something back onto the shelf.
    /// - In `.denyPlusAuto` an allow on a **container** does not lift the rating
    ///   check off its children, so a suggested album's explicit tracks stay
    ///   blocked. Deliberate, and the same rule that stops allowing an artist
    ///   from permitting their next explicit release.
    /// - In `.allowOnly` an allow-listed *ancestor* is enough and no rating is
    ///   consulted, so those same tracks do play. The inversion is pre-existing
    ///   allow-list behavior; suggestions only make it visible, which is why the
    ///   suggest sheet states the playable count up front.
    ///
    /// **Dismissed suggestions contribute nothing** — see ``SuggestionRecord``
    /// for why the allow has to go with the tile rather than outliving it.
    public func buildPolicy() -> PolicyBuild {
        var built: [PolicyEntry] = []
        var unreadable: [UUID] = []
        var unreadableSuggestions: [UUID] = []

        // **Retracted rows are not part of the policy, and are still here.** A
        // removal is a tombstone rather than a delete — see
        // `PolicyEntryRecord.retractedAt` — so the filtering happens on read.
        // The skew rule inside `isLive` is what makes a deny and a withdrawal
        // that arrive from two devices at nearly the same moment resolve in the
        // direction that hides an item rather than the one that unblocks it.
        for record in entries where record.isLive {
            if let entry = record.entry {
                built.append(entry)
                continue
            }

            unreadable.append(record.id)

            if let itemKind = ItemKind(rawValue: record.itemKind) {
                built.append(.deny(CatalogID(itemKind, record.catalogID)))
            }
        }

        // **The asymmetry with the loop above is the point.** An unreadable
        // policy row becomes a deny, because dropping a real deny silently
        // unblocks something a parent refused. Doing that here would be
        // backwards: a deny wins in every mode, so a corrupt *suggestion* would
        // turn into a family-wide block on an item nobody objected to — a worse
        // failure than the one the rule prevents. Suggestions only ever add, so
        // an unreadable one is dropped and reported.
        for record in suggestions where !record.isDismissed {
            guard record.target != nil else {
                unreadableSuggestions.append(record.id)
                continue
            }
            built.append(contentsOf: record.allowedIDs.map(PolicyEntry.allow))
        }

        return PolicyBuild(
            policy: Policy(
                // Resolved from the decision rows, falling back to the cached
                // columns — never the columns directly. See
                // ``Kid/effectiveMode``. The invariant the spec states is that
                // no default is substituted at evaluation time, and that still
                // holds: the fallback is the value a parent actually set, not a
                // constant.
                mode: effectiveMode,
                entries: built,
                unratedBehavior: effectiveUnratedBehavior
            ),
            unreadableEntryIDs: unreadable,
            unreadableSuggestionIDs: unreadableSuggestions
        )
    }

    /// An engine for this kid, built once and reused across a page of results.
    ///
    /// Discards the unreadable-row report. Use ``buildPolicy()`` where a
    /// surface can show it.
    public func makeEngine() -> PolicyEngine {
        PolicyEngine(policy: buildPolicy().policy)
    }
}
