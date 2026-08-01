import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

/// One thing in the parent's draft, before it commits.
///
/// Two cases because the two arrive already resolved in different shapes. A
/// catalog pick is a `CatalogItem` and nothing more; a playlist out of the
/// parent's own library has been matched track by track, and the tracks that did
/// *not* match have to travel with it — they are the difference between "39
/// songs" and "34 songs, and here is why."
enum SuggestionDraftItem: Identifiable, Hashable {
    case catalog(CatalogItem)
    case snapshot(name: String, songs: [CatalogItem], discarded: [DiscardedItem])

    var id: String {
        switch self {
        case .catalog(let item): "catalog:\(item.id)"
        case .snapshot(let name, _, _): "snapshot:\(name)"
        }
    }

    var title: String {
        switch self {
        case .catalog(let item): item.title
        case .snapshot(let name, _, _): name
        }
    }

    /// What the parent is told about this row, beyond its name.
    ///
    /// A snapshot answers with its own arithmetic and needs no lookup: the
    /// matching already happened, so the shortfall is known before the confirm
    /// screen draws. A catalog container has to be counted against the kid's
    /// level, which is a request — see ``SuggestionPreview``.
    var snapshotSentence: String? {
        guard case .snapshot(_, let songs, let discarded) = self else { return nil }
        let total = songs.count + discarded.count
        if discarded.isEmpty {
            return songs.count == 1 ? "1 song" : "\(songs.count) songs"
        }
        return "\(songs.count) of \(total) songs — the rest aren't on Apple Music"
    }
}

/// How much of a container a kid would actually get.
///
/// See ``Session/suggestionPreview(for:)`` for why a parent is shown this before
/// they commit rather than left to discover it.
struct SuggestionPreview: Hashable, Sendable {
    let playable: Int
    let total: Int

    var isComplete: Bool { playable == total }

    var sentence: String {
        if isComplete {
            return total == 1 ? "1 song" : "\(total) songs"
        }
        return "\(playable) of \(total) songs — the rest are explicit"
    }
}

/// One tile on the shelf a parent filled.
///
/// Two cases rather than a `CatalogItem` everywhere, because a suggested
/// playlist that a parent made themselves has no catalog identifier and there is
/// no honest `CatalogItem` to make for it. Synthesising one would mean putting a
/// UUID into ``CatalogID``, which is the rule the whole store rests on.
enum SuggestedTile: Identifiable, Hashable {
    /// Anything in the catalog: an artist, an album, a song, or a playlist Apple
    /// published.
    case item(CatalogItem)

    /// A playlist that only exists here, snapshotted from the parent's own
    /// Apple Music library.
    case snapshotPlaylist(SuggestionRow)

    var id: String {
        switch self {
        case .item(let item): "catalog:\(item.id)"
        case .snapshotPlaylist(let row): "snapshot:\(row.id)"
        }
    }

    /// `nil` for a snapshot, which is the whole reason this type exists.
    var catalogID: CatalogID? {
        switch self {
        case .item(let item): item.id
        case .snapshotPlaylist: nil
        }
    }

    var title: String {
        switch self {
        case .item(let item): item.title
        case .snapshotPlaylist(let row): row.displayName
        }
    }

    var subtitle: String? {
        switch self {
        case .item(let item): item.subtitle
        case .snapshotPlaylist(let row): row.subtitle
        }
    }

    /// The row behind the tile, for the ones that came from a suggestion.
    ///
    /// A tile drawn from the allow-list tail has none, which is what makes it
    /// undismissible: there is nothing to dismiss, and a kid cannot edit their
    /// parent's list.
    var suggestion: SuggestionRow? {
        if case .snapshotPlaylist(let row) = self { return row }
        return nil
    }

    /// The same thing for a catalog tile, which has to be looked up.
    ///
    /// A snapshot carries its row; an item carries an identifier and the row has
    /// to be found among the ones in memory. Takes the rows rather than reaching
    /// for the session so the answer is a function of what was passed in — every
    /// caller here is inside a `body` that redraws when those rows change.
    func row(among rows: [SuggestionRow]) -> SuggestionRow? {
        switch self {
        case .item(let item): rows.first { $0.catalogID == item.id }
        case .snapshotPlaylist(let row): row
        }
    }
}

/// A tile and the grown-up who put it there.
///
/// The pairing exists only long enough to be grouped — ``GrownUpShelf`` is what
/// the screen holds. It is a separate type rather than two more cases on
/// ``SuggestedTile`` because attribution is a fact about the *row*, and the
/// allow-list tail has one while carrying no row at all.
struct AttributedTile: Hashable {
    let tile: SuggestedTile

    /// A ``GrownUp/attribution``, or `nil` for a row written before anyone was
    /// named.
    let addedBy: String?

    /// The name copied onto the row at write time. Used when the roster no longer
    /// has this grown-up — a removed adult's shelf keeps its heading.
    let addedByName: String?
}

/// One grown-up's shelf on the kid's home screen.
///
/// **One per adult rather than one for the household**, because two parents
/// curate separately and a merged shelf tells a kid that everything came from
/// whoever the app happened to name first. The cost is vertical space on the
/// home screen, which is why a grown-up with nothing currently reachable
/// contributes no shelf at all rather than an empty band.
struct GrownUpShelf: Identifiable, Hashable {
    /// The grown-up's attribution, or ``GrownUpShelf/unattributed`` for the rows
    /// nobody is named on.
    ///
    /// Keyed on the identifier and never on the name, so two grown-ups who share
    /// one still get their own shelf.
    let id: String

    /// `nil` when nobody is named, which is every row until an adult puts
    /// themselves on the roster.
    let name: String?

    let tiles: [SuggestedTile]

    /// The route key for the unnamed shelf.
    ///
    /// A sentinel rather than an optional id, because this is also a
    /// `NavigationLink` value and `String?` in a route reads as "no shelf" at
    /// every site that has to handle it. Not a valid `UUID` string, so it can
    /// never collide with a real grown-up.
    static let unattributed = "unattributed"

    /// What the kid reads above it.
    ///
    /// The fallback is the wording the whole app used before anyone could be
    /// named, so a household that never fills the roster sees exactly what it saw
    /// before the feature existed.
    var title: String { name.map { "From \($0)" } ?? "From your grown-up" }
}

extension SuggestionRow {
    /// The note, if the parent wrote one worth drawing.
    ///
    /// Whitespace counts as nothing. A parent who tabbed through the field and
    /// left a space in it did not write a sentence for their kid to read, and a
    /// tile that grows a blank line for it looks broken.
    var displayNote: String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Judging stored rows

extension PlaylistEntryRow {
    /// What the engine judges, built from the row alone.
    ///
    /// **No rating, and that is sound rather than a gap.** A live suggestion puts
    /// an allow on each of its tracks *itself*, and a per-item allow is the one
    /// thing that overrides the rating check at level 2 — so the rating is never
    /// consulted for a track that got here. What the stored lineage does earn is
    /// the other direction: a deny on the album or the artist still reaches this
    /// track, offline, with no catalog round trip.
    var policyItem: Item {
        var ancestors: [Ancestor] = []
        if let album = ancestry.album { ancestors.append(Ancestor(id: album)) }
        if let artist = ancestry.artist { ancestors.append(Ancestor(id: artist)) }
        return Item(id: catalogID, rating: nil, ancestors: ancestors)
    }

    /// The row as something the player can be handed.
    ///
    /// Carries its ancestors, which is not decoration: `Session.queuedVerdict`
    /// returns `.unknown` for an item with none, and the player drops anything
    /// `.unknown` rather than queueing it. A snapshot row without lineage would
    /// cost every track in the playlist its gapless join.
    var item: CatalogItem {
        var ancestors: [Ancestor] = []
        if let album = ancestry.album { ancestors.append(Ancestor(id: album)) }
        if let artist = ancestry.artist { ancestors.append(Ancestor(id: artist)) }
        return CatalogItem(
            id: catalogID,
            title: displayName,
            subtitle: ancestry.artistName,
            artworkURL: artworkURL,
            ancestors: ancestors
        )
    }
}

extension SuggestionRow {
    /// The tracks this kid may still reach, in the order the parent's playlist
    /// had them.
    func reachableSongs(under engine: PolicyEngine) -> [CatalogItem] {
        entries.filter { engine.evaluate($0.policyItem).isAllowed }.map(\.item)
    }

    /// Whether anything inside is still reachable.
    ///
    /// What decides if a snapshot tile is drawn at all. A playlist has no rating
    /// and no identifier of its own to judge, so it is judged through its
    /// contents — otherwise a parent denying the artist would leave their kid a
    /// tile that opens onto an empty screen.
    func hasReachableSong(under engine: PolicyEngine) -> Bool {
        entries.contains { engine.evaluate($0.policyItem).isAllowed }
    }
}

// MARK: - Snapshotting

extension CatalogItem {
    /// This item's lineage in the form storage keeps it.
    ///
    /// Identifiers without names: `Ancestor` is `{id, rating}` and carries no
    /// title, so a caller that has the names — the library seeding path does —
    /// fills them in afterwards. The identifiers alone are what
    /// ``LibraryAncestry/isEmpty`` is judged on and what lets a deny reach the
    /// row, so a snapshot taken without names is still a correct one.
    var libraryAncestry: LibraryAncestry {
        var out = LibraryAncestry()
        for ancestor in ancestors {
            switch ancestor.id.kind {
            case .album where out.albumID == nil:
                out.albumID = ancestor.id.rawValue
            case .artist where out.artistID == nil:
                out.artistID = ancestor.id.rawValue
            default:
                break
            }
        }
        return out
    }
}
