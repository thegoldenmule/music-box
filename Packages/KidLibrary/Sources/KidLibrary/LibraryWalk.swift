import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine

extension LibraryIndexRow {
    /// Built from the catalog's index-time answers, never re-resolved.
    public var item: CatalogItem {
        var ancestors: [Ancestor] = []
        if let album = ancestry.album { ancestors.append(Ancestor(id: album)) }
        if let artist = ancestry.artist { ancestors.append(Ancestor(id: artist)) }
        return CatalogItem(
            id: catalogID,
            title: displayName,
            // Artist's name; nil leaves the subtitle to name the kind of thing.
            subtitle: ancestry.artistName,
            artworkURL: artworkURL,
            rating: rating.rating,
            ancestors: ancestors,
            trackNumber: trackNumber
        )
    }
}

/// Nothing here judges — records what the catalog said; the engine decides later.
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

    /// A failed step is skipped — the next walk retries only what's missing.
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
        case .song, .playlist:
            return
        }
    }

    /// Records first, then tracks — two requests fill the Albums column early.
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

    /// Album artwork carries to every track; a fetched one often has none.
    private func songs(
        on album: CatalogItem,
        artwork: URL?,
        source: CatalogID,
        artist: LibraryAncestry = .none
    ) async throws -> [LibraryIndexRow] {
        let tracks = try await catalog.children(of: album.id).filter { $0.id.kind == .song }
        guard !tracks.isEmpty else { return [] }

        // A favorited album knows its lineage; one via an artist was handed it.
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
