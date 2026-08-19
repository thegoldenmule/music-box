import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData

/// Always live: our own records, so every operation has a working provider.
@MainActor
public final class CloudKitLibraryProvider: LibraryProvider {
    public nonisolated let id = LibraryProviderID.cloudKit

    /// Everything — our own store has no primitive it lacks; the gaps are Apple's.
    public nonisolated let capabilities = LibraryCapabilities.all

    public enum Failure: Error, Equatable {
        /// No playlist with that local id belongs to this kid — deleted elsewhere.
        case unknownPlaylist(UUID)
    }

    private let kid: Kid
    private let context: ModelContext

    /// One provider per kid; switching kids builds a new one, like the engine.
    public init(kid: Kid, context: ModelContext) {
        self.kid = kid
        self.context = context
    }

    // MARK: - Favorites

    /// Most recent first; unreadable rows drop — a favorite isn't a permission.
    public func favorites() async throws -> [FavoriteRow] {
        kid.favorites
            .compactMap(\.row)
            .sorted { $0.favoritedAt > $1.favoritedAt }
    }

    public func addFavorite(
        _ id: CatalogID,
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry
    ) async throws {
        kid.addFavorite(
            id: id,
            displayName: displayName,
            artworkURL: artworkURL,
            origin: origin,
            ancestry: ancestry
        )
        try context.save()
    }

    /// Tops up lineage on favorites and entries, one save; failures just retry.
    public func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws {
        guard !ancestry.isEmpty else { return }

        var touched = false
        for record in kid.favorites {
            guard let id = record.itemID, let found = ancestry[id] else { continue }
            record.record(ancestry: found)
            touched = true
        }
        for playlist in kid.playlists {
            for entry in playlist.entries {
                guard let found = ancestry[entry.itemID] else { continue }
                entry.record(ancestry: found)
                touched = true
            }
        }

        guard touched else { return }
        try context.save()
    }

    public func removeFavorite(_ id: CatalogID) async throws {
        for record in kid.favorites.filter({ $0.itemID == id }) {
            context.delete(record)
        }
        kid.removeFavorite(id)
        try context.save()
    }

    // MARK: - The library index

    /// Sorted explicitly — SwiftData's relationship order isn't stable.
    public func indexed() async throws -> [LibraryIndexRow] {
        kid.libraryIndex
            .compactMap(\.row)
            .sorted { $0.catalogID.rawValue < $1.catalogID.rawValue }
    }

    /// Written as the walk finds things, so a closed app keeps what it got.
    public func appendIndex(from source: CatalogID, rows: [LibraryIndexRow]) async throws {
        guard !rows.isEmpty else { return }
        kid.appendIndex(from: source, with: rows)
        try context.save()
    }

    public func isIndexed(_ source: CatalogID) async -> Bool {
        kid.isIndexed(source)
    }

    public func removeIndex(from source: CatalogID) async throws {
        kid.removeIndex(from: source)
        try context.save()
    }

    // MARK: - Playlists

    /// Most recently touched first — the shelf shows what the kid is working on.
    public func playlists() async throws -> [PlaylistRow] {
        kid.playlists
            .map(\.row)
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func createPlaylist(named name: String, songs: [LibrarySong]) async throws -> PlaylistRow
    {
        let record = kid.addPlaylist(named: name)
        for song in songs {
            record.addSong(
                id: song.item.id,
                displayName: song.item.title,
                artworkURL: song.item.artworkURL,
                ancestry: song.ancestry
            )
        }
        try context.save()
        return record.row
    }

    public func addToPlaylist(_ handle: PlaylistHandle, song: LibrarySong) async throws {
        let record = try playlist(handle)
        record.addSong(
            id: song.item.id,
            displayName: song.item.title,
            artworkURL: song.item.artworkURL,
            ancestry: song.ancestry
        )
        try context.save()
    }

    public func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws {
        let record = try playlist(handle)
        for entry in record.entries.filter({ $0.itemID == song }) {
            context.delete(entry)
        }
        record.removeSong(song)
        try context.save()
    }

    public func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async throws {
        try playlist(handle).reorder(to: order)
        try context.save()
    }

    public func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws {
        try playlist(handle).rename(to: name)
        try context.save()
    }

    public func deletePlaylist(_ handle: PlaylistHandle) async throws {
        let record = try playlist(handle)
        kid.removePlaylist(record)
        context.delete(record)
        try context.save()
    }

    /// Looked up by our stable `local` id, never Apple's, which may be absent.
    private func playlist(_ handle: PlaylistHandle) throws -> PlaylistRecord {
        guard let record = kid.playlistRecord(for: handle.local) else {
            throw Failure.unknownPlaylist(handle.local)
        }
        return record
    }
}
