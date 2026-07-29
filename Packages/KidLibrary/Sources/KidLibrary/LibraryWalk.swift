import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

extension LibraryIndexRow {
    /// The row as the rest of the app sees everything: a `CatalogItem`.
    ///
    /// Here rather than on the row itself because ``FamilyStore`` does not know
    /// what a `CatalogItem` is, and deliberately — catalog metadata arrives there
    /// as values a caller passes in, which is what lets storage build and test
    /// with no MusicKit and no device.
    ///
    /// **Built from what was stored, never re-resolved.** The rating and the
    /// lineage are the catalog's own answers from index time, so this is a
    /// complete item rather than a placeholder — which is what makes judging the
    /// index free.
    public var item: CatalogItem {
        var ancestors: [Ancestor] = []
        if let album = ancestry.album { ancestors.append(Ancestor(id: album)) }
        if let artist = ancestry.artist { ancestors.append(Ancestor(id: artist)) }
        return CatalogItem(
            id: catalogID,
            title: displayName,
            // An artist's name on a song or a record; `nil` leaves the row's
            // second line to say what kind of thing it is, as it does elsewhere.
            subtitle: ancestry.artistName,
            artworkURL: artworkURL,
            rating: rating.rating,
            ancestors: ancestors,
            trackNumber: trackNumber
        )
    }
}

/// Turns one kept thing into everything underneath it.
///
/// Hearting an artist means keeping their work, not keeping a name. So the walk
/// goes **down** as well as up: an artist yields their records and every track on
/// every one of them, a record yields its tracks, and all of it lands in
/// ``LibraryIndexRecord`` so the browser can show it without asking the catalog
/// again.
///
/// ### It is slow, and that is designed for rather than hidden
///
/// `children(of:)` costs two requests, so an artist with twenty-five records is
/// fifty-two round trips. There is no version of this that is fast. What there is
/// instead:
///
/// - **It never blocks the heart.** The favorite is written and awaited on its
///   own; the walk is started afterwards and the kid carries on using the app
///   while it runs.
/// - **It writes as it goes.** Each record's tracks are saved when they arrive,
///   so an app closed halfway through keeps what it got and the next walk picks
///   up the rest rather than starting over.
/// - **The records land first.** They come back in the first two requests, so the
///   Albums column fills almost immediately and the songs arrive underneath.
///
/// ### What it does not do
///
/// No cap, deliberately: what a kid gets is what the catalog has. The real
/// ceiling is MusicKit's own relationship-fetch limit, which is **unmeasured** —
/// `artist.with([.albums])` returns a page and this layer has no way to ask for
/// another. So "every album" may prove to be "the first page of albums" on a real
/// account, and that is a thing to find out on device rather than a thing to
/// pretend is settled here.
///
/// Nothing here judges. The walk records what the catalog said, rating included,
/// and the engine has its say when a row is drawn — which is what lets a parent
/// deny something tomorrow and have it disappear from a library indexed today.
public struct LibraryWalk: Sendable {
    /// One step's worth of findings, handed over as soon as it is known.
    public struct Batch: Sendable {
        public let source: CatalogID
        public let rows: [LibraryIndexRow]
    }

    private let catalog: any CatalogSource

    public init(catalog: any CatalogSource) {
        self.catalog = catalog
    }

    /// Walks everything under `item`, reporting each step as it completes.
    ///
    /// `emit` is called on the walk's own task, once per step, and is where the
    /// writing happens. Returning from this method means the walk finished; it
    /// throwing means it did not, and whatever was already emitted stays.
    ///
    /// A step that fails is skipped rather than failing the walk. One record
    /// whose tracks would not load should cost that record's tracks and not the
    /// other twenty-four — the next walk tries again, because a source is only
    /// marked walked by the rows it produced.
    public func walk(
        _ item: CatalogItem,
        emit: @Sendable (Batch) async -> Void
    ) async throws {
        switch item.id.kind {
        case .artist:
            try await walkArtist(item, emit: emit)
        case .album:
            let songs = try await songs(on: item, artwork: item.artworkURL, source: item.id)
            await emit(Batch(source: item.id, rows: songs))
        // A song has nothing underneath it, and a playlist is never favorited.
        case .song, .playlist:
            return
        }
    }

    /// Records first, then each record's tracks.
    ///
    /// The order is the point: two requests put the Albums column on screen, and
    /// the fifty behind them fill it in. Doing it depth-first would leave a kid
    /// looking at one record for as long as the whole walk takes.
    private func walkArtist(
        _ artist: CatalogItem,
        emit: @Sendable (Batch) async -> Void
    ) async throws {
        let albums = try await catalog.children(of: artist.id).filter { $0.id.kind == .album }
        guard !albums.isEmpty else { return }

        let lineage = LibraryAncestry(
            artistID: artist.id.rawValue,
            artistName: artist.title,
            artistArtworkURL: artist.artworkURL
        )

        await emit(
            Batch(
                source: artist.id,
                rows: albums.map { album in
                    LibraryIndexRow(
                        catalogID: album.id,
                        displayName: album.title,
                        artworkURL: album.artworkURL,
                        rating: StoredRating(album.rating),
                        ancestry: lineage,
                        source: artist.id
                    )
                }
            )
        )

        for album in albums {
            try Task.checkCancellation()
            // Skipped, not thrown: see the note on `walk`.
            guard
                let rows = try? await songs(
                    on: album,
                    artwork: album.artworkURL,
                    source: artist.id,
                    artist: lineage
                )
            else { continue }
            await emit(Batch(source: artist.id, rows: rows))
        }
    }

    /// One record's tracks, as index rows.
    ///
    /// The album's artwork is carried onto every track rather than read off each
    /// one: a track fetched through a relationship often has none of its own, and
    /// a column of grey squares under a record that plainly has a cover reads as
    /// broken.
    private func songs(
        on album: CatalogItem,
        artwork: URL?,
        source: CatalogID,
        artist: LibraryAncestry = .none
    ) async throws -> [LibraryIndexRow] {
        let tracks = try await catalog.children(of: album.id).filter { $0.id.kind == .song }
        guard !tracks.isEmpty else { return [] }

        // An album favorited on its own knows its artist from its own lineage;
        // one reached through an artist was handed it. Either way the row carries
        // both, because the fold above reads nothing else.
        let artistID = artist.artistID ?? album.ancestors.first { $0.id.kind == .artist }?.id.rawValue
        let lineage = LibraryAncestry(
            albumID: album.id.rawValue,
            albumName: album.title,
            artistID: artistID,
            artistName: artist.artistName ?? album.subtitle,
            artistArtworkURL: artist.artistArtworkURL
        )

        return tracks.map { track in
            LibraryIndexRow(
                catalogID: track.id,
                displayName: track.title,
                artworkURL: track.artworkURL ?? artwork,
                trackNumber: track.trackNumber,
                rating: StoredRating(track.rating),
                ancestry: lineage,
                source: source
            )
        }
    }
}
