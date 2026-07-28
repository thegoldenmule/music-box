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

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A small catalog: one band, one record, and four songs on it.
    static let catalog: [CatalogItem] = [
        CatalogItem(id: band, title: "Café Band"),
        CatalogItem(
            id: record,
            title: "The Record",
            subtitle: "Café Band",
            rating: .clean,
            ancestors: [Ancestor(id: band)]
        ),
        song(clean, "Sunshine", rating: .clean),
        song(explicit, "Swearing", rating: .explicit),
        song(unrated, "Nobody Rated This", rating: nil),
        song(other, "Something Else", rating: .clean),
    ]

    static func song(_ id: CatalogID, _ title: String, rating: ContentRating?) -> CatalogItem {
        CatalogItem(
            id: id,
            title: title,
            subtitle: "Café Band",
            rating: rating,
            ancestors: [Ancestor(id: record, rating: .clean), Ancestor(id: band)]
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
        return Fix.catalog.first { $0.id == id }
    }

    func items(for ids: [CatalogID]) async throws -> [CatalogItem] {
        try check()
        let gone = lock.withLock { missing }
        return ids.compactMap { id in
            gone.contains(id) ? nil : Fix.catalog.first { $0.id == id }
        }
    }

    func children(of id: CatalogID) async throws -> [CatalogItem] {
        try check()
        return Fix.catalog.filter { $0.ancestors.contains { $0.id == id } }
    }

    func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        try check()
        return items.map { item in
            guard item.ancestors.isEmpty else { return item }
            return Fix.catalog.first { $0.id == item.id } ?? item
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

    func addFavorite(
        _ id: CatalogID,
        displayName: String,
        artworkURL: URL?,
        origin: LibraryOrigin
    ) async throws {
        try note("addFavorite(\(id))")
        favoriteRows.append(
            FavoriteRow(
                id: UUID(),
                catalogID: id,
                displayName: displayName,
                artworkURL: artworkURL,
                favoritedAt: Fix.t0,
                origin: origin
            )
        )
    }

    func removeFavorite(_ id: CatalogID) async throws {
        try note("removeFavorite(\(id))")
        favoriteRows.removeAll { $0.catalogID == id }
    }

    func playlists() async throws -> [PlaylistRow] {
        try note("playlists")
        return playlistRows
    }

    func createPlaylist(named name: String, songs: [CatalogItem]) async throws -> PlaylistRow {
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

    func addToPlaylist(_ handle: PlaylistHandle, song: CatalogItem) async throws {
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
