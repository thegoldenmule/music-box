import Foundation
import PolicyEngine

/// A stored fact plus today's verdict — the two disagree, and that's the point.
public struct Annotated<Fact: Sendable>: Sendable {
    public let fact: Fact

    /// The verdict now, or `nil` when asking honestly isn't possible.
    public let now: Verdict?

    public let confidence: AncestryConfidence

    public init(fact: Fact, now: Verdict?, confidence: AncestryConfidence) {
        self.fact = fact
        self.now = now
        self.confidence = confidence
    }

    /// `nil` means no verdict; render as a third state, never as "no".
    public var isAllowedNow: Bool? { now?.isAllowed }
}

/// How much the annotator knew — a verdict is only as good as its input.
public enum AncestryConfidence: Sendable, Hashable {
    /// Everything the engine consulted was on the row. The verdict is exact.
    case exact

    /// Missing input, but not the deciding one — provisional, shown as "probably".
    case itemOnly

    /// The deciding input is missing — no verdict, rather than guessing as fact.
    case unknown
}

/// Re-judges a stored row against today's policy, purely from stored columns.
public enum ReviewAnnotator {
    /// Two flags — an absence looks the same whether real or unresolved.
    public struct Knowledge: Sendable {
        public var item: Item

        /// Whether `item.ancestors` is everything this item has.
        public var ancestryIsComplete: Bool

        /// Whether `item.rating` is a fact, not an absence. See ``StoredRating``.
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

    /// Trusting a verdict scales with its input — more can only add a deny.
    static func confidence(
        in verdict: Verdict,
        knowing knowledge: Knowledge,
        under policy: Policy
    ) -> AncestryConfidence {
        // A matched deny is final; nothing unresolved could unmake it.
        if case .blocked(.deniedByParent) = verdict {
            return .exact
        }

        switch policy.mode {
        case .reportOnly:
            // Nothing but a deny can decide, and there was not one.
            return .exact

        case .allowOnly:
            // Ratings don't apply; only unresolved lineage could still allow it.
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

        // Artists and playlists have no rating, so its absence costs nothing.
        let ratingCouldDecide: Bool
        switch item.id.kind {
        case .artist, .playlist: ratingCouldDecide = false
        case .album, .song: ratingCouldDecide = true
        }

        // An explicit allow on the item itself is exact regardless of lineage.
        let isExplicitlyAllowed = policy.entries.contains {
            $0.kind == .allow && $0.id == item.id
        }

        if ratingCouldDecide, !isExplicitlyAllowed, !knowledge.ratingIsRecorded {
            // The rating would decide and nobody recorded it — that's our gap.
            return .unknown
        }

        // Reaches for ancestor ratings only once the item's own rating is absent.
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
            // Blocked already; more lineage could only add reasons.
            return .exact
        }
    }
}

// MARK: - What each kind of row knows

extension PlayEvent {
    /// Complete only with both containers — an unresolved album could be denied.
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
    /// Only the artist is stored, so a song block is never fully resolved.
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
