import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import SwiftData

@testable import KidLibrary

// MARK: - Fixtures

enum Fix {
    static let band = CatalogID(.artist, "artist-band")
    static let record = CatalogID(.album, "album-record")
    static let clean = CatalogID(.song, "song-clean")
    static let explicit = CatalogID(.song, "song-explicit")
    static let unrated = CatalogID(.song, "song-unrated")
    static let other = CatalogID(.song, "song-other")

    // A second act, so the fold has two of everything to keep apart. Named to
    // sort before the first once its article is dropped — "The Record" files
    // under R and "Antics" under A — which is what makes the ordering tests
    // about the sort key rather than about insertion order.
    static let duo = CatalogID(.artist, "artist-duo")
    static let sophomore = CatalogID(.album, "album-sophomore")
    static let ballad = CatalogID(.song, "song-ballad")
    static let encore = CatalogID(.song, "song-encore")

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A small catalog: two acts, one record each, six songs between them.
    static let catalog: [CatalogItem] = [
        CatalogItem(id: band, title: "Café Band"),
        CatalogItem(
            id: record,
            title: "The Record",
            subtitle: "Café Band",
            rating: .clean,
            ancestors: [Ancestor(id: band)]
        ),
        song(clean, "Sunshine", rating: .clean, track: 1),
        song(explicit, "Swearing", rating: .explicit, track: 2),
        song(unrated, "Nobody Rated This", rating: nil, track: 3),
        song(other, "Something Else", rating: .clean, track: 4),

        CatalogItem(id: duo, title: "The Duo"),
        CatalogItem(
            id: sophomore,
            title: "Antics",
            subtitle: "The Duo",
            rating: .clean,
            ancestors: [Ancestor(id: duo)]
        ),
        song(ballad, "Zither", rating: .clean, track: 1, on: sophomore, by: duo, named: "The Duo"),
        song(encore, "Applause", rating: .clean, track: 2, on: sophomore, by: duo, named: "The Duo"),
    ]

    /// An identifier for one of arbitrarily many interchangeable clean songs.
    ///
    /// **A three-hundred-entry playlist cannot be written out by hand**, and it
    /// is exactly the length the paging exists for — the bug it was written
    /// after needed 316 rows to appear at all. What these tests assert is sizes
    /// and ordering, not anything about a particular song, so the rows are
    /// generated and numbered: `bulk(7)` is the eighth of them and stays the
    /// eighth, which is what makes "the top arrived first" a testable claim.
    static func bulk(_ index: Int) -> CatalogID { CatalogID(.song, "song-bulk-\(index)") }

    /// The item behind ``bulk(_:)``, minted on demand rather than listed.
    static func bulkItem(_ id: CatalogID) -> CatalogItem? {
        guard id.kind == .song, id.rawValue.hasPrefix("song-bulk-") else { return nil }
        return CatalogItem(
            id: id,
            title: id.rawValue,
            subtitle: "Café Band",
            rating: .clean,
            ancestors: [Ancestor(id: record), Ancestor(id: band)]
        )
    }

    static func song(
        _ id: CatalogID,
        _ title: String,
        rating: ContentRating?,
        track: Int? = nil,
        on album: CatalogID = record,
        by artist: CatalogID = band,
        named artistName: String = "Café Band"
    ) -> CatalogItem {
        CatalogItem(
            id: id,
            title: title,
            subtitle: artistName,
            rating: rating,
            ancestors: [Ancestor(id: album, rating: .clean), Ancestor(id: artist)],
            trackNumber: track
        )
    }

    static func item(_ id: CatalogID) -> CatalogItem {
        catalog.first { $0.id == id }!
    }

    /// The same item as it arrives from a search: no lineage attached.
    static func bare(_ id: CatalogID) -> CatalogItem {
        let full = item(id)
        return CatalogItem(
            id: full.id,
            title: full.title,
            subtitle: full.subtitle,
            artworkURL: full.artworkURL,
            rating: full.rating
        )
    }
}

// MARK: - A catalog that answers, or does not

/// Serves ``Fix/catalog`` and can be told to stop answering.
///
/// The failing mode is not decoration: a shelf is built from stored identifiers,
/// and what it does when the network is gone is a real branch with a real rule.
final class StubCatalog: CatalogSource, @unchecked Sendable {
    struct Down: Error {}

    private let lock = NSLock()
    private var failing = false

    /// Identifiers the catalog no longer knows about — a delisting.
    private var missing: Set<CatalogID> = []

    var isFailing: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func delist(_ id: CatalogID) {
        lock.withLock { _ = missing.insert(id) }
    }

    func search(term: String, kinds: Set<ItemKind>, limit: Int, offset: Int) async throws
        -> CatalogPage
    {
        .empty
    }

    func item(for id: CatalogID) async throws -> CatalogItem? {
        try check()
        guard !lock.withLock({ missing.contains(id) }) else { return nil }
        return Fix.catalog.first { $0.id == id } ?? Fix.bulkItem(id)
    }

    /// The size of every batch lookup, in the order the requests were made.
    ///
    /// **The one thing no double in this repo could see, and the bug rode in on
    /// it.** A three-hundred-song playlist was sent as one request, one over
    /// Apple's cap, and nothing in any test could tell that from three hundred
    /// requests or from eleven. Recorded as sizes rather than counts because the
    /// question is now "how big was each one", not "how many were there".
    private var itemRequests: [Int] = []
    var itemRequestSizes: [Int] { lock.withLock { itemRequests } }

    /// Identifiers whose *page* fails — one batch of a long read going down
    /// while the rest of it lands.
    private var failingIDs: Set<CatalogID> = []

    func failLookup(of id: CatalogID) {
        lock.withLock { _ = failingIDs.insert(id) }
    }

    func items(for ids: [CatalogID]) async throws -> [CatalogItem] {
        try check()
        lock.withLock { itemRequests.append(ids.count) }
        if lock.withLock({ !failingIDs.isDisjoint(with: ids) }) { throw Down() }
        let gone = lock.withLock { missing }
        return ids.compactMap { id in
            gone.contains(id) ? nil : (Fix.catalog.first { $0.id == id } ?? Fix.bulkItem(id))
        }
    }

    /// Identifiers whose children will not load — one record on an artist that
    /// fails while the rest of the walk carries on.
    private var brokenChildren: Set<CatalogID> = []

    func breakChildren(of id: CatalogID) {
        lock.withLock { _ = brokenChildren.insert(id) }
    }

    func fixChildren(of id: CatalogID) {
        lock.withLock { _ = brokenChildren.remove(id) }
    }

    /// How many times the walk asked. What tells "indexed once" from "indexed on
    /// every read", which is the whole reason the index exists.
    private var childrenCallCount = 0
    var childrenCalls: Int { lock.withLock { childrenCallCount } }

    func children(of id: CatalogID) async throws -> [CatalogItem] {
        try check()
        lock.withLock { childrenCallCount += 1 }
        if lock.withLock({ brokenChildren.contains(id) }) { throw Down() }
        // An album's children are its tracks; an artist's are their records —
        // which is what makes ancestry the right thing to filter on, since a song
        // names both.
        return Fix.catalog.filter { item in
            item.ancestors.contains { $0.id == id }
                && (id.kind == .artist ? item.id.kind == .album : item.id.kind == .song)
        }
    }

    func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        try check()
        return items.map { item in
            guard item.ancestors.isEmpty else { return item }
            return Fix.catalog.first { $0.id == item.id } ?? Fix.bulkItem(item.id) ?? item
        }
    }

    private func check() throws {
        if isFailing { throw Down() }
    }
}

// MARK: - A second provider

/// Stands in for the Apple Music provider that Stage 2 will bring.
///
/// Everything a real second provider can do to the merged store is here:
/// declining a capability, failing an operation it claims to support, and
/// holding rows nothing else has.
@MainActor
final class StubProvider: LibraryProvider {
    nonisolated let id: LibraryProviderID
    nonisolated let capabilities: LibraryCapabilities

    struct Boom: Error {}

    /// Every operation throws. Stands for no subscription, iCloud Music Library
    /// off, no network, or authorization revoked mid-session — all the same
    /// shape to the merged store.
    var isFailing = false

    private(set) var favoriteRows: [FavoriteRow] = []
    private(set) var playlistRows: [PlaylistRow] = []

    /// Everything the merged store actually asked this provider to do.
    var calls: [String] = []

    init(
        id: LibraryProviderID = .appleMusic,
        capabilities: LibraryCapabilities = .all,
        favorites: [FavoriteRow] = [],
        playlists: [PlaylistRow] = []
    ) {
        self.id = id
        self.capabilities = capabilities
        favoriteRows = favorites
        playlistRows = playlists
    }

    private func note(_ call: String) throws {
        calls.append(call)
        if isFailing { throw Boom() }
    }

    func favorites() async throws -> [FavoriteRow] {
        try note("favorites")
        return favoriteRows
    }

    /// Lineage this provider was told about after the fact, by row.
    private(set) var recorded: [CatalogID: LibraryAncestry] = [:]

    func addFavorite(
        _ id: CatalogID,
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin,
        ancestry: LibraryAncestry
    ) async throws {
        try note("addFavorite(\(id))")
        favoriteRows.append(
            FavoriteRow(
                id: UUID(),
                catalogID: id,
                displayName: displayName,
                artworkURL: artworkURL,
                favoritedAt: Fix.t0,
                origin: origin,
                ancestry: ancestry
            )
        )
    }

    func recordAncestry(_ ancestry: [CatalogID: LibraryAncestry]) async throws {
        try note("recordAncestry(\(ancestry.count))")
        recorded.merge(ancestry) { _, new in new }
    }

    func removeFavorite(_ id: CatalogID) async throws {
        try note("removeFavorite(\(id))")
        favoriteRows.removeAll { $0.catalogID == id }
    }

    func playlists() async throws -> [PlaylistRow] {
        try note("playlists")
        return playlistRows
    }

    func createPlaylist(named name: String, songs: [LibrarySong]) async throws -> PlaylistRow {
        try note("createPlaylist(\(name))")
        let row = PlaylistRow(
            handle: PlaylistHandle(local: UUID(), appleLibraryID: "p.\(name)"),
            name: name,
            createdAt: Fix.t0,
            modifiedAt: Fix.t0,
            appleIsOurs: true,
            origin: .kid,
            entries: []
        )
        playlistRows.append(row)
        return row
    }

    func addToPlaylist(_ handle: PlaylistHandle, song: LibrarySong) async throws {
        try note("addToPlaylist(\(song.id))")
    }

    func removeFromPlaylist(_ handle: PlaylistHandle, song: CatalogID) async throws {
        try note("removeFromPlaylist(\(song))")
    }

    func reorderPlaylist(_ handle: PlaylistHandle, to order: [CatalogID]) async throws {
        try note("reorderPlaylist")
    }

    func renamePlaylist(_ handle: PlaylistHandle, to name: String) async throws {
        try note("renamePlaylist(\(name))")
    }

    func deletePlaylist(_ handle: PlaylistHandle) async throws {
        try note("deletePlaylist")
    }
}

extension DeviceLibraryState {
    /// The pair of answers that lands on a given `isSharedDevice`, for tests
    /// that care about the derived value rather than how it was reached.
    ///
    /// "Shared" here is the whole-device-and-account question, so the false case
    /// has to say both things: nobody else uses it *and* the account is the
    /// kid's. Saying only the first is the hand-me-down phone, which is shared.
    static func asked(shared: Bool) -> DeviceLibraryState {
        DeviceLibraryState(
            sharesDeviceWithChild: shared,
            childHasOwnAccount: !shared,
            hasBeenAsked: true
        )
    }
}

// MARK: - Wiring one up

@MainActor
struct Harness {
    let container: ModelContainer
    let context: ModelContext
    let kid: Kid
    let catalog = StubCatalog()
    let device: InMemoryDeviceLibraryState
    let cloudKit: CloudKitLibraryProvider
    private let providers: [any LibraryProvider]
    private(set) var library: MergedLibrary

    init(
        mode: SandboxMode = .denyPlusAuto,
        unrated: UnratedBehavior = .block,
        entries: [PolicyEntry] = [],
        extra: [any LibraryProvider] = [],
        device state: DeviceLibraryState = .asked(shared: false),
        container: ModelContainer? = nil
    ) throws {
        self.container = try container ?? FamilyStore.inMemoryContainer()
        context = ModelContext(self.container)

        if let existing = try context.fetch(FetchDescriptor<Kid>()).first {
            kid = existing
        } else {
            let family = Family(at: Fix.t0)
            let newKid = Kid(name: "Robin", mode: mode, unratedBehavior: unrated, at: Fix.t0)
            context.insert(family)
            context.insert(newKid)
            family.addKid(newKid, at: Fix.t0)
            kid = newKid
        }

        for entry in entries {
            kid.addEntry(kind: entry.kind, id: entry.id, displayName: entry.id.rawValue, at: Fix.t0)
        }
        try context.save()

        device = InMemoryDeviceLibraryState(state)
        cloudKit = CloudKitLibraryProvider(kid: kid, context: context)
        providers = [cloudKit] + extra
        library = MergedLibrary(
            providers: providers,
            catalog: catalog,
            engine: kid.makeEngine(),
            device: device
        )
    }

    /// Rebuilds the merged store against the kid's current policy — what the app
    /// does when a parent edits a list.
    mutating func repolicy(_ change: (Kid) -> Void) throws {
        change(kid)
        try context.save()
        library = MergedLibrary(
            providers: providers,
            catalog: catalog,
            engine: kid.makeEngine(),
            device: device
        )
    }
}
