import Foundation
import PolicyEngine

/// A projection, not a record — nothing sweeps it, so it outlives the events.
public struct RecentEntry: Hashable, Sendable, Identifiable {
    public let catalogID: CatalogID

    /// Empty for an album inferred from a run, never opened — nothing to put here.
    public let displayName: String
    public let artworkURL: URL?

    /// Carried so the rules below compare entries without revisiting events.
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

/// **Recomputed, not folded** — a fold can't un-decide, and two of the three
/// rules below look across the whole shelf: a new arrival can retract a tile
/// already on it (playing a track takes away that artist's own tile).
///
/// 1. A contiguous run through one album collapses to that album.
/// 2. An artist tile survives only if nothing else on the shelf is theirs.
/// 3. A song tile survives only if its album is not already shown.
public enum RecentTrail {
    /// Generous next to the two dozen drawn — filtering at render time costs tiles.
    public static let cap = 50

    /// Bounded so a replayed album yields a shorter shelf, never a wrong one.
    public static let window = 200

    /// Bumping it is how corrected rules reach a kid who already has a shelf.
    public static let version = 2

    /// - Parameter visits: oldest first — rule 1's "contiguous" means in time.
    public static func shelf(from visits: [VisitEvent]) -> [RecentEntry] {
        var entries = collapseRuns(in: visits)

        // Newest wins; done before the cross-shelf rules see one entry per item.
        entries = deduplicate(entries)

        let shownAlbums = Set(
            entries.filter { $0.catalogID.kind == .album }.map(\.catalogID)
        )

        // Rule 3: the album is already the way back to the track.
        entries.removeAll { entry in
            entry.catalogID.kind == .song && entry.albumID.map(shownAlbums.contains) == true
        }

        // Rule 2, after rule 3 so a song dropped for its album still counts.
        let representedArtists = Set(
            entries.filter { $0.catalogID.kind != .artist }.compactMap(\.artistID)
        )
        entries.removeAll { entry in
            entry.catalogID.kind == .artist && representedArtists.contains(entry.catalogID)
        }

        return Array(entries.sorted { $0.at > $1.at }.prefix(cap))
    }

    // MARK: -

    /// Rule 1. A run of one stays itself — one track isn't "listened to the record".
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
                    // Name only if the album itself was an arrival.
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

    /// `nil` for artist/playlist, so a whole evening can't collapse into one tile.
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
                // Keep whichever copy has a name — a run's album entry may lack one.
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
