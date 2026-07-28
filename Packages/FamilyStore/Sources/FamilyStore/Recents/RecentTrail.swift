import Foundation
import PolicyEngine

/// One tile on the kid's Recent shelf.
///
/// A **projection**, not a record of a child's activity. That distinction is
/// load-bearing rather than pedantic: the retention sweep is written against
/// event tables, so a shelf built directly out of events would empty itself the
/// day the window passed. This is derived state, recomputed from
/// ``VisitEvent``s, and nothing sweeps it.
public struct RecentEntry: Hashable, Sendable, Identifiable {
    public let catalogID: CatalogID

    /// Copied from the visit that produced this, when there was one.
    ///
    /// **Empty for an album the kid never opened** — one inferred from a run of
    /// tracks played out of it. Nothing records an album's title at play time
    /// (a song's ancestors carry identifiers, not names), so there is nothing
    /// honest to put here. The shelf resolves every tile through the catalog
    /// anyway; this is the offline fallback, and offline that tile is one of the
    /// ones that cannot draw a name.
    public let displayName: String
    public let artworkURL: URL?

    /// Carried so the rules below can compare entries without going back to the
    /// events.
    public let albumID: CatalogID?
    public let artistID: CatalogID?

    /// The most recent arrival this tile stands for.
    public let at: Date

    public var id: CatalogID { catalogID }

    public init(
        catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        albumID: CatalogID? = nil,
        artistID: CatalogID? = nil,
        at: Date
    ) {
        self.catalogID = catalogID
        self.displayName = displayName
        self.artworkURL = artworkURL
        self.albumID = albumID
        self.artistID = artistID
        self.at = at
    }

    public init(_ visit: VisitEvent) {
        self.init(
            catalogID: visit.itemID,
            displayName: visit.displayName,
            artworkURL: visit.artworkURL,
            albumID: visit.albumID,
            artistID: visit.artistID,
            at: visit.at
        )
    }
}

/// Turns a stream of arrivals into a shelf.
///
/// **Pure, and recomputed rather than folded.** An earlier version applied one
/// visit at a time to the trail it already had, which is cheaper and wrong here:
/// two of the three rules below look *across* the whole shelf, so a single new
/// arrival can retract a tile that was already on it — playing a track by an
/// artist takes that artist's own tile away. A fold cannot un-decide, so this
/// recomputes from a window of recent visits, which also makes the live path and
/// the rebuild path literally the same call.
///
/// Three rules, and each exists because of how a shelf reads rather than how the
/// data is shaped:
///
/// 1. **A contiguous run through one album collapses to that album.** A kid who
///    played four tracks off a record was listening to the record, and four
///    tiles for it says something the kid did not do.
/// 2. **An artist tile survives only if nothing else on the shelf is theirs.**
///    Opening an artist and stopping there is the only thing an artist tile is
///    for; if a record or a track of theirs made it on, that is the more useful
///    way back in.
/// 3. **A song tile survives only if its album is not already shown.** The album
///    is the way back to the song, and both is a duplicate.
public enum RecentTrail {
    /// How many tiles a shelf keeps.
    ///
    /// Generous next to the two dozen drawn, because the shelf filters at render
    /// time and a kid whose parent has denied half of last week should still get
    /// a full row.
    public static let cap = 50

    /// How many arrivals the shelf is computed from.
    ///
    /// Bounded so the recompute stays trivial. Beyond this the oldest arrivals
    /// cannot reach the front of a fifty-tile shelf anyway, and a kid who
    /// replayed one album two hundred times gets a **shorter** shelf rather than
    /// a wrong one.
    public static let window = 200

    /// Which build of the rules produced a stored shelf.
    ///
    /// Bumping it is how corrected rules reach kids who already have one: the
    /// projector notices the mismatch and recomputes. Nothing else reads it.
    public static let version = 2

    /// Builds the shelf, newest tile first.
    ///
    /// - Parameter visits: arrivals **oldest first**. The order is the input to
    ///   rule 1 — "contiguous" means contiguous in time, and a reversed stream
    ///   would find different runs.
    public static func shelf(from visits: [VisitEvent]) -> [RecentEntry] {
        var entries = collapseRuns(in: visits)

        // Newest wins, and a tile keeps the latest time it stood for. Done
        // before the cross-shelf rules so those see one entry per item.
        entries = deduplicate(entries)

        let shownAlbums = Set(
            entries.filter { $0.catalogID.kind == .album }.map(\.catalogID)
        )

        // Rule 3: the album is already the way back to the track.
        entries.removeAll { entry in
            entry.catalogID.kind == .song && entry.albumID.map(shownAlbums.contains) == true
        }

        // Rule 2: an artist whose work is on the shelf does not need a tile of
        // their own. Computed after rule 3 so a song dropped in favour of its
        // album still counts as that artist's work being present.
        let representedArtists = Set(
            entries.filter { $0.catalogID.kind != .artist }.compactMap(\.artistID)
        )
        entries.removeAll { entry in
            entry.catalogID.kind == .artist && representedArtists.contains(entry.catalogID)
        }

        return Array(entries.sorted { $0.at > $1.at }.prefix(cap))
    }

    // MARK: -

    /// Rule 1. Consecutive arrivals sharing an album become that album.
    ///
    /// A run of one is left as whatever it was: a single track played out of a
    /// record is a track, and calling it the record would claim more than
    /// happened. A run of one that *is* an album — the kid opened it and left —
    /// is likewise itself.
    private static func collapseRuns(in visits: [VisitEvent]) -> [RecentEntry] {
        var entries: [RecentEntry] = []
        var run: [VisitEvent] = []

        func flush() {
            guard let first = run.first else { return }
            defer { run.removeAll() }

            guard run.count > 1, let albumID = albumKey(of: first) else {
                entries.append(contentsOf: run.map(RecentEntry.init))
                return
            }
            entries.append(
                RecentEntry(
                    catalogID: albumID,
                    // The name only when the album itself was one of the
                    // arrivals; a run of tracks never carries it.
                    displayName: run.first { $0.itemID == albumID }?.displayName ?? "",
                    artworkURL: run.first { $0.itemID == albumID }?.artworkURL,
                    artistID: run.compactMap(\.artistID).first,
                    at: run.map(\.at).max() ?? first.at
                )
            )
        }

        for visit in visits {
            if let key = albumKey(of: visit), key == run.first.flatMap(albumKey(of:)) {
                run.append(visit)
            } else {
                flush()
                run = [visit]
            }
        }
        flush()
        return entries
    }

    /// The album an arrival belongs to, if any.
    ///
    /// An album is its own key, so opening a record and then playing from it is
    /// one run rather than two. An artist or a playlist has none and therefore
    /// never joins a run — which is what stops a kid's whole evening collapsing
    /// into one tile.
    private static func albumKey(of visit: VisitEvent) -> CatalogID? {
        switch visit.itemID.kind {
        case .album: visit.itemID
        case .song: visit.albumID
        case .artist, .playlist: nil
        }
    }

    /// One entry per item, keeping the latest arrival.
    private static func deduplicate(_ entries: [RecentEntry]) -> [RecentEntry] {
        var newest: [CatalogID: RecentEntry] = [:]
        for entry in entries {
            guard let existing = newest[entry.catalogID] else {
                newest[entry.catalogID] = entry
                continue
            }
            if entry.at > existing.at {
                // Keep whichever copy actually has a name: a run of tracks
                // produces a nameless album entry, and an earlier visit to that
                // album has the name we would otherwise throw away.
                newest[entry.catalogID] = RecentEntry(
                    catalogID: entry.catalogID,
                    displayName: entry.displayName.isEmpty
                        ? existing.displayName : entry.displayName,
                    artworkURL: entry.artworkURL ?? existing.artworkURL,
                    albumID: entry.albumID ?? existing.albumID,
                    artistID: entry.artistID ?? existing.artistID,
                    at: entry.at
                )
            }
        }
        return Array(newest.values)
    }
}
