import Foundation
import PolicyEngine

/// A stored fact plus today's verdict on it.
///
/// The two disagree constantly, and the disagreement is the most useful thing on
/// the parent's screen: *they played this forty times and you denied the artist
/// on Tuesday.* The fact is history and immutable; ``now`` is a fresh question
/// asked of today's policy.
public struct Annotated<Fact: Sendable>: Sendable {
    public let fact: Fact

    /// What the engine says **now**, or `nil` when it could not honestly be
    /// asked — see ``AncestryConfidence/unknown``.
    public let now: Verdict?

    public let confidence: AncestryConfidence

    public init(fact: Fact, now: Verdict?, confidence: AncestryConfidence) {
        self.fact = fact
        self.now = now
        self.confidence = confidence
    }

    /// Whether the kid could play this today. `nil` when there is no verdict,
    /// which a screen must render as a third state and never as "no".
    public var isAllowedNow: Bool? { now?.isAllowed }
}

/// How much the annotator actually knew.
///
/// The engine is pure and the caller supplies everything, so a verdict is only
/// as good as what a stored row kept. This is the difference between a report
/// that states a fact and one that states a guess in the same typeface.
public enum AncestryConfidence: Sendable, Hashable {
    /// Everything the engine consulted was on the row. The verdict is exact.
    case exact

    /// Something the engine consulted was missing, but not the thing that
    /// decided. Provisional in the sense the whole codebase uses: a deny may
    /// fail open, `allowOnly` fails closed. Shown as "probably", never as a
    /// fact.
    case itemOnly

    /// The missing input is the one that would decide. No verdict is offered at
    /// all, because the only one available would be an artifact of our own
    /// ignorance rather than a statement about the item.
    case unknown
}

/// Re-judges a stored row against today's policy.
///
/// Pure, synchronous, offline. Every input comes from columns the row already
/// carries — which is the property that lets a parent read a whole week on a
/// plane, and the reason `rating` is stored at all.
public enum ReviewAnnotator {
    /// What a row knows about its item, and what it only appears to.
    ///
    /// Two flags rather than inspecting ``Item`` directly, because both of the
    /// absences that matter are invisible from the value: an empty `ancestors`
    /// looks the same whether the item has no containers or whether nobody
    /// resolved them, and a `nil` rating looks the same whether the catalog said
    /// so or nobody asked.
    public struct Knowledge: Sendable {
        public var item: Item

        /// Whether `item.ancestors` is everything this item has.
        public var ancestryIsComplete: Bool

        /// Whether `item.rating` is a fact about the item rather than an
        /// absence of information. See ``StoredRating``.
        public var ratingIsRecorded: Bool

        public init(item: Item, ancestryIsComplete: Bool, ratingIsRecorded: Bool) {
            self.item = item
            self.ancestryIsComplete = ancestryIsComplete
            self.ratingIsRecorded = ratingIsRecorded
        }
    }

    public static func annotate<Fact: Sendable>(
        _ fact: Fact,
        knowing knowledge: Knowledge,
        with engine: PolicyEngine
    ) -> Annotated<Fact> {
        let verdict = engine.evaluate(knowledge.item)
        let confidence = confidence(in: verdict, knowing: knowledge, under: engine.policy)
        return Annotated(
            fact: fact,
            now: confidence == .unknown ? nil : verdict,
            confidence: confidence
        )
    }

    /// How much to trust one verdict, given what produced it.
    ///
    /// The asymmetries here are the point, and each one runs the same way: more
    /// information can only ever *add* a deny, never remove one.
    static func confidence(
        in verdict: Verdict,
        knowing knowledge: Knowledge,
        under policy: Policy
    ) -> AncestryConfidence {
        // A deny that matched is final. The entry is on the list and the item or
        // one of its known containers is what it names; nothing we failed to
        // resolve could unmake that.
        if case .blocked(.deniedByParent) = verdict {
            return .exact
        }

        switch policy.mode {
        case .reportOnly:
            // Nothing but a deny can decide, and there was not one.
            return .exact

        case .allowOnly:
            // Ratings are never consulted here: a parent who hand-picked
            // something meant it, explicit or not. Only lineage can change the
            // answer, and only in one direction — an unresolved container might
            // be on the allow list.
            switch verdict {
            case .allowed: return .exact
            case .blocked: return knowledge.ancestryIsComplete ? .exact : .itemOnly
            }

        case .denyPlusAuto:
            return denyPlusAutoConfidence(in: verdict, knowing: knowledge, under: policy)
        }
    }

    private static func denyPlusAutoConfidence(
        in verdict: Verdict,
        knowing knowledge: Knowledge,
        under policy: Policy
    ) -> AncestryConfidence {
        let item = knowledge.item

        // Artists and playlists carry no rating anywhere in the catalog, so the
        // rating path never runs for them and its absence costs nothing.
        let ratingCouldDecide: Bool
        switch item.id.kind {
        case .artist, .playlist: ratingCouldDecide = false
        case .album, .song: ratingCouldDecide = true
        }

        // An allow entry on the item itself short-circuits the rating check, so
        // a row that matched one is exact whatever else is missing.
        let isExplicitlyAllowed = policy.entries.contains {
            $0.kind == .allow && $0.id == item.id
        }

        if ratingCouldDecide, !isExplicitlyAllowed, !knowledge.ratingIsRecorded {
            // The rating is what would decide and nobody wrote it down. Whatever
            // `UnratedBehavior` says here is a statement about our records, not
            // about the item, and a parent reading "they can't play this any
            // more" would be reading our own gap back at themselves.
            return .unknown
        }

        // `inheritFromAncestor` reaches for ancestor ratings, which no row
        // stores. It only runs when the item's own rating is absent — a recorded
        // absence, at this point, since the unknown case returned above.
        if policy.unratedBehavior == .inheritFromAncestor,
            ratingCouldDecide,
            item.rating == nil,
            !knowledge.ancestryIsComplete
        {
            return .unknown
        }

        switch verdict {
        case .allowed:
            // A container we never resolved could be denied.
            return knowledge.ancestryIsComplete ? .exact : .itemOnly
        case .blocked:
            // Blocked on a rating or on the allow-list rules; more lineage could
            // only pile on more reasons.
            return .exact
        }
    }
}

// MARK: - What each kind of row knows

extension PlayEvent {
    /// A play row's own account of itself.
    ///
    /// Ancestry counts as complete when both containers are there. A song whose
    /// album never resolved could still belong to a denied album, and saying so
    /// is cheaper than a report that quietly overstates its certainty.
    public var knowledge: ReviewAnnotator.Knowledge {
        var ancestors: [Ancestor] = []
        if let albumID { ancestors.append(Ancestor(id: albumID)) }
        if let artistID { ancestors.append(Ancestor(id: artistID)) }
        return ReviewAnnotator.Knowledge(
            item: Item(id: songID, rating: rating.rating, ancestors: ancestors),
            ancestryIsComplete: albumID != nil && artistID != nil,
            ratingIsRecorded: rating.isRecorded
        )
    }
}

extension BlockEvent {
    /// A block row's own account of itself.
    ///
    /// Only the artist is stored, never the album — so a *song* block is never
    /// fully resolved, whatever came back. An artist block has no containers to
    /// miss and is complete by construction.
    public var knowledge: ReviewAnnotator.Knowledge {
        let ancestors = artistID.map { [Ancestor(id: $0)] } ?? []
        let ancestryIsComplete: Bool =
            switch itemID.kind {
            case .artist: true
            case .album, .playlist: artistID != nil
            case .song: false
            }
        return ReviewAnnotator.Knowledge(
            item: Item(id: itemID, rating: rating.rating, ancestors: ancestors),
            ancestryIsComplete: ancestryIsComplete,
            ratingIsRecorded: rating.isRecorded
        )
    }
}
