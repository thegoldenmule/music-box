import Foundation
import PolicyEngine
import SwiftData

/// The first projection here — derived, rebuildable, so a sweep may delete the
/// ``VisitEventRecord``s underneath; exempt from retention like favorites/lists.
/// No position column: order is `at` descending, so a revisit just refreshes it.
@Model
public final class RecentTrailRecord {
    public private(set) var id: UUID = UUID()
    public private(set) var at: Date = Date.distantPast

    public private(set) var catalogID: String = ""

    /// Part of the identity — this table mixes all four item kinds by design.
    public private(set) var itemKind: String = ItemKind.song.rawValue

    /// Copied at write time, so the shelf renders without a network call.
    public private(set) var displayName: String = ""

    /// A reference. Artwork bytes are never copied into our storage.
    public private(set) var artworkURL: URL?

    public private(set) var albumID: String?
    public private(set) var artistID: String?

    /// Which `RecentTrail` build produced this row; a mismatch triggers a replay.
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

    /// Moves the row to the front, not delete-and-insert — quieter, since this syncs.
    func refresh(at newDate: Date) {
        at = newDate
        version = RecentTrail.version
    }

    /// Internal — lets the replay path be tested without shipping a version bump.
    func markVersion(_ version: Int) {
        self.version = version
    }
}
