import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData

/// The kid's library as our own records.
///
/// **Always live.** Every operation therefore has at least one provider, and the
/// feature is complete with Apple Music absent, missing a subscription, offline,
/// or switched off by the shared-device toggle. Everything a kid does in this
/// app lands here first.
///
/// Named for the zone it belongs to rather than for SwiftData, because the store
/// being local today and synced in v2 is not a difference callers see.
///
/// Main-actor bound on purpose. It writes on the **same context that holds the
/// kid**, so a heart filled here is visible to the screen that filled it without
/// a refetch — the opposite arrangement to ``EventLog``, which owns its own
/// context precisely so logging never blocks playback. The contracts differ for
/// the same reason: a dropped log line is acceptable, and a heart that fills
/// over a write that did not land is a lie.
@MainActor
public final class CloudKitLibraryProvider: LibraryProvider {
    public nonisolated let id = LibraryProviderID.cloudKit

    /// Everything. Our own store has no primitive it lacks — the gaps in
    /// ``LibraryCapabilities`` are Apple's.
    public nonisolated let capabilities = LibraryCapabilities.all

    public enum Failure: Error, Equatable {
        /// No playlist with that local identifier belongs to this kid. Deleted
        /// on another device, or on another screen a moment ago.
        case unknownPlaylist(UUID)
    }

    private let kid: Kid
    private let context: ModelContext

    /// - Parameters:
    ///   - kid: the kid whose library this is. One provider per kid; switching
    ///     kids builds a new one, the way switching kids rebuilds the engine.
    ///   - context: the context `kid` was fetched on.
    public init(kid: Kid, context: ModelContext) {
        self.kid = kid
        self.context = context
    }

    // MARK: - Favorites

    /// Most recent first. Rows this version cannot read are dropped — a favorite
    /// is not a permission, so losing one costs a tile and costs safety nothing.
    public func favorites() async throws -> [FavoriteRow] {
        kid.favorites
            .compactMap(\.row)
            .sorted { $0.favoritedAt > $1.favoritedAt }
    }

    public func addFavorite(
        _ id: CatalogID,
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin
    ) async throws {
        kid.addFavorite(
            id: id,
            displayName: displayName,
            artworkURL: artworkURL,
            origin: origin
        )
        try context.save()
    }

    public func removeFavorite(_ id: CatalogID) async throws {
        for record in kid.favorites.filter({ $0.itemID == id }) {
            context.delete(record)
        }
        kid.removeFavorite(id)
        try context.save()
    }

    // MARK: - Playlists

    /// Most recently touched first, which is the order a shelf wants: the one a
    /// kid just added a song to is the one they are working on.
    public func playlists() async throws -> [PlaylistRow] {
        kid.playlists
            .map(\.row)
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func createPlaylist(named name: String, songs: [CatalogItem]) async throws -> PlaylistRow
    {
        let record = kid.addPlaylist(named: name)
        for song in songs {
            record.addSong(
                id: song.id,
                displayName: song.title,
                artworkURL: song.artworkURL
            )
        }
        try context.save()
        return record.row
    }

    public func addToPlaylist(_ handle: PlaylistHandle, song: CatalogItem) async throws {
        let record = try playlist(handle)
        record.addSong(id: song.id, displayName: song.title, artworkURL: song.artworkURL)
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

    /// Looked up by the **local** identifier, never the Apple one. `local` is
    /// ours and stable; `appleLibraryID` is absent on every playlist made while
    /// the Apple provider was not live.
    private func playlist(_ handle: PlaylistHandle) throws -> PlaylistRecord {
        guard let record = kid.playlistRecord(for: handle.local) else {
            throw Failure.unknownPlaylist(handle.local)
        }
        return record
    }
}
