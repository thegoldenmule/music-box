import Testing

import PolicyEngine

// MARK: - Fixtures

private enum Fix {
    static let artist = CatalogID(.artist, "artist-A")
    static let otherArtist = CatalogID(.artist, "artist-B")
    static let album = CatalogID(.album, "album-A")
    static let otherAlbum = CatalogID(.album, "album-B")
    static let song = CatalogID(.song, "song-A")
    static let playlist = CatalogID(.playlist, "playlist-A")
}

/// A song on `Fix.album` by `Fix.artist`, optionally reached through a playlist.
private func song(
    _ rating: ContentRating? = .clean,
    albumRating: ContentRating? = nil,
    artistRating: ContentRating? = nil,
    viaPlaylist: Bool = false
) -> Item {
    var ancestors = [
        Ancestor(id: Fix.album, rating: albumRating),
        Ancestor(id: Fix.artist, rating: artistRating),
    ]
    if viaPlaylist {
        ancestors.append(Ancestor(id: Fix.playlist))
    }
    return Item(id: Fix.song, rating: rating, ancestors: ancestors)
}

private func album(_ rating: ContentRating? = .clean) -> Item {
    Item(id: Fix.album, rating: rating, ancestors: [Ancestor(id: Fix.artist)])
}

private func engine(
    _ mode: SandboxMode,
    _ entries: [PolicyEntry] = [],
    unrated: UnratedBehavior = .block
) -> PolicyEngine {
    PolicyEngine(policy: Policy(mode: mode, entries: entries, unratedBehavior: unrated))
}

// MARK: - Rule 1: deny wins

@Suite("Rule 1 — deny wins")
struct DenyRules {
    @Test("A deny on the item blocks it in every mode", arguments: SandboxMode.allCases)
    func denyOnItem(mode: SandboxMode) {
        let sut = engine(mode, [.deny(Fix.song)])
        #expect(sut.evaluate(song()) == .blocked(.deniedByParent(Fix.song)))
    }

    @Test("A deny on the album blocks its tracks in every mode", arguments: SandboxMode.allCases)
    func denyOnAlbum(mode: SandboxMode) {
        let sut = engine(mode, [.deny(Fix.album)])
        #expect(sut.evaluate(song()) == .blocked(.deniedByParent(Fix.album)))
    }

    @Test("A deny on the artist blocks their tracks in every mode", arguments: SandboxMode.allCases)
    func denyOnArtist(mode: SandboxMode) {
        let sut = engine(mode, [.deny(Fix.artist)])
        #expect(sut.evaluate(song()) == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("A deny on a playlist blocks tracks reached through it")
    func denyOnPlaylist() {
        let sut = engine(.denyPlusAuto, [.deny(Fix.playlist)])
        #expect(sut.evaluate(song(viaPlaylist: true)) == .blocked(.deniedByParent(Fix.playlist)))
    }

    @Test("A deny on a playlist does not block the same track reached another way")
    func denyOnPlaylistIsScoped() {
        let sut = engine(.denyPlusAuto, [.deny(Fix.playlist)])
        #expect(sut.evaluate(song(viaPlaylist: false)) == .allowed)
    }

    @Test("Deny beats an allow on the same item")
    func denyBeatsAllowOnSameItem() {
        let sut = engine(.allowOnly, [.allow(Fix.song), .deny(Fix.song)])
        #expect(sut.evaluate(song()) == .blocked(.deniedByParent(Fix.song)))
    }

    @Test("Deny on the artist beats an allow on one of their songs")
    func denyBeatsAllowOnDescendant() {
        let sut = engine(.allowOnly, [.allow(Fix.song), .deny(Fix.artist)])
        #expect(sut.evaluate(song()) == .blocked(.deniedByParent(Fix.artist)))
    }

    @Test("The item itself is reported before its containers")
    func nearestMatchIsReported() {
        let sut = engine(.denyPlusAuto, [.deny(Fix.song), .deny(Fix.artist)])
        #expect(sut.evaluate(song()) == .blocked(.deniedByParent(Fix.song)))
    }

    @Test("A deny on an unrelated artist does not leak")
    func denyIsScopedToLineage() {
        let sut = engine(.denyPlusAuto, [.deny(Fix.otherArtist)])
        #expect(sut.evaluate(song()) == .allowed)
    }
}

// MARK: - Rule 2: report only

@Suite("Rule 2 — report only allows everything")
struct ReportOnlyRules {
    @Test("Explicit content is allowed")
    func explicitAllowed() {
        #expect(engine(.reportOnly).evaluate(song(.explicit)) == .allowed)
    }

    @Test("Unrated content is allowed even when the unrated default is block")
    func unratedAllowed() {
        let sut = engine(.reportOnly, unrated: .block)
        #expect(sut.evaluate(song(nil)) == .allowed)
    }

    @Test("Nothing needs to be on a list")
    func emptyListsAllowed() {
        #expect(engine(.reportOnly).evaluate(song()) == .allowed)
    }
}

// MARK: - Rule 3: allow only

@Suite("Rule 3 — allow only requires a match")
struct AllowOnlyRules {
    @Test("An unlisted item is blocked")
    func unlistedBlocked() {
        #expect(engine(.allowOnly).evaluate(song()) == .blocked(.notOnAllowList))
    }

    @Test("An allow on the item itself matches")
    func exactAllow() {
        #expect(engine(.allowOnly, [.allow(Fix.song)]).evaluate(song()) == .allowed)
    }

    @Test("An allow on the album covers its tracks")
    func albumAllowCoversTracks() {
        #expect(engine(.allowOnly, [.allow(Fix.album)]).evaluate(song()) == .allowed)
    }

    @Test("An allow on the artist covers their songs")
    func artistAllowCoversSongs() {
        #expect(engine(.allowOnly, [.allow(Fix.artist)]).evaluate(song()) == .allowed)
    }

    @Test("An allow on the artist covers their albums")
    func artistAllowCoversAlbums() {
        #expect(engine(.allowOnly, [.allow(Fix.artist)]).evaluate(album()) == .allowed)
    }

    @Test("An allow on a playlist covers tracks reached through it")
    func playlistAllowCoversTracks() {
        let sut = engine(.allowOnly, [.allow(Fix.playlist)])
        #expect(sut.evaluate(song(viaPlaylist: true)) == .allowed)
    }

    @Test("An allow on a playlist does not cover the same track reached another way")
    func playlistAllowIsScoped() {
        let sut = engine(.allowOnly, [.allow(Fix.playlist)])
        #expect(sut.evaluate(song(viaPlaylist: false)) == .blocked(.notOnAllowList))
    }

    @Test("An allow on an unrelated album does not leak")
    func allowIsScopedToLineage() {
        let sut = engine(.allowOnly, [.allow(Fix.otherAlbum)])
        #expect(sut.evaluate(song()) == .blocked(.notOnAllowList))
    }

    @Test("A hand-picked explicit song is allowed — the rating is not rechecked")
    func explicitAllowedWhenHandPicked() {
        #expect(engine(.allowOnly, [.allow(Fix.song)]).evaluate(song(.explicit)) == .allowed)
    }

    @Test("A hand-picked unrated song is allowed even when the default is block")
    func unratedAllowedWhenHandPicked() {
        let sut = engine(.allowOnly, [.allow(Fix.song)], unrated: .block)
        #expect(sut.evaluate(song(nil)) == .allowed)
    }
}

// MARK: - Rule 4: deny plus auto

@Suite("Rule 4 — deny plus auto screens by rating")
struct DenyPlusAutoRules {
    @Test("A clean song nobody listed is allowed")
    func cleanAllowed() {
        #expect(engine(.denyPlusAuto).evaluate(song(.clean)) == .allowed)
    }

    @Test("An explicit song is blocked")
    func explicitBlocked() {
        #expect(engine(.denyPlusAuto).evaluate(song(.explicit)) == .blocked(.explicitContent))
    }

    @Test("An explicit album is blocked")
    func explicitAlbumBlocked() {
        #expect(engine(.denyPlusAuto).evaluate(album(.explicit)) == .blocked(.explicitContent))
    }

    @Test("An allowed artist does not bypass the rating check on their explicit tracks")
    func containerAllowDoesNotOverrideRating() {
        let sut = engine(.denyPlusAuto, [.allow(Fix.artist)])
        #expect(sut.evaluate(song(.explicit)) == .blocked(.explicitContent))
    }

    @Test("An allow on the song itself does bypass the rating check")
    func exactAllowOverridesRating() {
        let sut = engine(.denyPlusAuto, [.allow(Fix.song)])
        #expect(sut.evaluate(song(.explicit)) == .allowed)
    }
}

// MARK: - Containers have no rating

@Suite("Containers are not rated, so they are not rating-blocked")
struct ContainerRules {
    @Test("An artist is allowed even though it carries no rating", arguments: UnratedBehavior.allCases)
    func artistNotBlockedByUnrated(behavior: UnratedBehavior) {
        let sut = engine(.denyPlusAuto, unrated: behavior)
        let artist = Item(id: Fix.artist, rating: nil)
        #expect(sut.evaluate(artist) == .allowed)
    }

    @Test("A playlist is allowed even though it carries no rating", arguments: UnratedBehavior.allCases)
    func playlistNotBlockedByUnrated(behavior: UnratedBehavior) {
        let sut = engine(.denyPlusAuto, unrated: behavior)
        let playlist = Item(id: Fix.playlist, rating: nil)
        #expect(sut.evaluate(playlist) == .allowed)
    }

    @Test("A denied playlist is still blocked")
    func deniedPlaylistStillBlocked() {
        let sut = engine(.denyPlusAuto, [.deny(Fix.playlist)])
        let playlist = Item(id: Fix.playlist, rating: nil)
        #expect(sut.evaluate(playlist) == .blocked(.deniedByParent(Fix.playlist)))
    }
}

// MARK: - Unrated handling

@Suite("Unrated handling")
struct UnratedRules {
    @Test("block treats an unrated song as explicit")
    func blockUnrated() {
        #expect(engine(.denyPlusAuto, unrated: .block).evaluate(song(nil)) == .blocked(.unrated))
    }

    @Test("allow treats an unrated song as safe")
    func allowUnrated() {
        #expect(engine(.denyPlusAuto, unrated: .allow).evaluate(song(nil)) == .allowed)
    }

    @Test("inheritFromAncestor picks up an explicit album")
    func inheritExplicitAlbum() {
        let sut = engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        #expect(sut.evaluate(song(nil, albumRating: .explicit)) == .blocked(.explicitContent))
    }

    @Test("inheritFromAncestor picks up a clean album")
    func inheritCleanAlbum() {
        let sut = engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        #expect(sut.evaluate(song(nil, albumRating: .clean)) == .allowed)
    }

    @Test("inheritFromAncestor takes the nearest rated ancestor, not the furthest")
    func inheritTakesNearest() {
        let sut = engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        let item = song(nil, albumRating: .explicit, artistRating: .clean)
        #expect(sut.evaluate(item) == .blocked(.explicitContent))
    }

    @Test("inheritFromAncestor skips unrated ancestors to reach a rated one")
    func inheritSkipsUnratedAncestors() {
        let sut = engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        let item = song(nil, albumRating: nil, artistRating: .explicit)
        #expect(sut.evaluate(item) == .blocked(.explicitContent))
    }

    @Test("inheritFromAncestor falls back to blocking when nothing is rated")
    func inheritFallsBackToBlock() {
        let sut = engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        #expect(sut.evaluate(song(nil)) == .blocked(.unrated))
    }

    @Test("A rated item ignores its ancestors")
    func ratingOnItemWins() {
        let sut = engine(.denyPlusAuto, unrated: .inheritFromAncestor)
        #expect(sut.evaluate(song(.clean, albumRating: .explicit)) == .allowed)
    }
}

// MARK: - Verdict shape

@Suite("Verdict")
struct VerdictShape {
    @Test("isAllowed reflects the case")
    func isAllowed() {
        #expect(Verdict.allowed.isAllowed)
        #expect(!Verdict.blocked(.unrated).isAllowed)
    }

    @Test("reason is nil when allowed and carries the cause when blocked")
    func reasonAccessor() {
        #expect(Verdict.allowed.reason == nil)
        #expect(Verdict.blocked(.explicitContent).reason == .explicitContent)
    }
}
