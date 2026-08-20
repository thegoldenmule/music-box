import PolicyEngine

/// One protocol for MusicKit or a test stub; nothing above knows which.
public protocol CatalogSource: Sendable {
    /// Raw, unfiltered — filtering is the caller's job, see ``FilteredCatalog``.
    func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int,
        offset: Int
    ) async throws -> CatalogPage

    /// Nil when the item no longer exists — a case an allow list must survive.
    func item(for id: CatalogID) async throws -> CatalogItem?

    /// Batched like ``resolveAncestry(for:)``; missing ids are absent, unordered.
    func items(for ids: [CatalogID]) async throws -> [CatalogItem]

    /// What a container holds: albums, tracks, or a playlist's songs, per kind.
    func children(of id: CatalogID) async throws -> [CatalogItem]

    /// Ranked top songs, not ``children(of:)`` — an artist's albums, kept apart.
    func topSongs(of id: CatalogID) async throws -> [CatalogItem]

    /// Every credited artist as items — ancestry keeps only one, for the engine.
    func artists(of id: CatalogID) async throws -> [CatalogItem]

    /// Adjacent artists — the only similarity edge MusicKit has. Artist only.
    func similarArtists(of id: CatalogID) async throws -> [CatalogItem]

    /// Adjacent albums. Rated at both ends, unlike ``similarArtists(of:)``.
    func relatedAlbums(of id: CatalogID) async throws -> [CatalogItem]

    /// Batched: search returns no relationships, but the engine needs lineage.
    func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem]
}

extension CatalogSource {
    /// Correct but slow, one at a time — every real source overrides this.
    public func items(for ids: [CatalogID]) async throws -> [CatalogItem] {
        var items: [CatalogItem] = []
        for id in ids {
            if let item = try await item(for: id) { items.append(item) }
        }
        return items
    }

    /// Sources whose reads already include lineage can skip this.
    public func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem] {
        items
    }

    /// Empty for sources with no ranking — the screen omits the songs section.
    public func topSongs(of id: CatalogID) async throws -> [CatalogItem] {
        []
    }

    /// Empty here falls back to the artist name already on hand, minus the link.
    public func artists(of id: CatalogID) async throws -> [CatalogItem] {
        []
    }

    /// Empty is a shelf that does not draw, never an error a screen reports.
    public func similarArtists(of id: CatalogID) async throws -> [CatalogItem] {
        []
    }

    /// Empty is a shelf that does not draw. See ``similarArtists(of:)``.
    public func relatedAlbums(of id: CatalogID) async throws -> [CatalogItem] {
        []
    }
}

/// Split from ``CatalogSource``: asked once at launch, then just observed.
public protocol CatalogAccess: Sendable {
    /// Prompt for access to Apple Music. Safe to call when already granted.
    func requestAuthorization() async -> AuthorizationStatus

    var authorizationStatus: AuthorizationStatus { get }

    /// Ask before promising anything, not at play time.
    func subscriptionState() async throws -> SubscriptionState

    /// Tracks a plan lapsing mid-session, a real case this needs to catch.
    var subscriptionUpdates: AsyncStream<SubscriptionState> { get }
}

public enum AuthorizationStatus: String, Sendable, Hashable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

public struct SubscriptionState: Sendable, Hashable {
    /// The account can play catalog content.
    public let canPlayCatalogContent: Bool

    /// Offer a subscription — only behind a parental gate, never the kid's side.
    public let canBecomeSubscriber: Bool

    /// False means library reads return nothing; say so, don't show an empty list.
    public let hasCloudLibraryEnabled: Bool

    public init(
        canPlayCatalogContent: Bool,
        canBecomeSubscriber: Bool,
        hasCloudLibraryEnabled: Bool
    ) {
        self.canPlayCatalogContent = canPlayCatalogContent
        self.canBecomeSubscriber = canBecomeSubscriber
        self.hasCloudLibraryEnabled = hasCloudLibraryEnabled
    }
}
