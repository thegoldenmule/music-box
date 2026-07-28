import Foundation
import PolicyEngine
import SwiftData

/// One row of the Recent shelf, as stored.
///
/// **A projection, and the first one in this store.** Everything else here is
/// either something a parent wrote or something a child did; this is neither. It
/// is derived from ``VisitEventRecord`` and can be thrown away and rebuilt at
/// any time, which is exactly why it is safe for the retention sweep to delete
/// the events underneath it. Whatever window is eventually chosen, this table is
/// **not** an event table and must be exempt — the same exemption favorites and
/// playlists already have, for a different reason.
///
/// No position column. Order is `at` descending, which reproduces the walk's
/// output exactly: a new excursion is prepended with the newest timestamp, and
/// revisiting something refreshes its timestamp and moves it up. Nothing depends
/// on insertion order, which is the store-wide rule.
@Model
public final class RecentTrailRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var at: Date = Date.distantPast

    public private(set) var catalogID: String = ""

    /// Part of the identity — MusicKit identifiers are unique only within a
    /// type, and this table mixes all four kinds by design.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    /// Copied at write time, like every other display name in this store, so a
    /// shelf renders before — or without — any network call.
    public private(set) var displayName: String = ""

    /// A reference. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var albumID: String?
    public private(set) var artistID: String?

    /// Which build of ``RecentTrail`` produced this row. A mismatch on read is
    /// what triggers a replay.
    public private(set) var version: Int = 0

    public var kid: Kid?

    public init(id: UUID = UUID(), entry: RecentEntry, version: Int = RecentTrail.version) {
        self.id = id
        self.at = entry.at
        self.catalogID = entry.catalogID.rawValue
        self.itemKind = entry.catalogID.kind.rawValue
        self.displayName = entry.displayName
        self.artworkURL = entry.artworkURL
        self.albumID = entry.albumID?.rawValue
        self.artistID = entry.artistID?.rawValue
        self.version = version
    }

    /// The typed entry, or `nil` if the kind column does not read back.
    public var entry: RecentEntry? {
        guard let itemKind = ItemKind(rawValue: itemKind) else { return nil }
        return RecentEntry(
            catalogID: CatalogID(itemKind, catalogID),
            displayName: displayName,
            artworkURL: artworkURL,
            albumID: albumID.map { CatalogID(.album, $0) },
            artistID: artistID.map { CatalogID(.artist, $0) },
            at: at
        )
    }

    /// Moves an existing row to the front rather than replacing it.
    ///
    /// Cheaper than delete-and-insert, and quieter: this table syncs, and a row
    /// rewritten wholesale on every revisit is a CloudKit change where a
    /// timestamp would do.
    func refresh(at newDate: Date) {
        at = newDate
    }

    /// Ages a row, so the replay path can be tested without shipping a version
    /// bump. Internal, and the only way to produce a row this build considers
    /// stale — the same reason ``PolicyEntryRecord`` carries a raw initializer.
    func markVersion(_ version: Int) {
        self.version = version
    }
}
