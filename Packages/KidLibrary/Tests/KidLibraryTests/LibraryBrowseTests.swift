import CatalogKit
import FamilyStore
import Foundation
import PolicyEngine
import Testing

@testable import KidLibrary

// MARK: - Ordering

@Suite("Sorting a column")
struct SortingAColumn {
    @Test(
        "A leading article does not decide where a name files",
        arguments: [
            ("The Beatles", "beatles"),
            ("the xx", "xx"),
            ("A Tribe Called Quest", "tribe called quest"),
            ("An Evening With", "evening with"),
            ("Antics", "antics"),
            ("Ólafur Arnalds", "olafur arnalds"),
            ("  Spaced  ", "spaced"),
            // Not an article, just a word that starts with one.
            ("Theory", "theory"),
        ]
    )
    func sortKey(_ title: String, _ expected: String) {
        #expect(LibraryBrowse.sortKey(title) == expected)
    }

    @Test("A name that is only an article keeps it rather than becoming nothing")
    func articleOnly() {
        #expect(LibraryBrowse.sortKey("The") == "the")
        #expect(LibraryBrowse.sortKey("A") == "a")
        // "The The" strips to "the", which is still a name and still sorts.
        #expect(LibraryBrowse.sortKey("The The") == "the")
    }

    @Test("Alphabetical, and by the folded key rather than the raw title")
    func alphabetical() {
        let items = [
            CatalogItem(id: CatalogID(.album, "1"), title: "The Record"),
            CatalogItem(id: CatalogID(.album, "2"), title: "Antics"),
            CatalogItem(id: CatalogID(.album, "3"), title: "Émigré"),
        ]
        #expect(LibraryBrowse.sorted(items).map(\.title) == ["Antics", "Émigré", "The Record"])
    }

    @Test("Two rows with the same name keep a stable order rather than swapping")
    func totalOrder() {
        let items = [
            CatalogItem(id: CatalogID(.album, "b"), title: "Greatest Hits"),
            CatalogItem(id: CatalogID(.album, "a"), title: "Greatest Hits"),
        ]
        #expect(LibraryBrowse.sorted(items).map(\.id.rawValue) == ["a", "b"])
        #expect(LibraryBrowse.sorted(items.reversed()).map(\.id.rawValue) == ["a", "b"])
    }
}

// MARK: - Folding

@Suite("Folding songs into containers")
struct FoldingSongs {
    /// One kept song, with whatever lineage the test needs.
    private func kept(
        _ id: CatalogID,
        album: (String, String)? = ("album-record", "The Record"),
        artist: (String, String)? = ("artist-band", "Café Band"),
        artwork: URL? = nil
    ) -> LibrarySong {
        LibrarySong(
            item: CatalogItem(id: id, title: id.rawValue, artworkURL: artwork),
            ancestry: LibraryAncestry(
                albumID: album?.0,
                albumName: album?.1,
                artistID: artist?.0,
                artistName: artist?.1
            )
        )
    }

    @Test("Many songs on one record fold to one row")
    func dedupes() {
        let songs = [kept(Fix.clean), kept(Fix.other), kept(Fix.unrated)]
        #expect(LibraryBrowse.albums(from: songs).map(\.title) == ["The Record"])
        #expect(LibraryBrowse.artists(from: songs).map(\.title) == ["Café Band"])
    }

    @Test("A song whose lineage was never resolved contributes nothing")
    func skipsUnresolved() {
        let songs = [kept(Fix.clean, album: nil, artist: nil)]
        #expect(LibraryBrowse.albums(from: songs).isEmpty)
        #expect(LibraryBrowse.artists(from: songs).isEmpty)
    }

    @Test("An identifier without a name is not enough to draw a row")
    func nameIsRequired() {
        let songs = [
            LibrarySong(
                item: CatalogItem(id: Fix.clean, title: "Sunshine"),
                ancestry: LibraryAncestry(albumID: "album-record", artistID: "artist-band")
            )
        ]
        #expect(LibraryBrowse.albums(from: songs).isEmpty)
        #expect(LibraryBrowse.artists(from: songs).isEmpty)
    }

    @Test("The folded album borrows the first song's artwork")
    func borrowsArtwork() {
        let art = URL(string: "https://example.invalid/cover.jpg")!
        let songs = [kept(Fix.clean, artwork: art), kept(Fix.other)]
        #expect(LibraryBrowse.albums(from: songs).first?.artworkURL == art)
    }

    @Test("A folded album carries its artist as lineage, so a column can link up")
    func albumKeepsItsArtist() {
        let album = LibraryBrowse.albums(from: [kept(Fix.clean)]).first
        #expect(album?.ancestors.map(\.id) == [CatalogID(.artist, "artist-band")])
        #expect(album?.subtitle == "Café Band")
    }

    @Test("Only this artist's records slide in")
    func albumsByOneArtist() {
        let songs = [
            kept(Fix.clean),
            kept(Fix.ballad, album: ("album-sophomore", "Antics"), artist: ("artist-duo", "Duo")),
        ]
        let byBand = LibraryBrowse.albums(from: songs, by: CatalogID(.artist, "artist-band"))
        #expect(byBand.map(\.title) == ["The Record"])
    }

    @Test("Only this record's songs slide in, in track order")
    func songsOnOneAlbum() {
        let songs = [
            LibrarySong(
                item: CatalogItem(id: Fix.other, title: "Second", trackNumber: 2),
                ancestry: LibraryAncestry(albumID: "r", albumName: "R")
            ),
            LibrarySong(
                item: CatalogItem(id: Fix.clean, title: "First", trackNumber: 1),
                ancestry: LibraryAncestry(albumID: "r", albumName: "R")
            ),
            LibrarySong(
                item: CatalogItem(id: Fix.ballad, title: "Elsewhere"),
                ancestry: LibraryAncestry(albumID: "other", albumName: "Other")
            ),
        ]
        let on = LibraryBrowse.songs(from: songs, on: CatalogID(.album, "r"))
        #expect(on.map(\.title) == ["First", "Second"])
    }

    @Test("An unnumbered track sorts to the end rather than to the front")
    func unnumberedLast() {
        let songs = [
            LibrarySong(
                item: CatalogItem(id: Fix.clean, title: "Aaa"),
                ancestry: LibraryAncestry(albumID: "r", albumName: "R")
            ),
            LibrarySong(
                item: CatalogItem(id: Fix.other, title: "Zzz", trackNumber: 1),
                ancestry: LibraryAncestry(albumID: "r", albumName: "R")
            ),
        ]
        let on = LibraryBrowse.songs(from: songs, on: CatalogID(.album, "r"))
        #expect(on.map(\.title) == ["Zzz", "Aaa"])
    }

    @Test("A hearted record wins the row over the same one folded from a song")
    func favoritedWins() {
        let hearted = CatalogItem(
            id: CatalogID(.album, "album-record"),
            title: "The Record",
            rating: .clean
        )
        let merged = LibraryBrowse.merged(
            [hearted],
            LibraryBrowse.albums(from: [kept(Fix.clean)])
        )
        #expect(merged.count == 1)
        // The hearted one has a real rating; the folded one only a copied name.
        #expect(merged.first?.rating == .clean)
    }

    @Test("Earlier tiers win, however many there are")
    func tiersHaveAnOrder() {
        let id = CatalogID(.album, "album-record")
        let merged = LibraryBrowse.merged(
            [CatalogItem(id: id, title: "Hearted", rating: .clean)],
            [CatalogItem(id: id, title: "Indexed")],
            [CatalogItem(id: id, title: "Folded")]
        )
        #expect(merged.map(\.title) == ["Hearted"])
    }
}

// MARK: - Filtering

@Suite("The filter field")
struct TheFilterField {
    private let items = [
        CatalogItem(id: CatalogID(.song, "1"), title: "Sunshine", subtitle: "Café Band"),
        CatalogItem(id: CatalogID(.song, "2"), title: "Zither", subtitle: "The Duo"),
    ]

    @Test("An empty term is the whole list, not none of it")
    func emptyTerm() {
        #expect(LibraryBrowse.filter(items, by: "").count == 2)
        #expect(LibraryBrowse.filter(items, by: "   ").count == 2)
    }

    @Test("Matches the middle of a title, not just the front")
    func substring() {
        #expect(LibraryBrowse.filter(items, by: "shin").map(\.title) == ["Sunshine"])
    }

    @Test("Matches the artist on the second line, which is most of what a kid types")
    func matchesSubtitle() {
        #expect(LibraryBrowse.filter(items, by: "duo").map(\.title) == ["Zither"])
    }

    @Test("Case and accents do not have to be typed")
    func folded() {
        #expect(LibraryBrowse.filter(items, by: "cafe").map(\.title) == ["Sunshine"])
        #expect(LibraryBrowse.filter(items, by: "CAFÉ").map(\.title) == ["Sunshine"])
    }
}
