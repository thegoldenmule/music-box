import PolicyEngine

/// Where catalog data comes from.
///
/// One protocol so the app can run against MusicKit in production and against a
/// stub in tests. Nothing above this layer knows which it is talking to.
public protocol CatalogSource: Sendable {
    /// One page of raw, unfiltered results. Filtering is the caller's job —
    /// see ``FilteredCatalog``.
    func search(
        term: String,
        kinds: Set<ItemKind>,
        limit: Int,
        offset: Int
    ) async throws -> CatalogPage

    /// Resolve one item. Returns `nil` when it no longer exists, which is the
    /// case an allow list has to survive.
    func item(for id: CatalogID) async throws -> CatalogItem?

    /// Resolve many items at once.
    ///
    /// A batch call for the same reason ``resolveAncestry(for:)`` is one: a
    /// screen built from stored identifiers — recents, a play history, an allow
    /// list — has a page of them, and one round trip per tile is thirty round
    /// trips per screen.
    ///
    /// Items that no longer exist are simply absent from the result, so the
    /// caller cannot assume the output lines up with the input by position.
    func items(for ids: [CatalogID]) async throws -> [CatalogItem]

    /// What is inside a container: an artist's albums, an album's tracks, a
    /// playlist's entries.
    func children(of id: CatalogID) async throws -> [CatalogItem]

    /// Attach ancestry to a batch of items.
    ///
    /// This exists as a batch call on purpose. MusicKit does not return
    /// relationships with search results, and the policy engine cannot judge a
    /// song against a denied artist without knowing who the artist is — so
    /// every search result needs its lineage before it can be filtered. Done
    /// one item at a time that is thirty round trips per page.
    ///
    /// Items that already carry ancestry should be returned untouched.
    func resolveAncestry(for items: [CatalogItem]) async throws -> [CatalogItem]
}

extension CatalogSource {
    /// One at a time, for sources with nothing better. Correct but slow, which
    /// is why every real source overrides it.
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
}

/// Authorization and subscription state.
///
/// Split from ``CatalogSource`` because it is asked once at launch and then
/// observed, rather than being part of every read.
public protocol CatalogAccess: Sendable {
    /// Prompt for access to Apple Music. Safe to call when already granted.
    func requestAuthorization() async -> AuthorizationStatus

    var authorizationStatus: AuthorizationStatus { get }

    /// Whether the signed-in account can actually play catalog content right
    /// now. Ask before promising anything, not at play time.
    func subscriptionState() async throws -> SubscriptionState

    /// Subscription changes over the life of the session — a plan lapsing
    /// mid-session is a real case.
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

    /// We may offer a subscription. Only meaningful behind a parental gate —
    /// nothing about buying anything belongs on the kid's side of the app.
    public let canBecomeSubscriber: Bool

    /// iCloud Music Library is on. When false, library reads return nothing,
    /// and that needs saying rather than showing an empty list.
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
